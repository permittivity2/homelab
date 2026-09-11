use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full integration test against a real Postgres AND a real, reachable
# PowerDNS HTTP API -- point HOMELAB_DOMAIN_ADMIN_CONFIG at a real,
# already-deployed config.yml (matches api/t/basic.t's own convention;
# no mocks). DNS-CRUD assertions use a throwaway zone name
# (homelab-domain-admin-test.invalid, tagged with time+pid) that will
# never collide with a real domain this project cares about (test.
# mailmasker.org, test.forge.name) -- PowerDNS will happily create/serve
# any zone name locally regardless of whether anything on the real
# internet actually delegates to it, which is fine for exercising the
# CRUD mechanics themselves.
unless ($ENV{HOMELAB_DOMAIN_ADMIN_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DOMAIN_ADMIN_CONFIG to a real config.yml (with a reachable PowerDNS API) to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::DomainAdmin::App');

# --- Auth: every route requires a bearer token, AND (since Phase 5)
# site_admin specifically -- see App.pm's authenticated_email helper.
$t->get_ok('/internal/v1/domains')->status_is(401, 'no Authorization header -> 401');

# A real JWT from a real homelab-api login -- same pattern as
# api/t/gateway.t and mailbridge/t/basic.t.
use Mojo::UserAgent;
my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;
my $email    = 'e2e-domain-admin-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'DomainAdminTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $email, password => $password });
my $login_tx = $ua->post("$api_base/api/v1/auth/login" => json => { email => $email, password => $password });
my $jwt      = $login_tx->res->json('/token');
ok($jwt, 'got a real JWT from homelab-api') or BAIL_OUT('cannot continue without a real login');
my $plain_auth = { Authorization => "Bearer $jwt" };

$t->get_ok('/internal/v1/domains' => $plain_auth)
  ->status_is(403, 'a valid token without site_admin is a clean 403, not 401 -- authenticated but not authorized');

# Grant site_admin the same way api/t/admin.t's own test account gets
# it -- direct SQL, since there's no self-service "become an admin" API
# by design (see api/migrations/003-rbac.sql's own comment). This
# reaches into homelab-api's OWN `api` schema, which domain-admin's
# narrowly-scoped runtime role has no grant on at all -- OS-level peer
# auth via `sudo -u postgres psql` (list-form exec, no shell
# interpolation of the SQL) is the same fallback tier every bootstrap
# script in this repo already uses when a feature-scoped role isn't
# enough, just reached from a test file instead of a postinst script.
{
    my $sql = "INSERT INTO api.user_roles (user_id, role_id) " .
        "SELECT u.id, r.id FROM api.users u, api.roles r WHERE u.email = '$email' AND r.name = 'site_admin'";
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
    die "could not grant site_admin to $email for testing (needs passwordless sudo to postgres) -- see t/basic.t\n" if $? != 0;
}
my $auth = { Authorization => "Bearer $jwt" };
$t->get_ok('/internal/v1/domains' => $auth)->status_is(200, 'the same token now works once its account holds site_admin');

# --- Domain metadata CRUD (dns_managed=false -- no PowerDNS call at all) ---
my $mail_only_domain = 'mail-only-' . time . '-' . $$ . '.invalid';

$t->post_ok('/internal/v1/domains' => $auth => json => {
    domain_name => $mail_only_domain, dns_managed => \0, mail_enabled => \1,
})->status_is(201)->json_is('/domain_name', $mail_only_domain)->json_is('/dns_managed', 0);

$t->post_ok('/internal/v1/domains' => $auth => json => { domain_name => $mail_only_domain })
  ->status_is(409, 're-adding the same domain_name is rejected, not silently duplicated');

$t->get_ok("/internal/v1/domains/$mail_only_domain" => $auth)
  ->status_is(200)->json_is('/mail_enabled', 1);

$t->patch_ok("/internal/v1/domains/$mail_only_domain" => $auth => json => { mail_enabled => \0 })
  ->status_is(200)->json_is('/mail_enabled', 0);

$t->delete_ok("/internal/v1/domains/$mail_only_domain" => $auth)
  ->status_is(200)->json_is('/ok', 1);
