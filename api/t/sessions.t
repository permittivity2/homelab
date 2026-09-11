use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres — same
# HOMELAB_API_CONFIG convention as t/basic.t and t/admin.t.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

my $suffix = time . '-' . $$;
my ($email, $password)       = ("sess-$suffix\@test.mailmasker.org", 'SessTest1Aa!!');
my ($other_email, $other_pw) = ("sess-other-$suffix\@test.mailmasker.org", 'SessOther1Aa!!');
my ($admin_email, $admin_pw) = ("sess-admin-$suffix\@test.mailmasker.org", 'SessAdmin1Aa!!');

$t->post_ok('/api/v1/auth/register', json => { email => $email, password => $password })->status_is(201);
$t->post_ok('/api/v1/auth/register', json => { email => $other_email, password => $other_pw })->status_is(201);
$t->post_ok('/api/v1/auth/register', json => { email => $admin_email, password => $admin_pw })->status_is(201);
{
    my $user_id = $t->app->pg->db->query('SELECT id FROM api.users WHERE email = ?', $admin_email)->hash->{id};
    my $role_id = $t->app->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'site_admin'})->hash->{id};
    $t->app->pg->db->query('INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?)', $user_id, $role_id);
}

# --- Capture: auto-detected User-Agent, and the 'unknown' fallback ---
$t->post_ok('/api/v1/auth/login' => { 'User-Agent' => 'sessions.t-test-agent/1.0' }, json => { email => $email, password => $password })
  ->status_is(200);
my $jwt           = $t->tx->res->json('/token');
my $refresh_token = $t->tx->res->json('/refresh_token');
my $jti           = $t->app->pg->db->query('SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?', $refresh_token)->hash->{jti};

my $row = $t->app->pg->db->query('SELECT user_agent, ip_address, first_seen_at FROM api.sessions WHERE jti = ?', $jti)->hash;
is($row->{user_agent}, 'sessions.t-test-agent/1.0', 'login captures the real User-Agent header');
ok($row->{ip_address}, 'login captures a non-empty ip_address (via $c->tx->remote_address)');
ok($row->{first_seen_at}, 'login sets first_seen_at');

# An explicitly-empty client_user_agent override (same code path a
# missing/absent real header takes) falls back to the literal string
# 'unknown', never NULL or an empty string.
$t->post_ok('/api/v1/auth/login', json => { email => $email, password => $password, client_user_agent => '' })
  ->status_is(200);
my $jti2 = $t->app->pg->db->query(
    'SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?',
    $t->tx->res->json('/refresh_token'),
)->hash->{jti};
is(
    $t->app->pg->db->query('SELECT user_agent FROM api.sessions WHERE jti = ?', $jti2)->hash->{user_agent},
    'unknown', "an empty/missing User-Agent is stored as the literal string 'unknown', never NULL",
);

# --- Override: client_user_agent/client_ip win over auto-detected
# values -- this is the exact mechanism homelab-sso's authorize_submit
# relies on to relay the real submitting browser's own values instead
# of sso's own backend HTTP client's. ---
$t->post_ok(
    '/api/v1/auth/login' => { 'User-Agent' => 'should-be-overridden/1.0' },
    json => { email => $email, password => $password, client_user_agent => 'Mozilla/5.0 (real browser)', client_ip => '203.0.113.42' },
)->status_is(200);
my $jti3 = $t->app->pg->db->query(
    'SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?',
    $t->tx->res->json('/refresh_token'),
)->hash->{jti};
my $row3 = $t->app->pg->db->query('SELECT user_agent, ip_address FROM api.sessions WHERE jti = ?', $jti3)->hash;
is($row3->{user_agent}, 'Mozilla/5.0 (real browser)', 'client_user_agent override wins over the raw header');
is($row3->{ip_address}, '203.0.113.42', 'client_ip override wins over $c->tx->remote_address');

