use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres — point
# HOMELAB_API_CONFIG at a config.yml with real (throwaway/test) runtime
# DB credentials for a schema with migrations already applied. Matches
# the same HOMELAB_*_CONFIG-env-var convention every other homelab-*
# Mojolicious app's test suite already uses.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

$t->get_ok('/health')->status_is(200)->content_is('ok');

# A fresh, randomized email so repeated test runs never collide.
my $email    = 'test-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'correct horse battery staple';

$t->post_ok('/api/v1/auth/register', json => { email => $email, password => $password })
  ->status_is(201)
  ->json_is('/email', $email);

# Registering the same email twice is rejected, not silently overwritten.
$t->post_ok('/api/v1/auth/register', json => { email => $email, password => $password })
  ->status_is(409);

$t->post_ok('/api/v1/auth/login', json => { email => $email, password => 'wrong password' })
  ->status_is(401);

$t->post_ok('/api/v1/auth/login', json => { email => $email, password => $password })
  ->status_is(200)
  ->json_has('/token')
  ->json_has('/refresh_token');

my $jwt           = $t->tx->res->json('/token');
my $refresh_token = $t->tx->res->json('/refresh_token');

$t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $jwt" })
  ->status_is(200)
  ->json_is('/email', $email)
  ->json_is('/roles', ['user'], 'introspect includes roles (Phase 5, for homelab-domain-admin site_admin gating) -- a fresh account only holds the default user role');

$t->get_ok('/api/v1/auth/introspect' => { Authorization => 'Bearer garbage' })
  ->status_is(401);

$t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $refresh_token })
  ->status_is(200)
  ->json_has('/token');

my $new_refresh_token = $t->tx->res->json('/refresh_token');
isnt($new_refresh_token, $refresh_token, 'refresh rotates to a new refresh_token');

# The OLD refresh_token was revoked by rotation — using it again must fail,
# not silently succeed (this is the actual security property rotation exists for).
$t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $refresh_token })
  ->status_is(401);

$t->post_ok('/api/v1/auth/logout', json => { refresh_token => $new_refresh_token })
  ->status_is(200);

$t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $new_refresh_token })
  ->status_is(401);

# The actual property real SSO logout depends on (see homelab-sso's
# README): logging out must invalidate the ACCESS TOKEN too, immediately
# -- not just block future refreshes. Before migrations/005-sessions.sql,
# this exact JWT (freshly minted moments ago, nowhere near its own
# ~30min expiry_seconds) would still introspect as perfectly valid here,
# since introspect() only checked the signature and exp claim. This is
# what makes "logout once, logged out everywhere" real instead of
# eventually-true-in-30-minutes.
{
    # Re-login to get a fresh token+refresh_token pair whose logout we
    # actually observe end-to-end in this one test, rather than relying
    # on $jwt from the very first login above (still technically valid
    # here since IT was never logged out).
    $t->post_ok('/api/v1/auth/login', json => { email => $email, password => $password })
      ->status_is(200);
    my $fresh_jwt           = $t->tx->res->json('/token');
    my $fresh_refresh_token = $t->tx->res->json('/refresh_token');

    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $fresh_jwt" })
      ->status_is(200, 'freshly-issued JWT introspects fine before logout');

    $t->post_ok('/api/v1/auth/logout', json => { refresh_token => $fresh_refresh_token })
      ->status_is(200);

    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $fresh_jwt" })
      ->status_is(401, 'the SAME still-unexpired JWT is rejected immediately after logout');
}

# --- Rate limiting (see migrations/006-login-attempts.sql) ---
# Uses a dedicated marker email so its own logged attempts can be
# cleaned up afterward without touching any other test's rows -- the
# rate limit itself is per-IP (Test::Mojo's in-process requests all
# resolve to the same address), so leftover rows here would otherwise
# affect every OTHER test run against this same database, not just this
# one, since api.login_attempts is a real accumulating table, not a
# per-test fixture. Loops until a 429 actually shows up rather than
# assuming a precise attempt count, since earlier tests above (the
# original wrong-password check near the top) already contributed at
# least one failure of their own to this same IP's running count.
{
    my $marker_email = 'rate-limit-test-' . time . '-' . $$ . '@test.mailmasker.org';
    my $saw_429 = 0;

    for (1 .. 15) {
        $t->post_ok('/api/v1/auth/login', json => { email => $marker_email, password => 'wrong' });
        if ($t->tx->res->code == 429) {
            $saw_429 = 1;
            last;
        }
        is($t->tx->res->code, 401, 'not-yet-rate-limited failed attempts are rejected normally');
    }
    ok($saw_429, 'repeated failed logins from the same IP eventually get rate-limited (429)');

    # A CORRECT password from the same (now rate-limited) IP is also
    # blocked -- this is throttling the IP, not merely counting wrong
    # guesses against one email, so it must not be bypassable just by
    # eventually guessing right.
    $t->post_ok('/api/v1/auth/login', json => { email => $email, password => $password })
      ->status_is(429, 'rate limiting blocks the IP outright, not just repeated failures for one email');

    $t->app->pg->db->query('DELETE FROM api.login_attempts WHERE email = ?', $marker_email);
}

# --- Service registry ---
$t->post_ok('/api/v1/registry/register', json => {
    feature_name => 'homelab-test-feature', host => '10.10.0.99', port => 4242, health_check_url => '/health',
})->status_is(200)->json_is('/ok', 1);

$t->get_ok('/api/v1/registry/homelab-test-feature')
  ->status_is(200)
  ->json_is('/host', '10.10.0.99')
  ->json_is('/port', 4242);

$t->get_ok('/api/v1/registry/nonexistent-feature-xyz')
  ->status_is(404);

# Re-registering the same feature updates in place (e.g. after a restart
# on a new port), not duplicated.
$t->post_ok('/api/v1/registry/register', json => {
    feature_name => 'homelab-test-feature', host => '10.10.0.100', port => 4343,
})->status_is(200);
$t->get_ok('/api/v1/registry/homelab-test-feature')
  ->status_is(200)
  ->json_is('/host', '10.10.0.100')
  ->json_is('/port', 4343);

# GET /api/v1/registry -- lists every registered feature, so a client
# can discover valid feature_name values rather than guessing them (the
# actual gap a real user hit: guessing "homelab-mail"/"homelab-dovecot"
# against /api/v1/registry/:feature and getting 404 every time).
my $listed = $t->get_ok('/api/v1/registry')
  ->status_is(200)
  ->tx->res->json;
ok((grep { $_->{feature_name} eq 'homelab-test-feature' } @$listed), 'list includes the feature registered above')
    or diag explain $listed;

$t->app->pg->db->query('DELETE FROM api.service_registry WHERE feature_name = ?', 'homelab-test-feature');

done_testing;