$t->get_ok("/internal/v1/domains/$mail_only_domain" => $auth)
  ->status_is(200)->json_is('/active', 0, 'disable is soft -- the row still exists, just inactive');

$t->get_ok('/internal/v1/domains' => $auth)->status_is(200);

$t->get_ok('/internal/v1/domains/nonexistent-domain-xyz.invalid' => $auth)->status_is(404);

# --- DNS zone/record CRUD (dns_managed=true -- real PowerDNS API calls) ---
my $zone = 'homelab-domain-admin-test-' . time . '-' . $$ . '.invalid';

$t->post_ok('/internal/v1/domains' => $auth => json => { domain_name => $zone })
  ->status_is(201, 'creating a dns_managed domain also creates the real PowerDNS zone')
  ->json_is('/dns_managed', 1);

$t->post_ok("/internal/v1/domains/$zone/dns/records" => $auth => json => {
    name => $zone, type => 'A', content => '203.0.113.10', ttl => 300,
})->status_is(201)->json_is('/ok', 1)->json_is('/restart_pending', 1, 'a brand-new name needs a pdns restart to become servable');

$t->get_ok("/internal/v1/domains/$zone/dns/records" => $auth)
  ->status_is(200)
  ->json_has('/0', 'at least one record comes back')
  or diag explain $t->tx->res->json;

# A value UPDATE on the same, already-created name should not need a
# restart (PowerDNS's gpgsql backend picks this up live) -- the real
# gotcha this whole debounce mechanism exists for.
$t->post_ok("/internal/v1/domains/$zone/dns/records" => $auth => json => {
    name => $zone, type => 'A', content => '203.0.113.20', ttl => 300,
})->status_is(201)->json_is('/restart_pending', 0, 'a value update on an EXISTING name does not need a restart');

$t->delete_ok("/internal/v1/domains/$zone/dns/records" => $auth => json => { name => $zone, type => 'A' })
  ->status_is(200)->json_is('/ok', 1);

# TXT content is DNS master-file *text* syntax, not a bare string --
# PowerDNS's own API 422s an unquoted value ("Data field in DNS should
# start with quote"). A real `homelab-cli dns records add ... --type
# TXT` call caught this; regression-tested here against the real API,
# not a fake, since the bug was specifically in how we talk to it.
$t->post_ok("/internal/v1/domains/$zone/dns/records" => $auth => json => {
    name => $zone, type => 'TXT', content => 'v=spf1 -all', ttl => 300,
})->status_is(201, 'TXT content gets auto-quoted for PowerDNS, not sent bare');

$t->delete_ok("/internal/v1/domains/$zone/dns/records" => $auth => json => { name => $zone, type => 'TXT' })
  ->status_is(200);

$t->delete_ok("/internal/v1/domains/$zone" => $auth)->status_is(200, 'soft-disable never touches the PowerDNS zone itself');

# --- Recipient allow/block ---
my $recipient = 'homelab-domain-admin-test-' . time . '-' . $$ . '@invalid.example';

$t->get_ok('/internal/v1/domains/recipient-access' => $auth)
  ->status_is(200, 'the literal "recipient-access" path segment routes here, not to domains#show with domain="recipient-access"');

$t->post_ok('/internal/v1/domains/recipient-access' => $auth => json => { recipient => $recipient, action => 'REJECT', reason => 'test' })
  ->status_is(201)->json_is('/action', 'REJECT')->json_is('/reason', 'test');

$t->get_ok('/internal/v1/domains/recipient-access' => $auth)
  ->status_is(200)
  ->json_has('/0', 'at least one entry comes back');

# Upsert, not insert-only -- re-blocking (here: re-allowing) an address
# already in the table updates it in place rather than 409ing.
$t->post_ok('/internal/v1/domains/recipient-access' => $auth => json => { recipient => $recipient, action => 'OK' })
  ->status_is(201)->json_is('/action', 'OK', 'posting the same recipient again updates the row instead of erroring');

$t->delete_ok("/internal/v1/domains/recipient-access/$recipient" => $auth)
  ->status_is(200)->json_is('/ok', 1);

$t->delete_ok("/internal/v1/domains/recipient-access/$recipient" => $auth)
  ->status_is(404, 'deleting an already-gone entry is a clean 404, not a 500');