# --- Refresh carries the OLD session's metadata forward, never
# recaptures fresh values -- this is what makes a silently-auto-
# refreshed long-lived session stay correctly attributed to whatever
# actually logged in, instead of looking like a series of unrelated
# logins from wherever each refresh call happened to originate. ---
{
    my $before = $t->app->pg->db->query('SELECT user_agent, ip_address, first_seen_at FROM api.sessions WHERE jti = ?', $jti3)->hash;

    $t->post_ok('/api/v1/auth/refresh' => { 'User-Agent' => 'refresh-caller-should-be-ignored/1.0' }, json => { refresh_token => $t->tx->res->json('/refresh_token') })
      ->status_is(200);
    my $new_jti = $t->app->pg->db->query(
        'SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?',
        $t->tx->res->json('/refresh_token'),
    )->hash->{jti};
    my $after = $t->app->pg->db->query('SELECT user_agent, ip_address, first_seen_at FROM api.sessions WHERE jti = ?', $new_jti)->hash;

    is($after->{user_agent}, $before->{user_agent}, 'refresh carries user_agent forward from the old session, not a fresh capture');
    is($after->{ip_address}, $before->{ip_address}, 'refresh carries ip_address forward from the old session');
    is($after->{first_seen_at}, $before->{first_seen_at}, 'refresh preserves the ORIGINAL first_seen_at (the new row is not a fresh "login")');
}

# --- List: self-service, includes `current`, never leaks another
# user's sessions ---
$t->get_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $jwt" })
  ->status_is(200);
my $listed = $t->tx->res->json;
ok((grep { $_->{jti} eq $jti } @$listed), 'sessions list includes the session used to log in earlier in this run')
    or diag explain $listed;

# The JWT used to make the list call itself should be marked current --
# use a fresh single-session account for an unambiguous check (the
# account above now has several live sessions from the capture tests).
$t->post_ok('/api/v1/auth/login', json => { email => $other_email, password => $other_pw })->status_is(200);
my $other_jwt = $t->tx->res->json('/token');
$t->get_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $other_jwt" })->status_is(200);
my $other_listed = $t->tx->res->json;
is(scalar(@$other_listed), 1, 'a fresh single-login account lists exactly one session');
ok($other_listed->[0]{current}, 'that one session is marked current (it is the very token used for this call)');

# --- ?user= scoping: 403 for a non-admin, honored for site_admin ---
$t->get_ok("/api/v1/auth/sessions?user=$email" => { Authorization => "Bearer $other_jwt" })
  ->status_is(403, 'a non-admin explicitly passing ?user= for someone else gets a clean 403, not a silently-scoped-down result');

$t->post_ok('/api/v1/auth/login', json => { email => $admin_email, password => $admin_pw })->status_is(200);
my $admin_jwt = $t->tx->res->json('/token');
$t->get_ok("/api/v1/auth/sessions?user=$other_email" => { Authorization => "Bearer $admin_jwt" })
  ->status_is(200);
my $admin_view = $t->tx->res->json;
ok((grep { $_->{jti} } @$admin_view), 'site_admin can list another user\'s sessions via ?user=')
    or diag explain $admin_view;
ok(!(grep { $_->{current} } @$admin_view), 'none of THOSE rows are marked current -- current is relative to the caller\'s own token, not the viewed user\'s');

