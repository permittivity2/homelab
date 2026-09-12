package Homelab::API::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::API::Auth qw(hash_password verify_password generate_jwt verify_jwt generate_jti generate_refresh_token);
use Homelab::API::Registry;
use Homelab::Common::Proxy qw(forward);
use Homelab::Common::AuditClient qw(enqueue);

has 'pg';
has 'registry';

sub startup ($self) {
    my $config = load_config('HOMELAB_API_CONFIG', '/etc/homelab/api/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:3000'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/api-hypnotoad.pid',
        workers  => $srv->{workers} // 4,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->registry(Homelab::API::Registry->new(pg => $self->pg));

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $r = $self->routes;

    # --- Auth ---------------------------------------------------------
    $r->post('/api/v1/auth/register' => sub ($c) { $self->_register($c) });
    $r->post('/api/v1/auth/login'    => sub ($c) { $self->_login($c) });
    $r->get('/api/v1/auth/introspect' => sub ($c) { $self->_introspect($c) });
    $r->post('/api/v1/auth/refresh'  => sub ($c) { $self->_refresh($c) });
    $r->post('/api/v1/auth/logout'   => sub ($c) { $self->_logout($c) });

    # Session visibility/revocation -- JWT-only for the caller's own
    # (?user= honored only for site_admin, see _sessions_scope_target
    # below). Two DELETE routes coexist fine (no *capture wildcard
    # involved, unlike the gateway routes above) since one has a jti path
    # segment and the other doesn't.
    $r->get('/api/v1/auth/sessions'          => sub ($c) { $self->_sessions_list($c) });
    $r->delete('/api/v1/auth/sessions'       => sub ($c) { $self->_sessions_revoke_others($c) });
    $r->delete('/api/v1/auth/sessions/:jti'  => sub ($c) { $self->_sessions_revoke($c) });

    # --- Service registry (see Homelab::Common::Registry — this is what
    # every OTHER feature's register()/lookup() calls hit) ------------
    $r->post('/api/v1/registry/register' => sub ($c) { $self->_registry_register($c) });
    $r->get('/api/v1/registry'           => sub ($c) { $self->_registry_list($c) });
    $r->get('/api/v1/registry/:feature'  => sub ($c) { $self->_registry_lookup($c) });

    # --- Admin (site_admin role required — see migrations/003-rbac.sql's
    # own comment: admin routes are deliberately hardcoded role checks,
    # not gated by a separate permissions table, so a bad row edit can't
    # lock every admin out at once). This is what homelab-cli's `admin`
    # subcommands talk to. ------------------------------------------
    $r->get('/api/v1/admin/users'                => sub ($c) { $self->_admin_list_users($c) });
    $r->post('/api/v1/admin/users/:id/roles'     => sub ($c) { $self->_admin_grant_role($c) });
    $r->delete('/api/v1/admin/users/:id/roles/:role' => sub ($c) { $self->_admin_revoke_role($c) });

    # --- Role/permission management (fast-follow to 003-rbac.sql's own
    # "no per-endpoint role_permissions table yet" comment -- see
    # migrations/008-role-permissions.sql and _has_capability below).
    # Still deliberately site_admin-only, same as the routes above: role/
    # permission management is itself an admin action. [role/permission
    # => qr/[^\/]+/] matches this file's existing placeholder-dot-
    # truncation fix elsewhere in this codebase (Mojolicious's default
    # :name pattern excludes "." for format-detection reservation, which
    # would otherwise silently truncate a capability like "audit.view"
    # to "audit") -- applied here proactively, not after hitting the
    # same bug a second time. ---------------------------------------
    $r->get('/api/v1/admin/roles'    => sub ($c) { $self->_admin_list_roles($c) });
    $r->post('/api/v1/admin/roles'   => sub ($c) { $self->_admin_create_role($c) });
    $r->delete('/api/v1/admin/roles/:name' => [name => qr/[^\/]+/] => sub ($c) { $self->_admin_delete_role($c) });
    $r->get('/api/v1/admin/permissions' => sub ($c) { $self->_admin_list_permissions($c) });
    $r->post('/api/v1/admin/roles/:role/permissions/:permission' => [role => qr/[^\/]+/, permission => qr/[^\/]+/]
        => sub ($c) { $self->_admin_grant_permission($c) });
    $r->delete('/api/v1/admin/roles/:role/permissions/:permission' => [role => qr/[^\/]+/, permission => qr/[^\/]+/]
        => sub ($c) { $self->_admin_revoke_permission($c) });

    # --- Gateway: the ONLY address a client (homelab-cli, or any
    # third-party script) should ever need -- see ../../CLAUDE.md's "one
    # API" design notes and Homelab::Common::Proxy's own docs. Auth is
    # NOT re-checked here: the Authorization header forwards through
    # unchanged, and each backend (homelab-drive, homelab-mailbridge)
    # already re-verifies it independently via its own introspect()
    # call -- same "verify at every hop" convention used everywhere else
    # in this codebase, not a gap. Uses $self->registry directly (this
    # app's own in-process DB access -- see Homelab::API::Registry)
    # rather than round-tripping over its own HTTP API just to read its
    # own database.
    #
    # *capture (not *path) -- "path" is a reserved Mojolicious stash key
    # and silently breaks route registration if used as a placeholder
    # name (caught by t/gateway.t, not by inspection).
    #
    # homelab-drive keeps its own /api/v1/files etc. paths (that's its
    # real, standalone API) -- /drive/ exists only in the gateway's
    # own client-facing namespace, sitting where /api/v1 already was,
    # so a client path of /api/v1/drive/files needs strip_prefix
    # (removes "/api/v1/drive") *and* backend_prefix (adds "/api/v1"
    # back) to land on drive's real /api/v1/files -- not a plain
    # prefix strip alone (a real bug caught by an actual `homelab-cli
    # drive list` call, not by common/t/proxy.t's simpler fake
    # backend paths -- see Homelab::Common::Proxy's own docs).
    # homelab-mailbridge's routes are deliberately already
    # /api/v1/mail/... themselves (it only exists to back this
    # gateway), so nothing needs rewriting for that one.
    $r->any('/api/v1/drive/*capture' => sub ($c) { $self->_gateway($c, 'homelab-drive', strip_prefix => '/api/v1/drive', backend_prefix => '/api/v1') });
    $r->any('/api/v1/mail/*capture'  => sub ($c) { $self->_gateway($c, 'homelab-mailbridge') });
    # homelab-domain-admin's own routes are already /internal/v1/domains/...
    # -- note they KEEP the "domains" segment, unlike drive (whose
    # client-facing "/drive" marker disappears entirely on the backend
    # side, landing on plain /api/v1/files). So the right transform
    # strips only "/api/v1" (not "/api/v1/domains") and re-adds
    # "/internal/v1" -- e.g. client /api/v1/domains/x/dns/records ->
    # backend /internal/v1/domains/x/dns/records, "domains" intact both
    # sides. Getting this wrong (stripping "/api/v1/domains" the way
    # drive strips "/api/v1/drive") silently drops "domains" and lands
    # on the wrong backend path -- caught by an actual `homelab-cli dns
    # domains list` call, not by inspection.
    #
    # TWO routes, not one: a *wildcard placeholder requires at least one
    # captured character after its own leading "/", so
    # "/api/v1/domains/*capture" alone never matches the bare
    # "/api/v1/domains" (list/create) -- unlike drive/mail, which never
    # have a bare top-level resource with nothing after the prefix.
    # Caught the same way (a raw Mojolicious 404, not even reaching
    # _gateway) -- see t/gateway.t.
    $r->any('/api/v1/domains' => sub ($c) { $self->_gateway($c, 'homelab-domain-admin', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });
    $r->any('/api/v1/domains/*capture' => sub ($c) { $self->_gateway($c, 'homelab-domain-admin', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });

    # homelab-worker's own routes are already /internal/v1/jobs/... --
    # same strip-"/api/v1"-then-reprepend-"/internal/v1" transform as
    # /api/v1/domains above (client /api/v1/jobs -> backend
    # /internal/v1/jobs, "jobs" intact both sides), and the same
    # two-routes-not-one requirement for the same reason (a *capture
    # wildcard never matches the bare "/api/v1/jobs" with nothing after
    # it -- see t/gateway.t). homelab-drive itself talks to
    # homelab-worker directly (not through this gateway) when building a
    # zip job's manifest and forwarding the user's JWT -- this route is
    # for homelab-cli's own `jobs list/show/download` commands.
    $r->any('/api/v1/jobs' => sub ($c) { $self->_gateway($c, 'homelab-worker', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });
    $r->any('/api/v1/jobs/*capture' => sub ($c) { $self->_gateway($c, 'homelab-worker', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });

    # homelab-audit's own route is /internal/v1/audit/log -- same
    # two-registration requirement as jobs/domains above (a *capture
    # wildcard never matches the bare prefix with nothing after it).
    $r->any('/api/v1/audit' => sub ($c) { $self->_gateway($c, 'homelab-audit', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });
    $r->any('/api/v1/audit/*capture' => sub ($c) { $self->_gateway($c, 'homelab-audit', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });

    return;
}

sub _gateway ($self, $c, $feature_name, %opts) {
    my $entry = $self->registry->lookup($feature_name);
    unless ($entry && $entry->{host} && $entry->{port}) {
        return $c->render(json => { error => "$feature_name is not currently available" }, status => 502);
    }
    return forward($c, feature_name => $feature_name, host => $entry->{host}, port => $entry->{port}, %opts);
}

# Rate limiting + a structured, queryable log of every auth attempt --
# see migrations/006-login-attempts.sql for why this is a real table
# rather than app log lines. Threshold/window deliberately generous (10
# failures / 15 minutes) -- this is throttling credential stuffing, not
# rate-limiting a legitimate user who mistyped a password twice.
#
# IMPORTANT: relies on $c->tx->remote_address resolving to the real
# client IP, not homelab-webproxy's own loopback address -- only true
# when MOJO_REVERSE_PROXY=1 is set (see systemd/homelab-api.service)
# AND homelab-webproxy is actually the only thing that can reach this
# service (homelab-api binds 127.0.0.1 only). Without both of those
# holding, every request looks like it came from 127.0.0.1 and this
# rate-limits the whole service as a single client instead of per
# attacker -- fails toward "too strict for everyone" in that case, not
# toward silently doing nothing.
use constant RATE_LIMIT_MAX_FAILURES => 10;
use constant RATE_LIMIT_WINDOW_MIN   => 15;

sub _rate_limited ($self, $ip) {
    my $count = $self->pg->db->query(
        q{SELECT count(*) AS n FROM api.login_attempts
          WHERE ip = ? AND success = FALSE AND attempted_at > NOW() - (? * INTERVAL '1 minute')},
        $ip, RATE_LIMIT_WINDOW_MIN,
    )->hash->{n};
    return $count >= RATE_LIMIT_MAX_FAILURES;
}

sub _log_attempt ($self, %fields) {
    $self->pg->db->query(
        'INSERT INTO api.login_attempts (ip, email, endpoint, success) VALUES (?, ?, ?, ?)',
        @fields{qw(ip email endpoint success)},
    );
}

# POST /api/v1/auth/register {email, password}
# Deliberately open (no auth required) for now — this is a test/dev
# domain (test.mailmasker.org) and the fastest path to real test
# accounts. Revisit (admin-only, or an invite flow) before this is ever
# pointed at anything resembling production.
sub _register ($self, $c) {
    my $body     = $c->req->json // {};
    my $email    = $body->{email};
    my $password = $body->{password};
    my $ip       = $c->tx->remote_address;

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    if ($self->_rate_limited($ip)) {
        return $c->render(json => { error => 'Too many attempts. Please wait 15 minutes.' }, status => 429);
    }

    my $existing = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash;
    if ($existing) {
        $self->_log_attempt(ip => $ip, email => $email, endpoint => 'register', success => 0);
        return $c->render(json => { error => 'email already registered' }, status => 409);
    }

    my $hash = hash_password($password);
    my $user = $self->pg->db->query(
        'INSERT INTO api.users (email, password_hash) VALUES (?, ?) RETURNING id',
        $email, $hash,
    )->hash;

    my $user_role_id = $self->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'user'})->hash->{id};
    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user->{id}, $user_role_id,
    );

    $self->_log_attempt(ip => $ip, email => $email, endpoint => 'register', success => 1);
    return $c->render(json => { id => $user->{id}, email => $email }, status => 201);
}

sub _login ($self, $c) {
    my $body     = $c->req->json // {};
    my $email    = $body->{email};
    my $password = $body->{password};
    my $ip       = $c->tx->remote_address;

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    if ($self->_rate_limited($ip)) {
        return $c->render(json => { error => 'Too many login attempts. Please wait 15 minutes.' }, status => 429);
    }

    my $user = $self->pg->db->query(
        'SELECT id, password_hash, active FROM api.users WHERE email = ?', $email,
    )->hash;

    unless ($user && $user->{active} && verify_password($password, $user->{password_hash})) {
        $self->_log_attempt(ip => $ip, email => $email, endpoint => 'login', success => 0);
        return $c->render(json => { error => 'invalid email or password' }, status => 401);
    }
    $self->_log_attempt(ip => $ip, email => $email, endpoint => 'login', success => 1);

    # Session device/IP metadata (see migrations/007-session-metadata.sql).
    # client_user_agent/client_ip are optional caller-supplied overrides --
    # homelab-sso's authorize_submit passes the REAL submitting browser's
    # own values here, since without them this row would record sso's own
    # backend HTTP client (the actual caller of THIS endpoint), not the
    # browser sitting behind it. Not a new trust boundary: whoever's
    # calling already had to supply a valid password for $email, so the
    # worst a lie here does is make that same account's OWN session-list
    # entry cosmetically wrong -- never an auth bypass.
    my $user_agent = $body->{client_user_agent} // $c->req->headers->user_agent;
    $user_agent = 'unknown' unless defined $user_agent && length $user_agent;
    my $ip_address = $body->{client_ip} // $ip;

    my $jti = generate_jti();
    my ($jwt, $expires_in) = generate_jwt($email, secret => $self->config->{jwt}{secret}, expires_in => $self->config->{jwt}{expiry_seconds}, jti => $jti);
    my $refresh_token = generate_refresh_token();
    my $refresh_ttl_days = $self->config->{jwt}{refresh_expiry_days} // 30;

    my $refresh_row = $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day')) RETURNING id},
        $user->{id}, $refresh_token, $refresh_ttl_days,
    )->hash;
    $self->pg->db->query(
        q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at, user_agent, ip_address, first_seen_at)
          VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'), ?, ?, NOW())},
        $jti, $user->{id}, $refresh_row->{id}, $expires_in, $user_agent, $ip_address,
    );

    enqueue(
        $self->pg->db, user_email => $email, jti => $jti, action => 'auth.login',
        resource_type => 'user', resource_id => $user->{id}, source_service => 'homelab-api',
        ip_address => $ip_address, user_agent => $user_agent,
    );

    return $c->render(json => {
        success       => \1,
        token         => $jwt,
        refresh_token => $refresh_token,
        expires_in    => $expires_in,
        email         => $email,
    });
}

sub _introspect ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'Token required' }, status => 401) unless $jwt;

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    return $c->render(json => { error => 'invalid or expired token' }, status => 401) unless $payload;

    # The actual revocation check -- see migrations/005-sessions.sql for
    # why this exists: without it, a JWT stays valid on pure signature+
    # expiry grounds regardless of logout, for up to its own ~30min
    # expiry_seconds. A missing session row (jti not found at all) fails
    # closed the same as an explicitly revoked one -- every JWT minted
    # from here on always has one, so "no row" only ever means "this
    # token predates session tracking" or "forged jti", neither of which
    # should introspect as valid.
    my $session = $self->pg->db->query(
        'SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '',
    )->hash;
    return $c->render(json => { error => 'session revoked' }, status => 401)
        unless $session && !$session->{revoked};

    # Added for homelab-domain-admin's site_admin gating (Phase 5) --
    # every existing caller (Dovecot's oauth2 passdb, mailbridge) simply
    # ignores this new key, same additive-response precedent as every
    # other field added here historically.
    my $roles = $self->pg->db->query(
        q{SELECT r.name FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          JOIN api.users u ON u.id = ur.user_id WHERE u.email = ?}, $payload->{email},
    )->hashes->map(sub { $_->{name} })->to_array;

    my $response = { email => $payload->{email}, exp => $payload->{exp}, roles => $roles, jti => $payload->{jti} };

    # Optional ?capability=<name> -- how a DIFFERENT service (which has
    # no direct grant on api.role_permissions/api.permissions, and never
    # will per this ecosystem's "no shared cross-schema access" norm)
    # asks "does this caller have capability X" without homelab-api
    # needing to expose a whole new endpoint for it. Reuses the same
    # introspect() call every service already makes on every request --
    # see _has_capability below for the actual site_admin-always-wins
    # plus role_permissions logic. Ignored by every existing caller that
    # doesn't pass it, same additive precedent as `roles`/`jti` above.
    if (my $capability = $c->param('capability')) {
        my $user = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $payload->{email})->hash;
        $response->{has_capability} = ($user && $self->_has_capability($user->{id}, $capability)) ? \1 : \0;
    }

    return $c->render(json => $response);
}

