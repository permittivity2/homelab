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
use FindBin;
use lib "$FindBin::Bin/../../common/t/lib";
use TestAccounts qw(track_account);
my $t = Test::Mojo->new('Homelab::API::App');

my $suffix = time . '-' . $$;

# Account clean-up is shared -- see t/lib/TestAccounts.pm. This file used
# to carry its own copy of the END block; a security clean-up is the last
# thing that should exist in more than one implementation.

my ($email, $password)       = ("sess-$suffix\@test.mailmasker.org", 'SessTest1Aa!!');
my ($other_email, $other_pw) = ("sess-other-$suffix\@test.mailmasker.org", 'SessOther1Aa!!');
my ($admin_email, $admin_pw) = ("sess-admin-$suffix\@test.mailmasker.org", 'SessAdmin1Aa!!');

track_account($t->app, $email, $other_email, $admin_email);
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
    track_account($t->app, $marker_email);
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

# --- ?except_current=false: revoke EVERYTHING, including this token.
# This is what makes single-logout work: homelab-sso gives every relying
# party its OWN independently issued token pair, so a logout that revoked
# only the IdP session's refresh token left drive/webmail/myaccount fully
# usable. Three sessions here stand in for three apps. ---
{
    my $all_email = "sess-all-$suffix\@test.mailmasker.org";
    track_account($t->app, $all_email);
    $t->post_ok('/api/v1/auth/register', json => { email => $all_email, password => 'AllTest1Aa!!' })->status_is(201);
    my @jwts;
    for (1 .. 3) {
        $t->post_ok('/api/v1/auth/login', json => { email => $all_email, password => 'AllTest1Aa!!' })->status_is(200);
        push @jwts, $t->tx->res->json('/token');
    }

    $t->get_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $jwts[2]" })->status_is(200);
    is(scalar(@{ $t->tx->res->json }), 3, 'sanity: three live sessions, one per "app"');

    $t->delete_ok('/api/v1/auth/sessions?except_current=false' => { Authorization => "Bearer $jwts[2]" })
      ->status_is(200)->json_is('/revoked', 3, 'all three sessions revoked, the caller\'s own included');

    # Every one of them, not just the two others.
    for my $i (0 .. 2) {
        $t->get_ok('/api/v1/auth/introspect' => { Authorization => "Bearer $jwts[$i]" })
          ->status_is(401, "session $i is dead after a revoke-all");
    }

    # Idempotent: a second logout (double-click, or two apps each fanning
    # out) must not error, just report nothing left to revoke. It needs a
    # live token to authenticate with, so log in once more.
    $t->post_ok('/api/v1/auth/login', json => { email => $all_email, password => 'AllTest1Aa!!' })->status_is(200);
    my $fresh = $t->tx->res->json('/token');
    $t->delete_ok('/api/v1/auth/sessions?except_current=false' => { Authorization => "Bearer $fresh" })
      ->status_is(200)->json_is('/revoked', 1, 'only the one live session was left to revoke');
    $t->delete_ok('/api/v1/auth/sessions?except_current=false' => { Authorization => "Bearer $fresh" })
      ->status_is(401, 'a second revoke-all with the now-dead token is a clean 401, not a 500');
}

# --- except_current must be explicit. The two behaviours differ by
# exactly "does this also end the session you are holding", so an omitted
# or garbage value is a 400 rather than either default. ---
$t->delete_ok('/api/v1/auth/sessions' => { Authorization => "Bearer $admin_jwt" })
  ->status_is(400, 'DELETE /auth/sessions with no except_current param is rejected, not treated as "revoke everything"');
$t->delete_ok('/api/v1/auth/sessions?except_current=yes' => { Authorization => "Bearer $admin_jwt" })
  ->status_is(400, 'a non-true/false except_current is rejected rather than coerced');

