use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;

# Full integration test against a real Postgres AND a real, reachable
# homelab-api (same "no mocks" convention as domain-admin/t/basic.t and
# api/t/gateway.t) -- point HOMELAB_INVITE_CONFIG at a real, already-
# deployed config.yml.
unless ($ENV{HOMELAB_INVITE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_INVITE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Invite::App');

$t->get_ok('/internal/v1/invites')->status_is(401, 'no Authorization header -> 401');

my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;

my $sender_email    = 'e2e-invite-sender-' . time . '-' . $$ . '@test.mailmasker.org';
my $sender_password = 'InviteSenderTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $sender_email, password => $sender_password });
my $sender_jwt = $ua->post("$api_base/api/v1/auth/login" => json => { email => $sender_email, password => $sender_password })
    ->res->json('/token');
ok($sender_jwt, 'got a real JWT for the sending account') or BAIL_OUT('cannot continue without a real login');
my $sender_auth = { Authorization => "Bearer $sender_jwt" };

my $recipient = 'e2e-invite-recipient-' . time . '-' . $$ . '@test.mailmasker.org';

# --- Create + dedup ---------------------------------------------------
my $created = $t->post_ok('/internal/v1/invites' => $sender_auth => json => { recipient_email => $recipient, channel => 'roundcube_plugin' })
    ->status_is(201, 'sender can create an invite with no special role')
    ->json_has('/token')
    ->json_has('/url')
    ->tx->res->json;
ok(length($created->{token}) == 64, 'token is a 64-hex-char (32 byte) value');

$t->post_ok('/internal/v1/invites' => $sender_auth => json => { recipient_email => $recipient, channel => 'roundcube_plugin' })
    ->status_is(409, 'a second invite to the same pending recipient is rejected, not duplicated');

# --- List (self-service vs admin) --------------------------------------
my $mine = $t->get_ok('/internal/v1/invites' => $sender_auth)->status_is(200)->tx->res->json;
ok((grep { $_->{token} eq $created->{token} } @$mine), 'list (no ?all) includes the invite just created');

$t->get_ok('/internal/v1/invites?all=true' => $sender_auth)
    ->status_is(403, '?all=true without site_admin is a clean 403');

# --- Grant site_admin (same direct-SQL technique domain-admin/t/basic.t
# and api/t/admin.t already use -- no self-service "become an admin" API
# by design). Also grant system_agent to a SECOND throwaway account, for
# the /consume test below (that route requires system_agent, not a
# normal user's JWT, and there's no self-service way to get one either).
my $admin_email    = 'e2e-invite-admin-' . time . '-' . $$ . '@test.mailmasker.org';
my $admin_password = 'InviteAdminTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $admin_email, password => $admin_password });
my $admin_jwt = $ua->post("$api_base/api/v1/auth/login" => json => { email => $admin_email, password => $admin_password })
    ->res->json('/token');
my $admin_auth = { Authorization => "Bearer $admin_jwt" };

my $agent_email    = 'e2e-invite-agent-' . time . '-' . $$ . '@test.mailmasker.org';
my $agent_password = 'InviteAgentTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $agent_email, password => $agent_password });
my $agent_jwt = $ua->post("$api_base/api/v1/auth/login" => json => { email => $agent_email, password => $agent_password })
    ->res->json('/token');
my $agent_auth = { Authorization => "Bearer $agent_jwt" };

for my $pair ([$admin_email, 'site_admin'], [$agent_email, 'system_agent']) {
    my ($email, $role) = @$pair;
    my $sql = "INSERT INTO api.user_roles (user_id, role_id) " .
        "SELECT u.id, r.id FROM api.users u, api.roles r WHERE u.email = '$email' AND r.name = '$role'";
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
    die "could not grant $role to $email for testing (needs passwordless sudo to postgres) -- see t/basic.t\n" if $? != 0;
}

$t->get_ok('/internal/v1/invites?all=true' => $admin_auth)
    ->status_is(200, 'a real site_admin can list every invite, not just their own');

# --- Quota (site_admin only) -------------------------------------------
$t->get_ok('/internal/v1/invites/quota' => $sender_auth)
    ->status_is(200, 'any authenticated user can see their OWN effective quota')
    ->json_has('/max_pending')->json_has('/max_per_day');

$t->put_ok("/internal/v1/invites/quota/$sender_email" => $sender_auth => json => { max_pending => 3, max_per_day => 2 })
    ->status_is(403, 'a non-admin cannot set anyone\'s quota, even their own');

$t->put_ok("/internal/v1/invites/quota/$sender_email" => $admin_auth => json => { max_pending => 3, max_per_day => 2 })
    ->status_is(200, 'site_admin can set a per-sender quota override')
    ->json_is('/max_pending', 3)->json_is('/max_per_day', 2);

# --- Consume: atomic one-time-use (server-to-server, system_agent) -----
my $second_recipient = 'e2e-invite-consume-' . time . '-' . $$ . '@test.mailmasker.org';
my $consumable = $t->post_ok('/internal/v1/invites' => $sender_auth => json => { recipient_email => $second_recipient, channel => 'roundcube_plugin' })
    ->status_is(201)->tx->res->json;

$t->post_ok('/internal/v1/invites/consume' => $sender_auth => json => { token => $consumable->{token}, email => $second_recipient })
    ->status_is(403, 'a normal user JWT (even the invite\'s own sender) cannot call consume -- system_agent only');

$t->post_ok('/internal/v1/invites/consume' => $agent_auth => json => { token => $consumable->{token}, email => 'wrong@test.mailmasker.org' })
    ->status_is(403, 'consume rejects an email that does not match the invite\'s own recipient_email');

$t->post_ok('/internal/v1/invites/consume' => $agent_auth => json => { token => $consumable->{token}, email => $second_recipient })
    ->status_is(200, 'consume succeeds the first time')
    ->json_is('/ok', 1);

$t->post_ok('/internal/v1/invites/consume' => $agent_auth => json => { token => $consumable->{token}, email => $second_recipient })
    ->status_is(409, 'consuming the SAME token a second time never succeeds twice -- the one-time-use guarantee');

# --- Public acceptance page ---------------------------------------------
$t->get_ok("/invite/$consumable->{token}")
    ->status_is(410, 'the public page for an already-consumed token reports it as no longer valid, not a 200');

$t->get_ok('/invite/not-a-real-token-at-all')
    ->status_is(404, 'a garbage token is a clean 404, not a 500 or a leaked stack trace');

# --- Revoke -------------------------------------------------------------
my $third_recipient = 'e2e-invite-revoke-' . time . '-' . $$ . '@test.mailmasker.org';
my $revocable = $t->post_ok('/internal/v1/invites' => $sender_auth => json => { recipient_email => $third_recipient, channel => 'roundcube_plugin' })
    ->status_is(201)->tx->res->json;

$t->delete_ok("/internal/v1/invites/$revocable->{id}" => $sender_auth)
    ->status_is(200, 'the sender can revoke their own pending invite');
$t->delete_ok("/internal/v1/invites/$revocable->{id}" => $sender_auth)
    ->status_is(404, 'revoking an already-revoked (no longer pending) invite is a clean 404, not a silent no-op success');

done_testing;