sub _refresh ($self, $c) {
    my $body          = $c->req->json // {};
    my $refresh_token = $body->{refresh_token};
    return $c->render(json => { error => 'refresh_token is required' }, status => 400) unless $refresh_token;

    my $row = $self->pg->db->query(
        q{SELECT rt.id, rt.user_id, u.email FROM api.refresh_tokens rt
          JOIN api.users u ON u.id = rt.user_id
          WHERE rt.token = ? AND rt.revoked = FALSE AND rt.expires_at > NOW()},
        $refresh_token,
    )->hash;
    return $c->render(json => { error => 'invalid or expired refresh_token' }, status => 401) unless $row;

    # Carry the OLD session's device/IP metadata forward rather than
    # recapturing it here -- see migrations/007-session-metadata.sql.
    # Deliberate, not a shortcut: a refresh can happen many hops from any
    # live browser request (sso's own silent-refresh fast path, or a BFF
    # like drive relaying a refresh_token grant), so "this request's own
    # user_agent/remote_address" is frequently just another backend
    # service, not meaningful browser/device info -- carrying the
    # ORIGINAL login's values forward keeps a long-refreshed session
    # correctly attributed to whatever actually logged in, and is also
    # what makes first_seen_at mean "since when", not "as of this refresh".
    my $old_session = $self->pg->db->query(
        'SELECT user_agent, ip_address, first_seen_at FROM api.sessions WHERE refresh_token_id = ? AND revoked = FALSE',
        $row->{id},
    )->hash // {};

    # Rotate: revoke the old token, issue a new one — a stolen, already-
    # used refresh token becomes immediately useless to an attacker on
    # the legitimate client's next refresh. Also revoke the OLD jti's
    # session row (not just the refresh_token) so a still-unexpired copy
    # of the previous JWT can't keep passing introspect() after its own
    # refresh_token has already been rotated away.
    $self->pg->db->query('UPDATE api.refresh_tokens SET revoked = TRUE WHERE id = ?', $row->{id});
    $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE refresh_token_id = ?', $row->{id});

    my $jti = generate_jti();
    my ($jwt, $expires_in) = generate_jwt($row->{email}, secret => $self->config->{jwt}{secret}, expires_in => $self->config->{jwt}{expiry_seconds}, jti => $jti);
    my $new_refresh_token = generate_refresh_token();
    my $refresh_ttl_days  = $self->config->{jwt}{refresh_expiry_days} // 30;

    my $new_refresh_row = $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day')) RETURNING id},
        $row->{user_id}, $new_refresh_token, $refresh_ttl_days,
    )->hash;
    $self->pg->db->query(
        q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at, user_agent, ip_address, first_seen_at)
          VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'), ?, ?, COALESCE(?, NOW()))},
        $jti, $row->{user_id}, $new_refresh_row->{id}, $expires_in,
        $old_session->{user_agent}, $old_session->{ip_address}, $old_session->{first_seen_at},
    );

    return $c->render(json => {
        success       => \1,
        token         => $jwt,
        refresh_token => $new_refresh_token,
        expires_in    => $expires_in,
    });
}

