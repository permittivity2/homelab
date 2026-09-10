package Homelab::API::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::API::Auth qw(hash_password verify_password generate_jwt verify_jwt generate_jti generate_refresh_token);
use Homelab::API::Registry;
use Homelab::Common::Proxy qw(forward);

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

    # --- Service registry (see Homelab::Common::Registry — this is what
    # every OTHER feature's register()/lookup() calls hit) ------------
    $r->post('/api/v1/registry/register' => sub ($c) { $self->_registry_register($c) });
    $r->get('/api/v1/registry/:feature'  => sub ($c) { $self->_registry_lookup($c) });

    # --- Admin (site_admin role required — see migrations/003-rbac.sql's
    # own comment: admin routes are deliberately hardcoded role checks,
    # not gated by a separate permissions table, so a bad row edit can't
    # lock every admin out at once). This is what homelab-cli's `admin`
    # subcommands talk to. ------------------------------------------
    $r->get('/api/v1/admin/users'                => sub ($c) { $self->_admin_list_users($c) });
    $r->post('/api/v1/admin/users/:id/roles'     => sub ($c) { $self->_admin_grant_role($c) });
    $r->delete('/api/v1/admin/users/:id/roles/:role' => sub ($c) { $self->_admin_revoke_role($c) });

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

    my $jti = generate_jti();
    my ($jwt, $expires_in) = generate_jwt($email, secret => $self->config->{jwt}{secret}, expires_in => $self->config->{jwt}{expiry_seconds}, jti => $jti);
    my $refresh_token = generate_refresh_token();
    my $refresh_ttl_days = $self->config->{jwt}{refresh_expiry_days} // 30;

    my $refresh_row = $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day')) RETURNING id},
        $user->{id}, $refresh_token, $refresh_ttl_days,
    )->hash;
    $self->pg->db->query(
        q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at) VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'))},
        $jti, $user->{id}, $refresh_row->{id}, $expires_in,
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

    return $c->render(json => { email => $payload->{email}, exp => $payload->{exp} });
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
        q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at) VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'))},
        $jti, $row->{user_id}, $new_refresh_row->{id}, $expires_in,
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

# Renders 401/403 itself and returns undef on failure, so callers can
# just do `my $user = $self->_require_site_admin($c) or return;`.
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
    $self->_require_site_admin($c) or return;

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
    return $c->render(json => { ok => \1 });
}

# DELETE /api/v1/admin/users/:id/roles/:role
sub _admin_revoke_role ($self, $c) {
    $self->_require_site_admin($c) or return;

    my $user_id = $c->param('id');
    my $role    = $c->param('role');

    $self->pg->db->query(
        q{DELETE FROM api.user_roles WHERE user_id = ?
          AND role_id = (SELECT id FROM api.roles WHERE name = ?)},
        $user_id, $role,
    );
    return $c->render(json => { ok => \1 });
}

1;