# --- Refresh-token rotation: a LOST RESPONSE must be recoverable ---------
#
# The server commits a rotation and the client never learns the result (a
# request timeout, a reset connection, a killed process). The old token is
# revoked and the new one was never received. For a human that is one
# re-login; for homelab-agent, which holds no password, it was PERMANENT --
# and it locked out 14 of 51 fleet nodes on 2026-10-28/29, the certificate
# issuer among them, unnoticed for up to 4.4 days (post-cutover items 36, 37).
#
# So a consumed token has a short grace window in which presenting it again
# returns THE SAME successor. These subtests are mostly about the four ways
# that must NOT work, because the whole risk of the change is softening
# single-use too far.
subtest 'a rotation whose response was lost can be retried' => sub {
    my ($ge, $gp) = ("sess-grace-$suffix\@test.mailmasker.org", 'GraceTest1Aa!!');
    track_account($t->app, $ge);
    $t->post_ok('/api/v1/auth/register', json => { email => $ge, password => $gp })->status_is(201);
    $t->post_ok('/api/v1/auth/login', json => { email => $ge, password => $gp })->status_is(200);
    my $first = $t->tx->res->json('/refresh_token');

    # The rotation the "client" is about to lose the response to.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $first })->status_is(200);
    my $successor = $t->tx->res->json('/refresh_token');
    my $sess_before = $t->app->pg->db->query(
        'SELECT count(*) AS n FROM api.sessions s JOIN api.users u ON u.id = s.user_id WHERE u.email = ?', $ge)->hash->{n};

    # Retrying the consumed token hands back the SAME successor...
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $first })
      ->status_is(200, 'the consumed token is accepted inside the grace window')
      ->json_is('/recovered' => 1, 'and says so')
      ->json_is('/refresh_token' => $successor, 'returning the same successor, not a new one');

    # ...and mints nothing, so a client stuck retrying converges instead of
    # generating sessions.
    my $sess_after = $t->app->pg->db->query(
        'SELECT count(*) AS n FROM api.sessions s JOIN api.users u ON u.id = s.user_id WHERE u.email = ?', $ge)->hash->{n};
    is $sess_after, $sess_before, 'the grace path creates no session';

    # The token it handed back is the live one and still works.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $successor })
      ->status_is(200, 'the recovered successor is genuinely usable');
    my $third = $t->tx->res->json('/refresh_token');

    # Now that the successor HAS been rotated on, the original is a genuinely
    # stale token -- reuse detection has to reassert itself even though we are
    # still inside the window.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $first })
      ->status_is(401, 'once the successor is itself consumed, the original is refused again');

    # Outside the window: aged by hand rather than by sleeping.
    $t->app->pg->db->query(
        q{UPDATE api.refresh_tokens SET rotated_at = NOW() - INTERVAL '1 day' WHERE token = ?}, $successor);
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $successor })
      ->status_is(401, 'a rotation older than the grace window is refused');

    # LOGOUT MUST STAY FINAL. A token revoked by logout records no successor,
    # which is exactly what distinguishes it from a rotation -- otherwise this
    # change would quietly have made logging out take five minutes.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $third })->status_is(200);
    my $live = $t->tx->res->json('/refresh_token');
    $t->post_ok('/api/v1/auth/logout', json => { refresh_token => $live })->status_is(200);
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => $live })
      ->status_is(401, 'a token revoked by logout is NOT recoverable, grace window or not');
    my $succ = $t->app->pg->db->query(
        'SELECT successor_id FROM api.refresh_tokens WHERE token = ?', $live)->hash;
    is $succ->{successor_id}, undef, 'logout records no successor, which is what keeps it final';

    # And a token nobody ever issued is still a flat refusal.
    $t->post_ok('/api/v1/auth/refresh', json => { refresh_token => 'not-a-real-token-at-all' })
      ->status_is(401, 'an unknown token is refused');
};

# --- Rotation is atomic -----------------------------------------------------
# Before 0.1.x these were separate autocommitted statements, so a crash
# mid-rotation could leave a revoked token with no successor at all -- the one
# case the grace window cannot repair, because there is nothing to hand back.
# The observable guarantee: every rotated token points at a successor that
# really exists.
subtest 'every rotation leaves a successor that exists' => sub {
    my $orphans = $t->app->pg->db->query(
        q{SELECT count(*) AS n FROM api.refresh_tokens rt
          WHERE rt.rotated_at IS NOT NULL
            AND (rt.successor_id IS NULL
                 OR NOT EXISTS (SELECT 1 FROM api.refresh_tokens s WHERE s.id = rt.successor_id))},
    )->hash->{n};
    is $orphans, 0, 'no rotated token points at a missing successor';
};

done_testing;