sub _logout ($self, $c) {
    my $body          = $c->req->json // {};
    my $refresh_token = $body->{refresh_token};
    if ($refresh_token) {
        my $row = $self->pg->db->query(
            'UPDATE api.refresh_tokens SET revoked = TRUE WHERE token = ? RETURNING id', $refresh_token,
        )->hash;
        # This is the actual "logout" from introspect()'s point of view
        # -- revoking just the refresh_token above only blocks *future*
        # token issuance; this is what makes the *current* JWT (still
        # sitting in whatever app called us) fail its very next
        # introspect() check, however much of its own exp window is
        # left. See migrations/005-sessions.sql.
        $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE refresh_token_id = ?', $row->{id})
            if $row;
    }
    return $c->render(json => { success => \1 });
}

sub _registry_register ($self, $c) {
    my $body = $c->req->json // {};
    for my $field (qw(feature_name host port)) {
        return $c->render(json => { error => "$field is required" }, status => 400)
            unless defined $body->{$field};
    }
    $self->registry->register(%$body);
    return $c->render(json => { ok => \1 });
}

sub _registry_lookup ($self, $c) {
    my $feature = $c->param('feature');
    my $entry   = $self->registry->lookup($feature);
    return $c->render(json => { error => 'not found' }, status => 404) unless $entry;
    return $c->render(json => $entry);
}

