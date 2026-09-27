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
my $t = Test::Mojo->new('Homelab::BlockLink::App');

$t->get_ok('/internal/v1/block-link/account')->status_is(401, 'no Authorization header -> 401');

my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;

my $domain = 'block-link-test-' . time . '-' . $$ . '.invalid';
my $email  = "user\@$domain";
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

# --- Public link page (no DB mutation on GET) -----------------------------
my $bogus_token = 'not-a-real-token-at-all';
$t->get_ok("/l/$bogus_token")->status_is(404, 'a garbage token is a clean 404');

# Insert a real pending_links row directly (this is what the milter would
# do live) to test the public page against real data.
my $token = join '', map { sprintf('%02x', int(rand(256))) } 1 .. 32;
$t->app->pg->db->query(
    q{INSERT INTO block_link.pending_links (token, candidates, expires_at)
      VALUES (?, ?, NOW() + INTERVAL '90 days')},
    $token, encode_json([{ account_email => $email, address => "victim\@$domain" }]),
);

$t->get_ok("/l/$token")->status_is(200, 'a real pending link renders the management page')
    ->content_like(qr/checked/, 'the candidate checkbox is pre-checked by default');

done_testing;