$t->post_ok('/internal/v1/domains/recipient-access' => $auth => json => { action => 'REJECT' })
  ->status_is(400, 'recipient is required');

# --- Multi-domain send-as: mail_aliases, and specifically that
# `active` (inbound routing) and `send_enabled` (outbound
# authorization) are genuinely independent -- the whole point of the
# feature (see README.md's "Multi-domain send-as" section). ---
my $alias_domain  = 'homelab-domain-admin-mailalias-test-' . time . '-' . $$ . '.invalid';
my $alias_pattern = "\@$alias_domain";

$t->post_ok('/internal/v1/domains/mail-aliases' => $auth => json => {
    source_pattern => $alias_pattern, destination => $email,
})->status_is(201, 'the literal "mail-aliases" path segment routes here, not to domains#show')
  ->json_is('/source_pattern', $alias_pattern)->json_is('/destination', $email)
  ->json_is('/active', 1)->json_is('/send_enabled', 1);

$t->get_ok("/internal/v1/domains/$alias_domain" => $auth)
  ->status_is(200, 'creating a mail-alias for a brand-new domain auto-creates its domainadmin.domains row')
  ->json_is('/mail_enabled', 0, 'auto-created as DKIM/DNS-eligible but NOT a virtual_mailbox_domain')
  ->json_is('/dns_managed', 1);

$t->get_ok('/internal/v1/domains/mail-aliases' => $auth)
  ->status_is(200)->json_has('/0', 'at least one entry comes back');

$t->get_ok("/internal/v1/domains/mail-aliases?destination=$email" => $auth)->status_is(200);
ok((grep { $_->{source_pattern} eq $alias_pattern } @{ $t->tx->res->json }), '?destination= filter finds our grant');

$t->post_ok('/internal/v1/domains/mail-aliases' => $auth => json => {
    source_pattern => $alias_pattern, destination => $email, send_enabled => \0,
})->status_is(201)->json_is('/send_enabled', 0, 'posting the same source_pattern again upserts in place, not a 409/duplicate');

$t->patch_ok("/internal/v1/domains/mail-aliases/$alias_pattern" => $auth => json => { send_enabled => \1 })
  ->status_is(200)->json_is('/send_enabled', 1);

# /mine is the one self-service exception in this whole service --
# $plain_auth is the SAME token from before site_admin was ever
# granted (still a valid JWT, just not site_admin), proving this route
# really doesn't require the role every other route in this file does.
$t->get_ok('/internal/v1/domains/mail-aliases/mine' => $plain_auth)
  ->status_is(200, '/mine works without site_admin, unlike every other route in this file');