# GET /api/v1/registry -- every currently-registered feature, so a
# client can discover valid feature_name values instead of guessing
# (e.g. "homelab-mailbridge" isn't guessable from the CLI's own `mail`
# subcommand name alone).
sub _registry_list ($self, $c) {
    return $c->render(json => $self->registry->list_all);
}

# Verifies a bearer JWT (signature+expiry+not-revoked -- the same three
# checks _introspect's own response is built from) and returns the
# authenticated user's {id, email}, or undef if any check fails. A
# separate, small helper rather than a refactor of _introspect itself
# (which has its own, already-tested distinct error messages per failure
# reason) -- this one only needs a yes/no plus the DB id, for the admin
# routes below.
sub _authenticated_user ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return undef unless $jwt;

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    return undef unless $payload;

    my $session = $self->pg->db->query(
        'SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '',
    )->hash;
    return undef unless $session && !$session->{revoked};

    return $self->pg->db->query('SELECT id, email FROM api.users WHERE email = ?', $payload->{email})->hash;
}

# Like _authenticated_user above, but also returns the token's own
# jti -- the /auth/sessions routes need it to mark which listed row is
# the caller's own currently-in-use session. Deliberately a SEPARATE
# helper rather than widening _authenticated_user's own return shape:
# that sub is called in scalar context (`my $user = ...`) by
# _require_site_admin, and `return ($user, $jti)` evaluated in scalar
# context returns the LAST element (comma operator), not $user -- would
# have silently broken every existing site_admin route.
# Renders 401 itself and returns () on failure, so callers can do
# `my ($user, $jti) = $self->_authenticate($c) or return;` (an empty
# list assigned to a 2-element my() list is a 0-count assignment in
# boolean context, so `or return` correctly fires).
sub _authenticate ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    unless ($jwt) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return ();
    }

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    unless ($payload) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return ();
    }

    my $session = $self->pg->db->query(
        'SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '',
    )->hash;
    unless ($session && !$session->{revoked}) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return ();
    }

    my $user = $self->pg->db->query('SELECT id, email FROM api.users WHERE email = ?', $payload->{email})->hash;
    unless ($user) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return ();
    }
    return ($user, $payload->{jti});
}

