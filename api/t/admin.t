use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres — same
# HOMELAB_API_CONFIG convention as t/basic.t.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

my $suffix = time . '-' . $$;
my ($admin_email, $admin_password) = ("admin-$suffix\@test.mailmasker.org", 'AdminTest1Aa!!');
my ($plain_email, $plain_password) = ("plain-$suffix\@test.mailmasker.org", 'PlainTest1Aa!!');

$t->post_ok('/api/v1/auth/register', json => { email => $admin_email, password => $admin_password })->status_is(201);
$t->post_ok('/api/v1/auth/register', json => { email => $plain_email, password => $plain_password })->status_is(201);

# --- No token at all: 401, not a crash ---
$t->get_ok('/api/v1/admin/users')->status_is(401);

# --- A real, valid token, but no site_admin role: 403, not 401 (the
# token IS valid — it's the *authorization*, not the *authentication*,
# that's insufficient; the distinction matters for a caller trying to
# tell "log in again" apart from "wrong account") ---
$t->post_ok('/api/v1/auth/login', json => { email => $plain_email, password => $plain_password })->status_is(200);
my $plain_jwt = $t->tx->res->json('/token');

$t->get_ok('/api/v1/admin/users' => { Authorization => "Bearer $plain_jwt" })->status_is(403);
$t->post_ok("/api/v1/admin/users/1/roles" => { Authorization => "Bearer $plain_jwt" }, json => { role => 'site_admin' })
  ->status_is(403);

# --- Promote admin_email to site_admin directly via SQL — same
# mechanism the real test-admin@test.mailmasker.org account was granted
# with; there's no bootstrapping-the-first-admin API by design (see
# migrations/003-rbac.sql's own comment on why admin gating is a
# hardcoded role check, not a self-service table). ---
{
    my $user_id = $t->app->pg->db->query('SELECT id FROM api.users WHERE email = ?', $admin_email)->hash->{id};
    my $role_id = $t->app->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'site_admin'})->hash->{id};
    $t->app->pg->db->query('INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?)', $user_id, $role_id);
}

$t->post_ok('/api/v1/auth/login', json => { email => $admin_email, password => $admin_password })->status_is(200);
my $admin_jwt = $t->tx->res->json('/token');

# --- Now the same "no role" account IS listed, with its roles ---
$t->get_ok('/api/v1/admin/users' => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200);
my $users = $t->tx->res->json;
my ($admin_row) = grep { $_->{email} eq $admin_email } @$users;
my ($plain_row) = grep { $_->{email} eq $plain_email } @$users;
ok($admin_row, 'the newly-promoted admin account appears in the listing');
ok($plain_row, 'the plain account appears in the listing too');
is_deeply([sort @{ $admin_row->{roles} }], ['site_admin', 'user'], 'admin account shows both roles');
is_deeply($plain_row->{roles}, ['user'], 'plain account shows only the default role');

# --- Granting an unknown role is rejected, not silently ignored ---
$t->post_ok("/api/v1/admin/users/$plain_row->{id}/roles" => { Authorization => "Bearer $admin_jwt" },
    json => { role => 'not-a-real-role' })
  ->status_is(400);

# --- Targeting a nonexistent user is rejected ---
$t->post_ok('/api/v1/admin/users/999999999/roles' => { Authorization => "Bearer $admin_jwt" },
    json => { role => 'site_admin' })
  ->status_is(404);

# --- Granting a real role to the plain user, verified via a fresh listing ---
$t->post_ok("/api/v1/admin/users/$plain_row->{id}/roles" => { Authorization => "Bearer $admin_jwt" },
    json => { role => 'site_admin' })
  ->status_is(200)->json_is('/ok', 1);

$t->get_ok('/api/v1/admin/users' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
($plain_row) = grep { $_->{email} eq $plain_email } @{ $t->tx->res->json };
is_deeply([sort @{ $plain_row->{roles} }], ['site_admin', 'user'], 'the granted role now shows up');

# Granting the same role twice is idempotent, not an error (ON CONFLICT
# DO NOTHING) — an admin re-running the same grant shouldn't 500.
$t->post_ok("/api/v1/admin/users/$plain_row->{id}/roles" => { Authorization => "Bearer $admin_jwt" },
    json => { role => 'site_admin' })
  ->status_is(200);

# --- Revoking it removes it, verified via another fresh listing ---
$t->delete_ok("/api/v1/admin/users/$plain_row->{id}/roles/site_admin" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200)->json_is('/ok', 1);

$t->get_ok('/api/v1/admin/users' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
($plain_row) = grep { $_->{email} eq $plain_email } @{ $t->tx->res->json };
is_deeply($plain_row->{roles}, ['user'], 'the revoked role is gone, the default role is untouched');

# Revoking a role the user never had is a harmless no-op, not an error.
$t->delete_ok("/api/v1/admin/users/$plain_row->{id}/roles/site_admin" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200);

done_testing;
