use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres — same
# HOMELAB_API_CONFIG convention as t/admin.t, which this mirrors.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

my $suffix = time . '-' . $$;
my ($admin_email, $admin_password) = ("roles-admin-$suffix\@test.mailmasker.org", 'AdminTest1Aa!!');
my ($plain_email, $plain_password) = ("roles-plain-$suffix\@test.mailmasker.org", 'PlainTest1Aa!!');
my $role_name = "auditor-$suffix";

$t->post_ok('/api/v1/auth/register', json => { email => $admin_email, password => $admin_password })->status_is(201);
$t->post_ok('/api/v1/auth/register', json => { email => $plain_email, password => $plain_password })->status_is(201);

# Promote admin_email to site_admin directly via SQL, same mechanism
# t/admin.t already uses (there's no self-service first-admin API by
# design — see migrations/003-rbac.sql).
{
    my $user_id = $t->app->pg->db->query('SELECT id FROM api.users WHERE email = ?', $admin_email)->hash->{id};
    my $role_id = $t->app->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'site_admin'})->hash->{id};
    $t->app->pg->db->query('INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?)', $user_id, $role_id);
}

$t->post_ok('/api/v1/auth/login', json => { email => $admin_email, password => $admin_password })->status_is(200);
my $admin_jwt = $t->tx->res->json('/token');
$t->post_ok('/api/v1/auth/login', json => { email => $plain_email, password => $plain_password })->status_is(200);
my $plain_jwt = $t->tx->res->json('/token');

# --- introspect now carries jti ---
$t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $plain_jwt" })->status_is(200);
my $introspect_jti = $t->tx->res->json('/jti');
ok($introspect_jti && length($introspect_jti) > 10, 'introspect includes a real jti');

# --- No token / not site_admin: 401 / 403, not a crash ---
$t->get_ok('/api/v1/admin/roles')->status_is(401);
$t->get_ok('/api/v1/admin/roles' => { Authorization => "Bearer $plain_jwt" })->status_is(403);
$t->post_ok('/api/v1/admin/roles' => { Authorization => "Bearer $plain_jwt" }, json => { name => 'whatever' })->status_is(403);

# --- Create a new, non-protected role ---
$t->post_ok('/api/v1/admin/roles' => { Authorization => "Bearer $admin_jwt" },
    json => { name => $role_name, description => 'test auditor role' })
  ->status_is(201)
  ->json_is('/name', $role_name)
  ->json_is('/protected', 0)
  ->json_is('/permissions', []);

# Creating the same role twice is a real conflict, not silently ignored.
$t->post_ok('/api/v1/admin/roles' => { Authorization => "Bearer $admin_jwt" }, json => { name => $role_name })
  ->status_is(409);

# --- It shows up in the listing ---
$t->get_ok('/api/v1/admin/roles' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
my ($new_role) = grep { $_->{name} eq $role_name } @{ $t->tx->res->json };
ok($new_role, 'new role appears in the listing');
is_deeply($new_role->{permissions}, [], 'starts with zero permissions');

# --- Permission catalog includes the seeded audit.view ---
$t->get_ok('/api/v1/admin/permissions' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
my ($audit_view) = grep { $_->{name} eq 'audit.view' } @{ $t->tx->res->json };
ok($audit_view, 'audit.view is seeded in the permission catalog');

# --- has_capability: site_admin always passes, regardless of role_permissions ---
$t->get_ok("/api/v1/auth/introspect?capability=audit.view" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200)->json_is('/has_capability', 1);

# --- A plain user-role account fails without a matching permission row ---
$t->get_ok("/api/v1/auth/introspect?capability=audit.view" => { Authorization => "Bearer $plain_jwt" })
  ->status_is(200)->json_is('/has_capability', 0);

# --- Grant the new role to the plain user, still no permission yet ---
{
    my $plain_id = $t->app->pg->db->query('SELECT id FROM api.users WHERE email = ?', $plain_email)->hash->{id};
    $t->post_ok("/api/v1/admin/users/$plain_id/roles" => { Authorization => "Bearer $admin_jwt" },
        json => { role => $role_name })
      ->status_is(200);
}
$t->get_ok("/api/v1/auth/introspect?capability=audit.view" => { Authorization => "Bearer $plain_jwt" })
  ->status_is(200)->json_is('/has_capability', 0, 'holding the role alone is not enough -- it has no permissions yet');

# --- Grant audit.view to the role -- now the plain user passes ---
$t->post_ok("/api/v1/admin/roles/$role_name/permissions/audit.view" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200)->json_is('/ok', 1);

$t->get_ok("/api/v1/auth/introspect?capability=audit.view" => { Authorization => "Bearer $plain_jwt" })
  ->status_is(200)->json_is('/has_capability', 1, 'granting the permission to the role the user holds now passes');

$t->get_ok('/api/v1/admin/roles' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
($new_role) = grep { $_->{name} eq $role_name } @{ $t->tx->res->json };
is_deeply($new_role->{permissions}, ['audit.view'], 'role listing reflects the grant');

# Granting the same permission twice is idempotent, not an error.
$t->post_ok("/api/v1/admin/roles/$role_name/permissions/audit.view" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200);

# Unknown role/permission names are rejected, not silently ignored.
$t->post_ok("/api/v1/admin/roles/not-a-real-role/permissions/audit.view" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(404);
$t->post_ok("/api/v1/admin/roles/$role_name/permissions/not.a.real.permission" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(404);

# --- Revoke the permission -- capability check flips back to false ---
$t->delete_ok("/api/v1/admin/roles/$role_name/permissions/audit.view" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200)->json_is('/ok', 1);
$t->get_ok("/api/v1/auth/introspect?capability=audit.view" => { Authorization => "Bearer $plain_jwt" })
  ->status_is(200)->json_is('/has_capability', 0);

# --- Protected roles cannot be deleted, cleanly, not silently ---
$t->delete_ok('/api/v1/admin/roles/user' => { Authorization => "Bearer $admin_jwt" })->status_is(400);
$t->delete_ok('/api/v1/admin/roles/site_admin' => { Authorization => "Bearer $admin_jwt" })->status_is(400);
{
    my $still_there = $t->app->pg->db->query(q{SELECT 1 FROM api.roles WHERE name = 'user'})->hash;
    ok($still_there, 'the protected role really is still there, not deleted then reported as an error');
}

# --- The non-protected test role CAN be deleted ---
$t->delete_ok("/api/v1/admin/roles/$role_name" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200)->json_is('/ok', 1);
$t->get_ok('/api/v1/admin/roles' => { Authorization => "Bearer $admin_jwt" })->status_is(200);
ok(!(grep { $_->{name} eq $role_name } @{ $t->tx->res->json }), 'deleted role is really gone');

# Deleting a nonexistent role is a clean 404, not a 200 no-op.
$t->delete_ok("/api/v1/admin/roles/$role_name" => { Authorization => "Bearer $admin_jwt" })->status_is(404);

done_testing;