# Resolves which user_id a /auth/sessions call should act on: the
# caller's own by default, or (only for a site_admin caller) whatever
# ?user=<email> asks for. A non-admin explicitly passing ?user= gets a
# clean 403 -- same "attempt the call, let the server decide, no
# confusing silently-scoped-down result" convention as every other
# ?user=/?destination=-style admin-visibility param in this ecosystem
# (see homelab-domain-admin's MailAliases/RecipientAccess). Renders the
# error itself and returns undef on failure.
sub _sessions_scope_target ($self, $c, $caller) {
    my $target_email = $c->param('user');
    return $caller unless defined $target_email && length $target_email;

    my $has_role = $self->pg->db->query(
        q{SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          WHERE ur.user_id = ? AND r.name = 'site_admin'},
        $caller->{id},
    )->hash;
    unless ($has_role) {
        $c->render(json => { error => 'site_admin role required' }, status => 403);
        return undef;
    }

    my $target = $self->pg->db->query('SELECT id, email FROM api.users WHERE email = ?', $target_email)->hash;
    unless ($target) {
        $c->render(json => { error => 'user not found' }, status => 404);
        return undef;
    }
    return $target;
}

# GET /api/v1/auth/sessions[?user=<email>] -- every non-revoked,
# non-expired session for the target user, newest-first. `current: true`
# marks whichever row is the JWT the caller is USING RIGHT NOW to make
# this very call -- lets a client warn before revoking its own live
# session out from under itself.
sub _sessions_list ($self, $c) {
    my ($caller, $jti) = $self->_authenticate($c) or return;
    my $target = $self->_sessions_scope_target($c, $caller) or return;

    my $rows = $self->pg->db->query(
        q{SELECT jti, user_agent, ip_address, first_seen_at, expires_at
          FROM api.sessions
          WHERE user_id = ? AND revoked = FALSE AND expires_at > NOW()
          ORDER BY first_seen_at DESC NULLS LAST, created_at DESC},
        $target->{id},
    )->hashes->to_array;

    $_->{current} = ($_->{jti} eq $jti) ? \1 : \0 for @$rows;
    return $c->render(json => $rows);
}