# --- Revoke: the actual "force re-login" property. Must survive the
# CLI's own 401-refresh-retry -- i.e. killing the refresh_token too, not
# just flipping the session's revoked flag. ---
{
    $t->post_ok('/api/v1/auth/login', json => { email => $email, password => $password })->status_is(200);
    my $victim_jwt           = $t->tx->res->json('/token');
    my $victim_refresh_token = $t->tx->res->json('/refresh_token');
    my $victim_jti           = $t->app->pg->db->query(
        'SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?',
        $victim_refresh_token,
    )->hash->{jti};

    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $victim_jwt" })
      ->status_is(200, 'sanity: the session is genuinely valid before revoke');

    # Another user cannot revoke it by jti guess.
    $t->delete_ok("/api/v1/auth/sessions/$victim_jti" => { Authorization => "Bearer $other_jwt" })
      ->status_is(404, 'a session id scoped to a DIFFERENT user 404s, not 200 -- the WHERE clause itself enforces ownership');

    $t->delete_ok("/api/v1/auth/sessions/$victim_jti" => { Authorization => "Bearer $jwt" })
      ->status_is(200, 'the owner can revoke their own session');

    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $victim_jwt" })
      ->status_is(401, 'introspect fails IMMEDIATELY after revoke, however much of the JWT\'s own exp window is left');

    # The critical correctness property: the refresh_token must ALSO be
    # dead, or homelab-cli's own 401-auto-refresh would silently mint a
    # brand new, perfectly valid session right back -- making this
    # entire revoke endpoint a no-op against the client this ecosystem
    # actually ships.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $victim_refresh_token })
      ->status_is(401, 'the refresh_token is ALSO revoked -- a client with auto-refresh-on-401 cannot silently undo this revoke');

    # Revoking an already-revoked session is a clean 404, not a 500 or a
    # silent no-op success.
    $t->delete_ok("/api/v1/auth/sessions/$victim_jti" => { Authorization => "Bearer $jwt" })
      ->status_is(404, 'revoking an already-revoked session 404s');
}

# --- site_admin can revoke another user's session via ?user= ---
{
    $t->post_ok('/api/v1/auth/login', json => { email => $other_email, password => $other_pw })->status_is(200);
    my $target_jwt = $t->tx->res->json('/token');
    my $target_jti = $t->app->pg->db->query(
        'SELECT jti FROM api.refresh_tokens rt JOIN api.sessions s ON s.refresh_token_id = rt.id WHERE rt.token = ?',
        $t->tx->res->json('/refresh_token'),
    )->hash->{jti};

    $t->delete_ok("/api/v1/auth/sessions/$target_jti?user=$other_email" => { Authorization => "Bearer $admin_jwt" })
      ->status_is(200, 'site_admin can revoke another user\'s session via ?user=');
    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $target_jwt" })
      ->status_is(401, 'the revoked user\'s JWT is now dead too');
}

# --- ?except_current=true: revoke every other session, keep this one ---
{
    my $marker_email = "sess-bulk-$suffix\@test.mailmasker.org";
    $t->post_ok('/api/v1/auth/register', json => { email => $marker_email, password => 'BulkTest1Aa!!' })->status_is(201);
    $t->post_ok('/api/v1/auth/login', json => { email => $marker_email, password => 'BulkTest1Aa!!' })->status_is(200);
    my $first_jwt = $t->tx->res->json('/token');
    $t->post_ok('/api/v1/auth/login', json => { email => $marker_email, password => 'BulkTest1Aa!!' })->status_is(200);
    my $second_jwt = $t->tx->res->json('/token');

    $t->get_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $second_jwt" })->status_is(200);
    is(scalar(@{ $t->tx->res->json }), 2, 'sanity: two live sessions before the bulk revoke');

    $t->delete_ok('/api/v1/auth/sessions?except_current=true' => { Authorization => "Bearer $second_jwt" })
      ->status_is(200)->json_is('/revoked', 1, 'exactly the one OTHER session was revoked');

    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $first_jwt" })
      ->status_is(401, 'the other session is genuinely dead');
    $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $second_jwt" })
      ->status_is(200, 'the CURRENT session survives its own bulk-revoke-others call');
}

# --- Missing except_current=true on the bulk route is a clean 400, not
# an accidental full-account wipe ---
$t->delete_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $admin_jwt" })
  ->status_is(400, 'DELETE /auth/sessions with no except_current=true param is rejected, not treated as "revoke everything"');

done_testing;
