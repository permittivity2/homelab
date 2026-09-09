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
  ->json_is('/email', $email);

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

done_testing;