# DELETE /api/v1/auth/sessions/:jti[?user=<email>] -- the actual "force
# re-login" action. Revokes BOTH the session row and its refresh_token
# row in one call -- revoking only the session would be silently undone
# by homelab-cli's own 401-refresh-retry (client.py's _send): a stale-
# but-not-actually-revoked refresh_token would just mint the caller a
# brand new, perfectly valid session on their very next request, making
# this entire endpoint a no-op against the client this ecosystem already
# ships. Scoped to $target->{id} in the WHERE clause itself (not checked
# after the fact) so this can never revoke another user's session even
# by jti guess.
sub _sessions_revoke ($self, $c) {
    my ($caller, undef) = $self->_authenticate($c) or return;
    my $target = $self->_sessions_scope_target($c, $caller) or return;

    my $row = $self->pg->db->query(
        q{SELECT jti, refresh_token_id FROM api.sessions
          WHERE jti = ? AND user_id = ? AND revoked = FALSE},
        $c->stash('jti'), $target->{id},
    )->hash;
    return $c->render(json => { error => 'session not found' }, status => 404) unless $row;

    $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE jti = ?', $row->{jti});
    $self->pg->db->query('UPDATE api.refresh_tokens SET revoked = TRUE WHERE id = ?', $row->{refresh_token_id})
        if $row->{refresh_token_id};

    return $c->render(json => { ok => \1 });
}

