use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::URL;

# Full end-to-end integration test — needs a real config.yml (real
# runtime DB credentials, migrations already applied) AND a real,
# reachable homelab-api (homelab_api.base_url in that config), since
# login proxies through to it. Same HOMELAB_*_CONFIG convention as
# every other homelab-* Mojolicious app's tests. Also needs at least one
# real registered `clients` entry in that config.yml named `test-client`
# with a known client_secret/redirect_uri — see t/README (or just this
# file's own header) for the exact values this test expects.
unless ($ENV{HOMELAB_SSO_CONFIG}) {
    plan skip_all => 'Set HOMELAB_SSO_CONFIG to a real config.yml (with a test-client entry, see this file) to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::SSO::App');

my $client_id     = 'test-client';
my $client_secret = $ENV{HOMELAB_SSO_TEST_CLIENT_SECRET} // 'test-client-secret';
my $redirect_uri  = 'http://127.0.0.1:9999/oauth/callback';

my $email    = 'e2e-sso-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'E2eSsoTest1Aa';

# Register the account this test logs in as, directly against
# homelab-api (bypassing this app entirely for setup, same as every
# other package's own integration test does).
{
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    die "test account registration failed: " . $tx->result->body unless $tx->result->code == 201;
}

# --- Unknown client is rejected up front ---
$t->get_ok('/oauth/authorize' => form => { client_id => 'nonexistent-client', redirect_uri => $redirect_uri })
  ->status_is(400);

# --- No session yet: shows the login form, doesn't redirect ---
$t->get_ok(Mojo::URL->new('/oauth/authorize')->query(
    client_id => $client_id, redirect_uri => $redirect_uri, state => 'xyz', scope => 'openid',
))->status_is(200)->content_like(qr/Log in/);

# --- Wrong password: form redisplayed with an error, no code issued ---
$t->post_ok('/oauth/authorize' => form => {
    client_id => $client_id, redirect_uri => $redirect_uri, state => 'xyz',
    email => $email, password => 'definitely-wrong',
})->status_is(200)->content_like(qr/failed|Log in/i);

# --- Correct credentials: redirected back to the client with a code ---
$t->post_ok('/oauth/authorize' => form => {
    client_id => $client_id, redirect_uri => $redirect_uri, state => 'xyz',
    email => $email, password => $password,
})->status_is(302);

my $location = $t->tx->res->headers->location;
like($location, qr/^\Q$redirect_uri\E\?/, 'redirected back to the registered redirect_uri');
my $callback_url = Mojo::URL->new($location);
my $code  = $callback_url->query->param('code');
my $state = $callback_url->query->param('state');
ok($code, 'a real authorization code was issued');
is($state, 'xyz', 'state is echoed back unchanged (CSRF protection for the client)');

# --- THE actual SSO property, checked here (before anything below
# rotates the underlying token via the refresh_token grant) rather than
# at the end of this file: a second /oauth/authorize call in the same
# browser session (same Test::Mojo cookie jar) skips the login form
# entirely and issues a fresh code immediately, because the IdP session
# cookie set by the POST above is still live. This is what "login once,
# login everywhere" actually depends on — everything else in this file
# could pass even with a per-client-only login; this can't. Deliberately
# BEFORE the refresh_token-grant test further down: that grant rotates
# (and revokes the OLD copy of) the exact same token this IdP session
# cookie is holding, which would otherwise make this check fail for a
# reason that has nothing to do with SSO actually working. ---
$t->get_ok(Mojo::URL->new('/oauth/authorize')->query(
    client_id => $client_id, redirect_uri => $redirect_uri, state => 'second-request',
))->status_is(302, 'a second authorize call with a live IdP session skips the login form');
my $second_location = $t->tx->res->headers->location;
like($second_location, qr/^\Q$redirect_uri\E\?/, 'still redirects to the client');
my $second_code = Mojo::URL->new($second_location)->query->param('code');
isnt($second_code, $code, 'a genuinely NEW code, not the already-used one');
# Exchange it too, so it doesn't linger as an unused row, and so the
# LOGOUT check at the end of this file has a real, still-valid access
# token of its own to prove goes invalid.
$t->post_ok('/oauth/token' => form => {
    grant_type => 'authorization_code', code => $second_code,
    client_id => $client_id, client_secret => $client_secret, redirect_uri => $redirect_uri,
})->status_is(200)->json_has('/access_token');

# --- Server-to-server code exchange ---
$t->post_ok('/oauth/token' => form => {
    grant_type => 'authorization_code', code => $code,
    client_id => $client_id, client_secret => $client_secret, redirect_uri => $redirect_uri,
})->status_is(200)->json_has('/access_token')->json_has('/refresh_token');

my $access_token  = $t->tx->res->json('/access_token');
my $refresh_token = $t->tx->res->json('/refresh_token');

# --- The code is one-time use — replaying it must fail ---
$t->post_ok('/oauth/token' => form => {
    grant_type => 'authorization_code', code => $code,
    client_id => $client_id, client_secret => $client_secret, redirect_uri => $redirect_uri,
})->status_is(400)->json_is('/error', 'invalid_grant');

# --- Wrong client_secret is rejected ---
$t->post_ok('/oauth/token' => form => {
    grant_type => 'authorization_code', code => 'irrelevant-since-secret-is-checked-first',
    client_id => $client_id, client_secret => 'wrong-secret', redirect_uri => $redirect_uri,
})->status_is(401)->json_is('/error', 'invalid_client');

# --- userinfo (what Roundcube's oauth_identity_uri calls) ---
$t->get_ok('/oauth/userinfo' => { Authorization => "Bearer $access_token" })
  ->status_is(200)->json_is('/email', $email);

$t->get_ok('/oauth/userinfo' => { Authorization => 'Bearer garbage' })
  ->status_is(401);

# --- refresh_token grant. Rotates (and revokes the OLD copy of) this
# exact token -- deliberately tested here, AFTER the SSO-session check
# above, not before it; see that check's own comment for why. ---
$t->post_ok('/oauth/token' => form => {
    grant_type => 'refresh_token', refresh_token => $refresh_token,
    client_id => $client_id, client_secret => $client_secret,
})->status_is(200)->json_has('/access_token');

# --- Logout kills the IdP session: the NEXT authorize call shows the
# login form again instead of silently re-authenticating. ---
$t->get_ok('/logout')->status_is(200)->content_like(qr/logged out/i);

$t->get_ok(Mojo::URL->new('/oauth/authorize')->query(
    client_id => $client_id, redirect_uri => $redirect_uri, state => 'after-logout',
))->status_is(200, 'after logout, authorize shows the login form again, not a silent redirect')
  ->content_like(qr/Log in/);

done_testing;
