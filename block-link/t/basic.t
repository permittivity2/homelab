use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);

# Full integration test against a real Postgres AND a real, reachable
# homelab-api -- point HOMELAB_BLOCK_LINK_CONFIG at a real,
# already-deployed config.yml (same "no mocks" convention as every
# other homelab-* service's own test suite).
unless ($ENV{HOMELAB_BLOCK_LINK_CONFIG}) {
    plan skip_all => 'Set HOMELAB_BLOCK_LINK_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
use FindBin;
use lib "$FindBin::Bin/../../common/t/lib";
use TestAccounts qw(track_account);
my $t = Test::Mojo->new('Homelab::BlockLink::App');

$t->get_ok('/internal/v1/block-link/account')->status_is(401, 'no Authorization header -> 401');

my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;

my $domain = 'block-link-test-' . time . '-' . $$ . '.invalid';
my $email  = "user\@$domain";
# Real account, registered below -- tracked for clean-up.
track_account(undef, $email);
my $password = 'BlockLinkTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $email, password => $password });
my $jwt = $ua->post("$api_base/api/v1/auth/login" => json => { email => $email, password => $password })
    ->res->json('/token');
ok($jwt, 'got a real JWT') or BAIL_OUT('cannot continue without a real login');
my $auth = { Authorization => "Bearer $jwt" };

# --- Account settings (self-service) ------------------------------------
my $effective = $t->get_ok('/internal/v1/block-link/account' => $auth)
    ->status_is(200)->tx->res->json;
is($effective->{enabled}, 0, 'a brand new domain with no settings row defaults to disabled');
is($effective->{mode}, 'header', 'default mode is header');

$t->put_ok('/internal/v1/block-link/account' => $auth => json => { enabled => \1 })
    ->status_is(200)
    ->json_is('/enabled', 1);

# --- Domain settings (site_admin only) -----------------------------------
$t->put_ok("/internal/v1/block-link/domains/$domain" => $auth => json => { enabled => \1, mode => 'both' })
    ->status_is(403, 'a non-admin cannot set the domain default');

# Grant site_admin the same direct-SQL technique every other test suite
# in this repo uses (no self-service "become an admin" API by design).
{
    my $sql = "INSERT INTO api.user_roles (user_id, role_id) " .
        "SELECT u.id, r.id FROM api.users u, api.roles r WHERE u.email = '$email' AND r.name = 'site_admin'";
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
    die "could not grant site_admin to $email for testing -- see t/basic.t\n" if $? != 0;
}

$t->put_ok("/internal/v1/block-link/domains/$domain" => $auth => json => { enabled => \1, mode => 'both' })
    ->status_is(200, 'site_admin can set the domain default')
    ->json_is('/mode', 'both');

$t->put_ok("/internal/v1/block-link/domains/$domain" => $auth => json => { enabled => \1, mode => 'bogus' })
    ->status_is(400, 'an invalid mode is rejected, not silently accepted');

# --- Account override beats the domain default ---------------------------
$t->put_ok('/internal/v1/block-link/account' => $auth => json => { enabled => \0 })
    ->status_is(200)->json_is('/enabled', 0);
my $effective2 = $t->get_ok('/internal/v1/block-link/account' => $auth)->status_is(200)->tx->res->json;
is($effective2->{enabled}, 0, 'account override (disabled) beats the domain default (enabled)');
is($effective2->{domain_default}, 1, 'domain_default field reports the real domain setting, unaffected by the override');

# --- The link page needs a sign-in (post-cutover item 69) -------------------
# Signed out, the page is never drawn and the link is never looked up: with
# an sso: block a visitor is sent to sign in, without one they get a page
# that only points at Manage Account. Either way no address, no form.
my $signed_out = $t->app->sso ? 302 : 200;
my $bogus_token = 'not-a-real-token-at-all';
$t->get_ok("/l/$bogus_token")->status_is($signed_out, 'a garbage token, signed out: no 404 to learn from')
    ->content_unlike(qr{not valid}, '... the link is not even looked up');

# Insert a real pending_links row directly (this is what the milter would
# do live) to test the page against real data.
my $token = join '', map { sprintf('%02x', int(rand(256))) } 1 .. 32;
$t->app->pg->db->query(
    q{INSERT INTO block_link.pending_links (token, candidates, expires_at)
      VALUES (?, ?, NOW() + INTERVAL '90 days')},
    $token, encode_json([{ account_email => $email, address => "victim\@$domain" }]),
);

$t->get_ok("/l/$token")->status_is($signed_out, 'a real pending link, signed out: not shown')
    ->content_unlike(qr{victim\@}, '... the address is not on the page')
    ->content_unlike(qr{>Add to Block List</button>}, '... and there is nothing to block with');
$t->post_ok("/l/$token" => json => { block => ["victim\@$domain"] })
    ->status_is(403, 'blocking from the link alone is refused');
is $t->app->pg->db->query(
    'SELECT count(*) FROM domainadmin.recipient_access WHERE lower(recipient) = lower(?)', "victim\@$domain",
)->array->[0], 0, '... and nothing was blocked';
# The signed-in page (the form, the block list, Add to Block List, unblock)
# needs a browser sign-in through homelab-sso: see the live check in
# post-cutover item 69's record (tools/e2e69.sh), run from offsite.

# --- Regression (post-cutover item 48): one link, two accounts -------------
# One message to two accounts gets ONE link. Signed out, nobody may see or
# block the other account's address. Refused before any on-behalf call, so
# this leaves nothing behind in recipient_access.
my $token2 = join '', map { sprintf('%02x', int(rand(256))) } 1 .. 32;
$t->app->pg->db->query(
    q{INSERT INTO block_link.pending_links (token, candidates, expires_at)
      VALUES (?, ?, NOW() + INTERVAL '90 days')},
    $token2, encode_json([
        { account_email => $email,                  address => "mine\@$domain" },
        { account_email => "someone-else\@$domain", address => "bcc-copy\@$domain" },
    ]),
);
$t->get_ok("/l/$token2")->status_is($signed_out)
    ->content_unlike(qr{bcc-copy\@}, 'a two-account link does not show the other account\'s address')
    ->content_unlike(qr{mine\@},     '... nor any address, until you sign in');
$t->post_ok("/l/$token2" => json => { block => ["bcc-copy\@$domain"] })
    ->status_is(403, '... and blocking from it is refused');
$t->app->pg->db->query('DELETE FROM block_link.pending_links WHERE token IN (?, ?)', $token, $token2);

done_testing;