# DELETE /api/v1/auth/sessions?except_current=true -- "log out
# everywhere else." Always scoped to the CALLER's own account (no
# ?user= support -- a site_admin wanting to kill a different user's
# other sessions can already do that one at a time via _sessions_revoke,
# which is the safer, auditable primitive; a bulk "nuke everyone else's
# sessions" admin action isn't something this was asked for).
sub _sessions_revoke_others ($self, $c) {
    my ($caller, $jti) = $self->_authenticate($c) or return;
    return $c->render(json => { error => 'except_current=true is required' }, status => 400)
        unless ($c->param('except_current') // '') eq 'true';

    my $rows = $self->pg->db->query(
        q{SELECT jti, refresh_token_id FROM api.sessions
          WHERE user_id = ? AND revoked = FALSE AND jti != ?},
        $caller->{id}, $jti,
    )->hashes->to_array;
    for my $row (@$rows) {
        $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE jti = ?', $row->{jti});
        $self->pg->db->query('UPDATE api.refresh_tokens SET revoked = TRUE WHERE id = ?', $row->{refresh_token_id})
            if $row->{refresh_token_id};
    }
    return $c->render(json => { ok => \1, revoked => scalar(@$rows) });
}

# Renders 401/403 itself and returns undef on failure, so callers can
# just do `my $user = $self->_require_site_admin($c) or return;`.
# Cheap local re-decode of the caller's own already-verified JWT, just
# for its jti -- homelab-api (unlike every other service) holds the
# signing secret itself, so this never needs a remote introspect round
# trip the way homelab-audit's own capability check does. Used only by
# audit call sites that got here via _require_site_admin (which returns
# {id, email}, no jti) rather than _authenticate (which already does).
sub _jwt_jti ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    my $payload = $jwt ? verify_jwt($jwt, secret => $self->config->{jwt}{secret}) : undef;
    return $payload ? $payload->{jti} : undef;
}

sub _require_site_admin ($self, $c) {
    my $user = $self->_authenticated_user($c);
    unless ($user) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return undef;
    }

    my $has_role = $self->pg->db->query(
        q{SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          WHERE ur.user_id = ? AND r.name = 'site_admin'},
        $user->{id},
    )->hash;
    unless ($has_role) {
        $c->render(json => { error => 'site_admin role required' }, status => 403);
        return undef;
    }

    return $user;
}

