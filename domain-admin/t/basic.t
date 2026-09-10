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

# --- Auth: every route requires a bearer token -----------------------
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
my $auth = { Authorization => "Bearer $jwt" };

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

done_testing;