my $mine = $t->tx->res->json;
ok((grep { $_ eq $email } @{ $mine->{send}{addresses} }), q{caller's own address is always in send.addresses});
ok((grep { $_ eq $alias_pattern } @{ $mine->{send}{domains} }), 'active+send_enabled catch-all grant appears under send.domains');
is(scalar(@{ $mine->{receive_only}{domains} }), 0, 'nothing under receive_only yet');

# The actual point of having two flags: disabling send must NOT touch
# `active` -- a real assertion on the persisted row, not just on /mine.
$t->patch_ok("/internal/v1/domains/mail-aliases/$alias_pattern" => $auth => json => { send_enabled => \0 })
  ->status_is(200)->json_is('/send_enabled', 0)
  ->json_is('/active', 1, 'active is untouched by the send_enabled toggle -- inbound routing keeps working');

$t->get_ok('/internal/v1/domains/mail-aliases/mine' => $plain_auth)->status_is(200);
$mine = $t->tx->res->json;
ok(!(grep { $_ eq $alias_pattern } @{ $mine->{send}{domains} }), 'no longer under send.domains once send_enabled=false');
ok((grep { $_ eq $alias_pattern } @{ $mine->{receive_only}{domains} }), 'moved to receive_only.domains instead -- still receiving, just not sending');

$t->patch_ok('/internal/v1/domains/mail-aliases/nonexistent-pattern' => $auth => json => { send_enabled => \1 })
  ->status_is(404);
$t->patch_ok("/internal/v1/domains/mail-aliases/$alias_pattern" => $auth => json => {})
  ->status_is(400, 'send_enabled is required');

$t->delete_ok("/internal/v1/domains/mail-aliases/$alias_pattern" => $auth)
  ->status_is(200)->json_is('/ok', 1);
$t->delete_ok("/internal/v1/domains/mail-aliases/$alias_pattern" => $auth)
  ->status_is(404, 'deleting an already-gone entry is a clean 404, not a 500');

$t->post_ok('/internal/v1/domains/mail-aliases' => $auth => json => { destination => $email })
  ->status_is(400, 'source_pattern and destination are required');
$t->post_ok('/internal/v1/domains/mail-aliases' => $auth => json => { source_pattern => 'no-at-sign', destination => $email })
  ->status_is(400, 'source_pattern must contain a domain');

$t->get_ok('/internal/v1/domains/mail-aliases/mine')->status_is(401, 'no Authorization header -> 401, same as every other route');

# --- DKIM rotation state machine -- real opendkim-genkey + real
# PowerDNS TXT writes, no mocks (needs opendkim-tools installed and
# /etc/opendkim/keys writable, true on any host homelab-postfix is
# actually installed on -- see README.md's "DKIM" section). ---
my $dkim_domain = 'homelab-domain-admin-dkim-test-' . time . '-' . $$ . '.invalid';
$t->post_ok('/internal/v1/domains' => $auth => json => { domain_name => $dkim_domain })
  ->status_is(201, 'DKIM test needs a real PowerDNS zone to publish TXT records into');

$t->get_ok("/internal/v1/domains/$dkim_domain/dkim/selectors" => $auth)
  ->status_is(200)->json_is('' => [], 'no selectors yet');

$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/rotate" => $auth)
  ->status_is(201)->json_is('/state', 'pending')
  or diag explain $t->tx->res->json;
my $selector1 = $t->tx->res->json('/selector');
ok($selector1, 'got a real date/version selector, e.g. 20260911a') or BAIL_OUT('DKIM rotate failed -- cannot continue');
ok(!exists $t->tx->res->json->{private_key}, 'response never includes private key material, only public_key (see README.md)');

$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/rotate" => $auth)->status_is(201);
my $selector2 = $t->tx->res->json('/selector');
isnt($selector2, $selector1, 'a second same-day rotation gets a different selector (date+incrementing letter)');

# Activating selector1 while nothing else is active: no prior selector
# to demote to 'retiring'.
$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/$selector1/activate" => $auth)
  ->status_is(200)->json_is('/state', 'active');

$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/$selector1/activate" => $auth)
  ->status_is(409, 're-activating an already-active selector is rejected, not a silent no-op');

# Activating selector2 demotes selector1 to 'retiring' with a real
# retire_after timestamp (config.yml's dkim.retirement_days, default 7)
# -- the actual hard requirement this whole state machine exists for:
# the OLD key must keep verifying mail already in flight.
$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/$selector2/activate" => $auth)
  ->status_is(200)->json_is('/state', 'active');

$t->get_ok("/internal/v1/domains/$dkim_domain/dkim/selectors" => $auth)->status_is(200);
my %by_selector = map { $_->{selector} => $_ } @{ $t->tx->res->json };
is($by_selector{$selector1}{state}, 'retiring', 'the previously-active selector is now retiring, not gone');
ok($by_selector{$selector1}{retire_after}, 'retiring selector has a real retire_after timestamp');
is($by_selector{$selector2}{state}, 'active', 'the newly-activated selector is now active');

# Break-glass: force-retire the retiring selector immediately instead
# of waiting for the automatic timer.
$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/$selector1/retire" => $auth)
  ->status_is(200)->json_is('/ok', 1);
$t->get_ok("/internal/v1/domains/$dkim_domain/dkim/selectors" => $auth)->status_is(200);
%by_selector = map { $_->{selector} => $_ } @{ $t->tx->res->json };
is($by_selector{$selector1}{state}, 'retired', 'force-retire moved it straight to retired');

$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/$selector1/retire" => $auth)
  ->status_is(409, 're-retiring an already-retired selector is rejected');

$t->post_ok("/internal/v1/domains/$dkim_domain/dkim/nonexistent-selector/activate" => $auth)
  ->status_is(404);

done_testing;