# GET /api/v1/admin/users -- every user, with their granted role names.
sub _admin_list_users ($self, $c) {
    $self->_require_site_admin($c) or return;

    my $users = $self->pg->db->query(
        'SELECT id, email, active, created_at FROM api.users ORDER BY id',
    )->hashes;
    my $roles_by_user = $self->pg->db->query(
        q{SELECT ur.user_id, r.name FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id},
    )->hashes;
    my %roles;
    push @{ $roles{ $_->{user_id} } }, $_->{name} for @$roles_by_user;

    return $c->render(json => [
        map { { %$_, roles => ($roles{ $_->{id} } // []) } } @$users,
    ]);
}

# POST /api/v1/admin/users/:id/roles {role: "site_admin"}
sub _admin_grant_role ($self, $c) {
    my $admin = $self->_require_site_admin($c) or return;

    my $user_id = $c->param('id');
    my $role    = ($c->req->json // {})->{role};
    return $c->render(json => { error => 'role is required' }, status => 400) unless $role;

    my $target = $self->pg->db->query('SELECT id FROM api.users WHERE id = ?', $user_id)->hash;
    return $c->render(json => { error => 'user not found' }, status => 404) unless $target;

    my $role_row = $self->pg->db->query('SELECT id FROM api.roles WHERE name = ?', $role)->hash;
    return $c->render(json => { error => "unknown role: $role" }, status => 400) unless $role_row;

    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user_id, $role_row->{id},
    );
    enqueue(
        $self->pg->db, user_email => $admin->{email}, jti => $self->_jwt_jti($c), action => 'role.grant',
        resource_type => 'user', resource_id => $user_id, source_service => 'homelab-api',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { role => $role },
    );
    return $c->render(json => { ok => \1 });
}

# DELETE /api/v1/admin/users/:id/roles/:role
sub _admin_revoke_role ($self, $c) {
    my $admin = $self->_require_site_admin($c) or return;

    my $user_id = $c->param('id');
    my $role    = $c->param('role');

    $self->pg->db->query(
        q{DELETE FROM api.user_roles WHERE user_id = ?
          AND role_id = (SELECT id FROM api.roles WHERE name = ?)},
        $user_id, $role,
    );
    enqueue(
        $self->pg->db, user_email => $admin->{email}, jti => $self->_jwt_jti($c), action => 'role.revoke',
        resource_type => 'user', resource_id => $user_id, source_service => 'homelab-api',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { role => $role },
    );
    return $c->render(json => { ok => \1 });
}

# Capability check used both locally (nothing in THIS service gates on
# it yet -- see migrations/008-role-permissions.sql's comment on why
# role/permission management itself stays site_admin-only, not
# capability-gated) and remotely, via _introspect's optional
# ?capability= param, by other services (starting with homelab-audit's
# read path). site_admin is an unconditional, hardcoded yes regardless
# of role_permissions -- deliberately: making site_admin's own
# capabilities configurable through this table would mean a single bad
# DELETE (or a role_permissions row silently missing after a fresh
# install) could lock every admin out of the very system meant to fix
# it. This is additive infrastructure for defining new, LESSER roles
# with a named subset of capabilities -- it never constrains what
# site_admin can do, and no existing hardcoded site_admin check
# anywhere in this ecosystem is expected to switch to it.
sub _has_capability ($self, $user_id, $name) {
    my $is_admin = $self->pg->db->query(
        q{SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          WHERE ur.user_id = ? AND r.name = 'site_admin'},
        $user_id,
    )->hash;
    return 1 if $is_admin;

    my $has_perm = $self->pg->db->query(
        q{SELECT 1 FROM api.user_roles ur
          JOIN api.role_permissions rp ON rp.role_id = ur.role_id
          JOIN api.permissions p ON p.id = rp.permission_id
          WHERE ur.user_id = ? AND p.name = ?},
        $user_id, $name,
    )->hash;
    return $has_perm ? 1 : 0;
}

# GET /api/v1/admin/roles -- every role, with its granted permission
# names and whether it's deletable.
sub _admin_list_roles ($self, $c) {
    $self->_require_site_admin($c) or return;

    my $roles = $self->pg->db->query(
        'SELECT id, name, description, protected, created_at FROM api.roles ORDER BY id',
    )->hashes;
    my $perms_by_role = $self->pg->db->query(
        q{SELECT rp.role_id, p.name FROM api.role_permissions rp
          JOIN api.permissions p ON p.id = rp.permission_id},
    )->hashes;
    my %perms;
    push @{ $perms{ $_->{role_id} } }, $_->{name} for @$perms_by_role;

    return $c->render(json => [
        map { { %$_, permissions => ($perms{ $_->{id} } // []) } } @$roles,
    ]);
}

# POST /api/v1/admin/roles {name, description?} -- new roles are never
# protected (only 'user'/'site_admin', seeded that way once, ever are).
sub _admin_create_role ($self, $c) {
    $self->_require_site_admin($c) or return;

    my $body = $c->req->json // {};
    my $name = $body->{name};
    return $c->render(json => { error => 'name is required' }, status => 400) unless $name;

    my $row = eval {
        $self->pg->db->query(
            'INSERT INTO api.roles (name, description) VALUES (?, ?) RETURNING id, name, description, protected, created_at',
            $name, $body->{description},
        )->hash;
    };
    return $c->render(json => { error => "role '$name' already exists" }, status => 409) if $@;
    return $c->render(json => { %$row, permissions => [] }, status => 201);
}

# DELETE /api/v1/admin/roles/:name -- 400s on protected = true instead
# of silently no-op'ing, so a caller can't mistake "refused" for "done".
sub _admin_delete_role ($self, $c) {
    $self->_require_site_admin($c) or return;

    my $name = $c->stash('name');
    my $role = $self->pg->db->query('SELECT id, protected FROM api.roles WHERE name = ?', $name)->hash;
    return $c->render(json => { error => 'role not found' }, status => 404) unless $role;
    return $c->render(json => { error => "'$name' is a protected role and cannot be deleted" }, status => 400)
        if $role->{protected};

    $self->pg->db->query('DELETE FROM api.roles WHERE id = ?', $role->{id});
    return $c->render(json => { ok => \1 });
}

# GET /api/v1/admin/permissions -- the known capability catalog. Seeded/
# extended by code (migrations), never user-created free text here --
# there's no POST for this on purpose, a permission only means anything
# once some route actually checks for it.
sub _admin_list_permissions ($self, $c) {
    $self->_require_site_admin($c) or return;
    return $c->render(json => $self->pg->db->query(
        'SELECT id, name, description FROM api.permissions ORDER BY name',
    )->hashes->to_array);
}

# POST /api/v1/admin/roles/:role/permissions/:permission
sub _admin_grant_permission ($self, $c) {
    $self->_require_site_admin($c) or return;

    my ($role_name, $perm_name) = ($c->stash('role'), $c->stash('permission'));
    my $role = $self->pg->db->query('SELECT id FROM api.roles WHERE name = ?', $role_name)->hash;
    return $c->render(json => { error => "unknown role: $role_name" }, status => 404) unless $role;
    my $perm = $self->pg->db->query('SELECT id FROM api.permissions WHERE name = ?', $perm_name)->hash;
    return $c->render(json => { error => "unknown permission: $perm_name" }, status => 404) unless $perm;

    $self->pg->db->query(
        'INSERT INTO api.role_permissions (role_id, permission_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $role->{id}, $perm->{id},
    );
    return $c->render(json => { ok => \1 });
}

# DELETE /api/v1/admin/roles/:role/permissions/:permission
sub _admin_revoke_permission ($self, $c) {
    $self->_require_site_admin($c) or return;

    my ($role_name, $perm_name) = ($c->stash('role'), $c->stash('permission'));
    $self->pg->db->query(
        q{DELETE FROM api.role_permissions WHERE role_id = (SELECT id FROM api.roles WHERE name = ?)
          AND permission_id = (SELECT id FROM api.permissions WHERE name = ?)},
        $role_name, $perm_name,
    );
    return $c->render(json => { ok => \1 });
}

1;
