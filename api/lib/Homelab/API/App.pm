package Homelab::API::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::Promise;
use Mojo::UserAgent;
use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::API::Auth qw(hash_password verify_password generate_jwt verify_jwt generate_jti generate_refresh_token);
use Homelab::API::Registry;
use Homelab::Common::Proxy qw(forward);
use Homelab::Common::AuditClient qw(enqueue enqueue_p);
use Homelab::Common::Registry qw(system_agent_token);

has 'pg';
has 'registry';

# Promise-chain sentinel for the routes converted to non-blocking below
# (_login, _introspect, _gateway): some early-exit branches already
# called $c->render() themselves (e.g. 401/429/502) and just need the
# rest of that route's chain skipped, not treated as a real error --
# rejecting with this shared marker, checked in each such route's own
# final ->catch, distinguishes "already handled" from "something
# actually broke" without a second render() firing on the same request
# (Mojolicious dies loudly on a double render).
my $ALREADY_RENDERED = \'already_rendered';

sub startup ($self) {
    my $config = load_config('HOMELAB_API_CONFIG', '/etc/homelab/api/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:3000'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/api-hypnotoad.pid',
        workers  => $srv->{workers} // 4,
        # A 4GB drive upload forwarded through the gateway is one long
        # request; the default 15s inactivity timeout would drop it on a
        # brief network stall. Generous, config-overridable defaults.
        inactivity_timeout => $srv->{inactivity_timeout} // 1200,
        heartbeat_timeout  => $srv->{heartbeat_timeout}  // 120,
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

    # Account-creation + recovery helpers, all system_agent-gated (never
    # public): they're called server-to-server by the packages that own
    # the browser-facing pages -- homelab-invite's acceptance page for
    # username-availability, homelab-sso's forgot/reset pages for the
    # password-reset pair. Keeping them off the public surface means the
    # "does this username/account exist" oracle they necessarily are is
    # only reachable by a trusted fleet caller, not an anonymous enumerator.
    $r->post('/api/v1/auth/username-availability'  => sub ($c) { $self->_username_availability($c) });
    $r->post('/api/v1/auth/password-reset/request' => sub ($c) { $self->_password_reset_request($c) });
    $r->post('/api/v1/auth/password-reset/confirm' => sub ($c) { $self->_password_reset_confirm($c) });

    # Session visibility/revocation -- JWT-only for the caller's own
    # (?user= honored only for site_admin, see _sessions_scope_target
    # below). Two DELETE routes coexist fine (no *capture wildcard
    # involved, unlike the gateway routes above) since one has a jti path
    # segment and the other doesn't.
    $r->get('/api/v1/auth/sessions'          => sub ($c) { $self->_sessions_list($c) });
    $r->delete('/api/v1/auth/sessions'       => sub ($c) { $self->_sessions_revoke_others($c) });
    $r->delete('/api/v1/auth/sessions/:jti'  => sub ($c) { $self->_sessions_revoke($c) });

    # Account summary for the caller's OWN account (bearer JWT) -- the
    # profile panel homelab-accountmanage renders: email, created_at,
    # recovery_email, active, roles. Introspect deliberately stays minimal
    # (email/exp/roles/jti, hit on every request by every service); this
    # is the fuller account view, so it's its own endpoint.
    $r->get('/api/v1/account/summary' => sub ($c) { $self->_account_summary($c) });

    # Authenticated self-service (bearer JWT). Change-password works with
    # NO recovery_email on file (unlike the SSO reset-by-email flow);
    # recovery-email lets a user set/change/clear the address that flow
    # needs. Both back homelab-accountmanage's Security panel.
    $r->post('/api/v1/auth/password' => sub ($c) { $self->_change_password($c) });
    $r->post('/api/v1/account/recovery-email' => sub ($c) { $self->_set_recovery_email($c) });

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
    $r->post('/api/v1/admin/users/:id/active'    => sub ($c) { $self->_admin_set_active($c) });
    $r->post('/api/v1/admin/users/:id/mail-quota' => sub ($c) { $self->_admin_set_mail_quota($c) });
    $r->post('/api/v1/admin/users/:id/roles'     => sub ($c) { $self->_admin_grant_role($c) });
    $r->delete('/api/v1/admin/users/:id/roles/:role' => sub ($c) { $self->_admin_revoke_role($c) });
    # Mints a real api.users row for a system-owned mailbox identity
    # (e.g. invites@<domain>, used by homelab-invite to send mail with
    # no logged-in human behind it) -- reuses hash_password() so this
    # identity authenticates IMAP/SMTP exactly like a human account,
    # same unified-identity model as everything else, no second
    # credential system. Prints the plaintext password exactly once in
    # the response, same one-time-reveal choreography as homelab-sso's
    # own OAuth client secrets (see sso/debian/postinst) -- the caller
    # (homelab-cli admin users create-service-account) is responsible
    # for showing it to the operator and never logging it.
    $r->post('/api/v1/admin/users/service-account' => sub ($c) { $self->_admin_create_service_account($c) });

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

    # --- Fleet agent (see migrations/010-fleet-agent.sql). Enroll is
    # site_admin-only (a human bootstrapping a new host's agent); redeem
    # and heartbeat are the agent's own unauthenticated-until-redeemed and
    # system_agent-authenticated calls respectively; the read endpoints
    # are site_admin-only, same posture as every other /admin/* route
    # above. -----------------------------------------------------------
    $r->post('/api/v1/admin/agent/enroll' => sub ($c) { $self->_agent_enroll($c) });
    $r->post('/api/v1/agent/enroll/redeem' => sub ($c) { $self->_agent_enroll_redeem($c) });
    $r->post('/api/v1/agent/heartbeat' => sub ($c) { $self->_agent_heartbeat($c) });
    $r->get('/api/v1/admin/agent/hosts' => sub ($c) { $self->_agent_list_hosts($c) });
    $r->get('/api/v1/admin/agent/status' => sub ($c) { $self->_agent_list_status($c) });
    $r->get('/api/v1/admin/agent/status/mismatches' => sub ($c) { $self->_agent_list_mismatches($c) });

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

    # homelab-invite's own routes are already /internal/v1/invites/...
    # -- same strip-"/api/v1"-then-reprepend-"/internal/v1" transform,
    # and the same two-routes-not-one requirement, as domains/jobs/audit
    # above (a *capture wildcard never matches the bare "/api/v1/invites"
    # with nothing after it -- list/create hit that bare path).
    $r->any('/api/v1/invites' => sub ($c) { $self->_gateway($c, 'homelab-invite', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });
    $r->any('/api/v1/invites/*capture' => sub ($c) { $self->_gateway($c, 'homelab-invite', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });

    # homelab-block-link's own routes are already /internal/v1/
    # block-link/... -- same strip-"/api/v1"-then-reprepend-
    # "/internal/v1" transform as invites/domains/jobs/audit above.
    # No bare "/api/v1/block-link" route (unlike domains/jobs/audit):
    # every real client path under this prefix already has at least one
    # segment after it (domains/:domain, account) -- confirmed against
    # homelab-block-link's own route table before assuming, not copied
    # blindly from the domains/jobs precedent.
    $r->any('/api/v1/block-link/*capture' => sub ($c) { $self->_gateway($c, 'homelab-block-link', strip_prefix => '/api/v1', backend_prefix => '/internal/v1') });

    return;
}

# Non-blocking (registry lookup via ->lookup_p, forward() itself now
# promise-based too) -- this is the busiest route in the whole service
# (every /api/v1/{drive,mail,domains,jobs,audit}/* request lands here),
# and a blocking lookup+forward used to park a whole hypnotoad worker
# for both the registry SELECT AND the full backend round trip. See
# Homelab::Common::Proxy's own docs for why forward() requires
# render_later from its caller.
sub _gateway ($self, $c, $feature_name, %opts) {
    $c->render_later;
    $self->registry->lookup_p($feature_name)->then(sub ($entry) {
        unless ($entry && $entry->{host} && $entry->{port}) {
            $c->render(json => { error => "$feature_name is not currently available" }, status => 502);
            return;
        }
        return forward($c, feature_name => $feature_name, host => $entry->{host}, port => $entry->{port}, %opts);
    })->catch(sub ($err) {
        $c->app->log->error("_gateway($feature_name) failed: $err");
        $c->render(json => { error => "$feature_name is not currently available" }, status => 502)
            unless $c->tx->res->code;
    });
    return;
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

# Non-blocking twins of _rate_limited/_log_attempt above, used only by
# the converted _login below -- _register still uses the blocking
# originals (lower request volume than login, not what the stress test
# exercised; left as a tracked follow-up rather than converted here).
sub _rate_limited_p ($self, $ip) {
    return $self->pg->db->query_p(
        q{SELECT count(*) AS n FROM api.login_attempts
          WHERE ip = ? AND success = FALSE AND attempted_at > NOW() - (? * INTERVAL '1 minute')},
        $ip, RATE_LIMIT_WINDOW_MIN,
    )->then(sub ($results) { return $results->hash->{n} >= RATE_LIMIT_MAX_FAILURES });
}

sub _log_attempt_p ($self, %fields) {
    return $self->pg->db->query_p(
        'INSERT INTO api.login_attempts (ip, email, endpoint, success) VALUES (?, ?, ?, ?)',
        @fields{qw(ip email endpoint success)},
    );
}

# POST /api/v1/auth/register {email, password, invite_token?}
# Was unconditionally open (no auth required) -- this is still true by
# default (config auth.require_invite: false), since this is a test/dev
# domain and the fastest path to real test accounts shouldn't regress
# for anyone not opting into the invite package. When
# auth.require_invite is true (an operator has installed homelab-invite
# and wants it enforced), invite_token becomes mandatory and is
# consumed via a server-to-server call BEFORE any api.users row is
# created -- fails closed (never silently skips the check) if the token
# is missing/invalid/already-used, or if homelab-invite itself is
# unreachable, same "verify at every hop, don't assume the caller
# already checked" posture as every other cross-feature call in this
# codebase.
sub _register ($self, $c) {
    my $body         = $c->req->json // {};
    my $email        = $body->{email};
    my $password     = $body->{password};
    my $invite_token = $body->{invite_token};
    my $ip           = $c->tx->remote_address;

    # A trusted internal caller may supply the REAL originating
    # client's IP in client_ip, instead of $ip above reflecting ITS
    # OWN address -- the only real caller today is homelab-invite's
    # own /invite/:token/accept, relaying a real end user's browser
    # request as a fresh server-to-server call of its own (there is no
    # way to "forward" the original TCP connection itself; the IP has
    # to be passed as data). Without this, EVERY invite acceptance
    # fleet-wide shares homelab-invite's own host as its apparent IP
    # for _rate_limited below -- found live, 2026-09-26: a burst of
    # unrelated rejected acceptances from different real invitees
    # locked out invite acceptance fleet-wide for 15 minutes, since
    # the shared counter couldn't tell them apart. Gated on the SAME
    # system_agent credential every other internal service-to-service
    # trust decision in this codebase already uses (filesystem-
    # permission-gated, never just a bare client-supplied field a
    # public caller could fake to dodge rate limiting entirely) --
    # _is_system_agent is a non-rendering check specifically so a
    # normal public registration (no such credential at all) isn't
    # affected.
    if ($body->{client_ip}) {
        my $caller = $self->_authenticated_user($c);
        $ip = $body->{client_ip} if $caller && $self->_is_system_agent($caller);
    }

    # Optional failsafe address for password recovery (see
    # migrations/013-recovery-email.sql). At invite acceptance this
    # defaults to the invite's own recipient_email -- the external
    # contact address the invite was sent to -- so a locked-out user has
    # a route back in that doesn't depend on the fleet mailbox they
    # can't reach. Nullable; validated only for basic shape when present.
    my $recovery_email = $body->{recovery_email};
    $recovery_email = undef if defined $recovery_email && $recovery_email eq '';
    return $c->render(json => { error => 'recovery_email is not a valid email address' }, status => 400)
        if defined $recovery_email && $recovery_email !~ /^[^@\s]+\@[^@\s]+\.[^@\s]+$/;

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    if ($self->_rate_limited($ip)) {
        return $c->render(json => { error => 'Too many attempts. Please wait 15 minutes.' }, status => 429);
    }

    # Checked BEFORE consuming the invite, deliberately: consuming burns
    # the one-time token, and "email already registered" is a real,
    # not-uncommon outcome (a stale invite link re-clicked after the
    # account was already created some other way) -- getting this order
    # backwards would permanently burn a token for a registration that
    # never actually happened. Found in review, not live, but the same
    # "don't consume before every other precondition is confirmed"
    # discipline this codebase's atomic-consume design already assumes.
    #
    # Deliberately NOT logged via _log_attempt (unlike a genuine
    # credential-guessing failure, e.g. a wrong password at LOGIN,
    # which still counts): "this email already exists" is a
    # deterministic fact about the input, not a signal that someone is
    # guessing at anything, and login's own brute-force protection
    # (the actual reason _rate_limited exists) shares this same
    # counter -- letting a burst of these silently exhaust it would
    # incidentally rate-limit login too, for a reason unrelated to
    # login security. Same reasoning applies to the domain-rejection
    # check below.
    my $existing = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash;
    if ($existing) {
        return $c->render(json => { error => 'email already registered' }, status => 409);
    }

    my $require_invite = $self->config->{auth}{require_invite} // 0;
    if ($require_invite) {
        return $c->render(json => { error => 'invite_token is required' }, status => 400)
            unless $invite_token;

        # The recipient-DOMAIN restriction (an invite may not be accepted
        # for a fleet-managed CONTACT address) used to live here, checked
        # against the registration email. It moved to homelab-invite's
        # own accept()/show() as of 2026-09-27, and for a real reason,
        # not tidiness: the account being created here is now a freshly
        # CHOSEN fleet-domain login (<username>@<account_domain>) that is
        # DELIBERATELY on a fleet-managed domain -- checking the
        # registration email for "is this fleet-managed" would now reject
        # every legitimate invite acceptance. The thing that must not be
        # fleet-managed is the invite's RECIPIENT (contact) address, which
        # only homelab-invite knows -- so that's where the check now
        # lives, operating on recipient_email. See homelab-invite's
        # Controller::Invites _recipient_domain_error + its README.
        my $consume_error = $self->_consume_invite($invite_token, $email);
        if ($consume_error) {
            $self->_log_attempt(ip => $ip, email => $email, endpoint => 'register', success => 0);
            return $c->render(json => { error => $consume_error }, status => 403);
        }
    }

    my $hash = hash_password($password);
    my $user = $self->pg->db->query(
        'INSERT INTO api.users (email, password_hash, recovery_email) VALUES (?, ?, ?) RETURNING id',
        $email, $hash, $recovery_email,
    )->hash;

    my $user_role_id = $self->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'user'})->hash->{id};
    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user->{id}, $user_role_id,
    );

    $self->_log_attempt(ip => $ip, email => $email, endpoint => 'register', success => 1);
    return $c->render(json => { id => $user->{id}, email => $email }, status => 201);
}

# Blocking on purpose (unlike _gateway's non-blocking lookup_p+forward
# chain above): _register is one of the few routes in this file NOT
# yet converted to Mojo::Pg's non-blocking API (see the comment above
# _sessions_list's own conversion for why that migration matters on hot
# paths) -- registration is low-volume and already does several
# blocking ->query calls in a row, so one more blocking HTTP round trip
# here isn't a new class of problem. Returns undef on success, or a
# user-facing error string on failure -- deliberately not a thrown
# exception, since "invite already used" is an expected, common outcome
# here, not a real error condition.
sub _consume_invite ($self, $token, $email) {
    my $entry = $self->pg->db->query(
        'SELECT feature_name, host, port FROM api.service_registry
         WHERE feature_name = ? ORDER BY updated_at DESC LIMIT 1',
        'homelab-invite',
    )->hash;
    return 'invite service is not currently available' unless $entry && $entry->{host} && $entry->{port};

    # One bounded retry on EITHER a bare transport-level failure OR a
    # 403 -- found live, 2026-09-26, and actually root-caused (not just
    # patched around): homelab-agent rotates this host's own
    # system_agent JWT on every heartbeat (see system_agent_token()'s
    # own doc comment on why it's re-read from disk fresh every call,
    # never cached), and homelab-invite's authenticated_system_agent
    # verifies it by calling BACK into this same service's /introspect
    # -- a real, if narrow, race: a token read here can be valid at
    # read time and already rotated-out by the time introspect checks
    # it a moment later, correctly producing a real 403 (not a
    # transport error, which is exactly why the earlier version of this
    # retry -- transport-failures only -- didn't catch it: confirmed
    # live, a fast ~0.3s 403, not a ~10s timeout). Re-fetching a FRESH
    # token on the retry (not reusing the same, possibly already-stale
    # one) is what actually makes the retry useful here, unlike a
    # generic 403 on some OTHER endpoint that would just fail the same
    # way twice. A 409 (already used/expired) or 404 (not found) is a
    # stable, real outcome either way -- never retried, same as before.
    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
    my $tx;
    for my $attempt (1, 2) {
        my $agent_token = eval { system_agent_token() };
        unless ($agent_token) {
            return 'invite service credential unavailable' if $attempt == 2;
            next;
        }
        $tx = $ua->post(
            "http://$entry->{host}:$entry->{port}/internal/v1/invites/consume",
            { Authorization => "Bearer $agent_token" },
            json => { token => $token, email => $email },
        );
        last unless $tx->error && (!$tx->error->{code} || $tx->error->{code} == 403);
    }
    if (my $err = $tx->error) {
        return 'invite already used or expired' if $err->{code} && $err->{code} == 409;
        return 'invite not found' if $err->{code} && $err->{code} == 404;
        # Logged, not silently swallowed as before -- the generic
        # fallback message gave no way to tell "homelab-invite is
        # genuinely down" apart from "got some OTHER real error back"
        # (e.g. a genuine 500 on ITS side). The specific 403/token-race
        # case this used to also fall into is now retried above instead
        # of reaching here at all -- this branch is for whatever's left.
        $self->log->warn(
            "homelab-api: _consume_invite got " . ($err->{code} // 'no response')
            . " from homelab-invite's /consume: " . ($err->{message} // ''),
        );
        return 'invite could not be verified';
    }
    return undef;
}

# POST /api/v1/auth/username-availability {local_part, domain}
# system_agent-gated (only homelab-invite's acceptance page calls it,
# server-to-server) -- deliberately NOT public: this is unavoidably a
# "does <name> already exist" oracle, and keeping it behind the
# system_agent credential means only a trusted fleet caller can probe
# it, not an anonymous enumerator. Response is always 200 (a taken name
# is a normal UX outcome, not an error): { available: bool } plus, when
# taken, { suggestions: [local_part, ...] } of names that ARE free, and
# when the input isn't a usable local-part at all, { available: false,
# invalid: true, error: "..." } so the caller can tell "try another"
# apart from "that's malformed".
sub _username_availability ($self, $c) {
    $self->_require_system_agent($c) or return;
    my $body   = $c->req->json // {};
    my $local  = lc($body->{local_part} // '');
    my $domain = lc($body->{domain} // '');
    return $c->render(json => { error => 'local_part and domain are required' }, status => 400)
        unless length $local && length $domain;

    unless (_valid_local_part($local)) {
        return $c->render(json => {
            available => \0, invalid => \1,
            error => 'Usernames may use lowercase letters, numbers, dots, dashes and '
                   . 'underscores, must start and end with a letter or number, and be 1-64 characters.',
        });
    }

    if ($self->_email_taken("$local\@$domain")) {
        return $c->render(json => { available => \0, suggestions => $self->_username_suggestions($local, $domain, 4) });
    }
    return $c->render(json => { available => \1 });
}

# Lowercased local-part rules -- intentionally conservative (a strict
# subset of what SMTP technically permits) so every account login is a
# clean, unambiguous mailbox name: starts/ends alphanumeric, inner chars
# may add . _ - , total length 1-64.
sub _valid_local_part ($local) {
    return $local =~ /^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$/;
}

sub _email_taken ($self, $email) {
    return !!$self->pg->db->query('SELECT 1 FROM api.users WHERE lower(email) = lower(?)', $email)->hash;
}

# A short list of free variations on a taken local-part, checked against
# the real table so every returned name is actually claimable at the
# moment of the call (a later racing registration is still caught by the
# UNIQUE constraint on INSERT -- this is a UX convenience, not a
# reservation). Numeric suffixes first (the least surprising), then a
# couple of dotted forms, stopping as soon as $count free ones are found.
sub _username_suggestions ($self, $local, $domain, $count) {
    my @candidates = map { "$local$_" } (1 .. 20);
    push @candidates, "$local.1", "$local.2", "the.$local", "$local.mail";
    my @free;
    for my $cand (@candidates) {
        last if @free >= $count;
        next unless _valid_local_part($cand);
        push @free, $cand unless $self->_email_taken("$cand\@$domain");
    }
    return \@free;
}

# POST /api/v1/auth/password-reset/request {email, client_ip?}
# system_agent-gated (homelab-sso's public /forgot page calls it). Mints
# a one-time reset token ONLY when the account exists AND has a recovery
# address on file, and returns that token + the recovery address to the
# caller (SSO) to email. Returning found/recovery to a TRUSTED caller is
# fine -- SSO is responsible for collapsing this into a uniform,
# non-enumerable "if an account exists we've emailed a link" message to
# the actual browser. A light per-user throttle (no fresh token if an
# unused one was minted in the last 60s) blunts using this to spam a
# victim's recovery inbox, without a second rate-limit store.
sub _password_reset_request ($self, $c) {
    $self->_require_system_agent($c) or return;
    my $body  = $c->req->json // {};
    my $email = lc($body->{email} // '');
    return $c->render(json => { error => 'email is required' }, status => 400) unless length $email;

    my $user = $self->pg->db->query(
        'SELECT id, recovery_email FROM api.users WHERE lower(email) = lower(?) AND active = TRUE', $email,
    )->hash;
    return $c->render(json => { found => \0 }) unless $user;
    return $c->render(json => { found => \1, recovery_email => undef }) unless $user->{recovery_email};

    my $recent = $self->pg->db->query(
        q{SELECT 1 FROM api.password_resets
          WHERE user_id = ? AND used = FALSE AND created_at > NOW() - INTERVAL '60 seconds'},
        $user->{id},
    )->hash;
    if ($recent) {
        return $c->render(json => { found => \1, recovery_email => $user->{recovery_email}, throttled => \1 });
    }

    my $token = generate_jti();
    $self->pg->db->query(
        q{INSERT INTO api.password_resets (token, user_id, expires_at) VALUES (?, ?, NOW() + INTERVAL '1 hour')},
        $token, $user->{id},
    );
    return $c->render(json => { found => \1, recovery_email => $user->{recovery_email}, token => $token });
}

# POST /api/v1/auth/password-reset/confirm {token, password}
# system_agent-gated (homelab-sso's /reset/:token page calls it).
# Single-use via an atomic UPDATE ... WHERE used=FALSE AND expires_at>NOW()
# RETURNING -- two concurrent confirms on the same token: exactly one
# matches a row. On success sets the new password AND revokes every
# existing session for that user (a password reset is exactly the moment
# you want any still-live stolen session gone), so the user re-logs in
# everywhere.
sub _password_reset_confirm ($self, $c) {
    $self->_require_system_agent($c) or return;
    my $body     = $c->req->json // {};
    my $token    = $body->{token};
    my $password = $body->{password};
    return $c->render(json => { error => 'token and password are required' }, status => 400)
        unless $token && $password;
    return $c->render(json => { error => 'password must be at least 8 characters' }, status => 400)
        if length($password) < 8;

    my $row = $self->pg->db->query(
        q{UPDATE api.password_resets SET used = TRUE
          WHERE token = ? AND used = FALSE AND expires_at > NOW() RETURNING user_id},
        $token,
    )->hash;
    return $c->render(json => { error => 'this reset link is invalid or has expired' }, status => 410)
        unless $row;

    $self->pg->db->query('UPDATE api.users SET password_hash = ? WHERE id = ?',
        hash_password($password), $row->{user_id});
    $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE user_id = ? AND revoked = FALSE',
        $row->{user_id});
    return $c->render(json => { ok => \1 });
}

# Converted to Mojo::Pg's non-blocking API (see $ALREADY_RENDERED above
# for the early-exit convention) -- this was the worst single offender
# in the blocking-I/O stress-test collapse: 5+ sequential DB round trips
# per call, each one parking the ENTIRE hypnotoad worker's event loop
# (not just this request) for its full duration under Mojo::Pg's old
# blocking ->query(). Behavior is unchanged from the blocking version
# above -- same status codes, same error shapes, same query ordering
# (each step here still genuinely depends on the previous one's result,
# e.g. the session INSERT needs the refresh_token row's own id).
sub _login ($self, $c) {
    my $body     = $c->req->json // {};
    my $email    = $body->{email};
    my $password = $body->{password};
    my $ip       = $c->tx->remote_address;

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    $c->render_later;

    $self->_rate_limited_p($ip)->then(sub ($limited) {
        if ($limited) {
            $c->render(json => { error => 'Too many login attempts. Please wait 15 minutes.' }, status => 429);
            return Mojo::Promise->reject($ALREADY_RENDERED);
        }
        # is_system_agent fetched in the SAME query as password_hash,
        # checked BEFORE verify_password is ever called below (not as a
        # later stage) — system_agent accounts (a fleet agent's own
        # identity, or homelab-api's own outbound identity for pulling
        # agent status, see migrations/010-fleet-agent.sql) get an
        # unguessable, NOT NECESSARILY ARGON2-FORMATTED password_hash
        # (they're only ever issued a session via
        # /api/v1/agent/enroll/redeem, never this endpoint), and
        # verify_password's own argon2id_verify() throws on a malformed
        # hash rather than returning false — calling it on one of these
        # rows would 500, not cleanly reject. Checking the role first
        # avoids ever reaching that call for these accounts.
        return $self->pg->db->query_p(
            q{SELECT u.id, u.password_hash, u.active,
                     EXISTS(SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
                            WHERE ur.user_id = u.id AND r.name = 'system_agent') AS is_system_agent
              FROM api.users u WHERE u.email = ?}, $email,
        );
    })->then(sub ($results) {
        my $user = $results->hash;
        # Same generic error as a wrong password, deliberately, so this
        # doesn't leak which accounts are system accounts.
        $user = undef if $user && $user->{is_system_agent};
        unless ($user && $user->{active} && verify_password($password, $user->{password_hash})) {
            return $self->_log_attempt_p(ip => $ip, email => $email, endpoint => 'login', success => 0)->then(sub {
                $c->render(json => { error => 'invalid email or password' }, status => 401);
                return Mojo::Promise->reject($ALREADY_RENDERED);
            });
        }
        return $self->_log_attempt_p(ip => $ip, email => $email, endpoint => 'login', success => 1)
            ->then(sub { return $user });
    })->then(sub ($user) {
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

        return $self->pg->db->query_p(
            q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day')) RETURNING id},
            $user->{id}, $refresh_token, $refresh_ttl_days,
        )->then(sub ($results) {
            my $refresh_row = $results->hash;
            return $self->pg->db->query_p(
                q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at, user_agent, ip_address, first_seen_at)
                  VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'), ?, ?, NOW())},
                $jti, $user->{id}, $refresh_row->{id}, $expires_in, $user_agent, $ip_address,
            );
        })->then(sub {
            return enqueue_p(
                $self->pg->db, actor_email => $email, affected_user => $email, jti => $jti, action => 'auth.login',
                resource_type => 'user', resource_id => $user->{id}, source_service => 'homelab-api',
                ip_address => $ip_address, user_agent => $user_agent,
            );
        })->then(sub {
            $c->render(json => {
                success       => \1,
                token         => $jwt,
                refresh_token => $refresh_token,
                expires_in    => $expires_in,
                email         => $email,
            });
        });
    })->catch(sub ($err) {
        return if ref $err eq 'SCALAR' && $err == $ALREADY_RENDERED;
        $c->app->log->error("_login failed: $err");
        $c->render(json => { error => 'internal server error' }, status => 500);
    });

    return;
}

# Converted to Mojo::Pg's non-blocking API -- this is called by EVERY
# other service in the fleet on EVERY authenticated request it handles
# (see Homelab::Common::Proxy's own docs: "each backend already
# re-verifies it independently via its own introspect() call"), making
# it arguably the single hottest route in the whole service, hotter
# than _login itself. Behavior unchanged from the blocking version:
# same status codes/error shapes, same revocation-then-roles-then-
# optional-capability sequencing.
sub _introspect ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'Token required' }, status => 401) unless $jwt;

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    return $c->render(json => { error => 'invalid or expired token' }, status => 401) unless $payload;

    $c->render_later;

    # The actual revocation check -- see migrations/005-sessions.sql for
    # why this exists: without it, a JWT stays valid on pure signature+
    # expiry grounds regardless of logout, for up to its own ~30min
    # expiry_seconds. A missing session row (jti not found at all) fails
    # closed the same as an explicitly revoked one -- every JWT minted
    # from here on always has one, so "no row" only ever means "this
    # token predates session tracking" or "forged jti", neither of which
    # should introspect as valid.
    $self->pg->db->query_p('SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '')
        ->then(sub ($results) {
            my $session = $results->hash;
            unless ($session && !$session->{revoked}) {
                $c->render(json => { error => 'session revoked' }, status => 401);
                return Mojo::Promise->reject($ALREADY_RENDERED);
            }
            # Added for homelab-domain-admin's site_admin gating (Phase 5) --
            # every existing caller (Dovecot's oauth2 passdb, mailbridge) simply
            # ignores this new key, same additive-response precedent as every
            # other field added here historically.
            return $self->pg->db->query_p(
                q{SELECT r.name FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
                  JOIN api.users u ON u.id = ur.user_id WHERE u.email = ?}, $payload->{email},
            );
        })->then(sub ($results) {
            my $roles = $results->hashes->map(sub { $_->{name} })->to_array;
            my $response = { email => $payload->{email}, exp => $payload->{exp}, roles => $roles, jti => $payload->{jti} };

            # Optional ?capability=<name> -- how a DIFFERENT service (which has
            # no direct grant on api.role_permissions/api.permissions, and never
            # will per this ecosystem's "no shared cross-schema access" norm)
            # asks "does this caller have capability X" without homelab-api
            # needing to expose a whole new endpoint for it. Reuses the same
            # introspect() call every service already makes on every request --
            # see _has_capability_p below for the actual site_admin-always-wins
            # plus role_permissions logic. Ignored by every existing caller that
            # doesn't pass it, same additive precedent as `roles`/`jti` above.
            my $capability = $c->param('capability');
            unless ($capability) {
                $c->render(json => $response);
                return;
            }

            return $self->pg->db->query_p('SELECT id FROM api.users WHERE email = ?', $payload->{email})
                ->then(sub ($results2) {
                    my $user = $results2->hash;
                    return $user ? $self->_has_capability_p($user->{id}, $capability) : Mojo::Promise->resolve(0);
                })->then(sub ($has_cap) {
                    $response->{has_capability} = $has_cap ? \1 : \0;
                    $c->render(json => $response);
                });
        })->catch(sub ($err) {
            return if ref $err eq 'SCALAR' && $err == $ALREADY_RENDERED;
            $c->app->log->error("_introspect failed: $err");
            $c->render(json => { error => 'internal server error' }, status => 500);
        });

    return;
}

# GET /api/v1/account/summary -- the caller's own account, for the
# account-management dashboard. Bearer JWT (same verify + session-
# revocation check as _introspect). Returns email, created_at,
# recovery_email, active, roles[].
sub _account_summary ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'Token required' }, status => 401) unless $jwt;

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    return $c->render(json => { error => 'invalid or expired token' }, status => 401) unless $payload;

    $c->render_later;
    my $email = $payload->{email};

    $self->pg->db->query_p('SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '')
        ->then(sub ($results) {
            my $session = $results->hash;
            unless ($session && !$session->{revoked}) {
                $c->render(json => { error => 'session revoked' }, status => 401);
                return Mojo::Promise->reject($ALREADY_RENDERED);
            }
            return $self->pg->db->query_p(
                'SELECT email, created_at, recovery_email, active FROM api.users WHERE email = ?', $email);
        })->then(sub ($results) {
            my $user = $results->hash;
            unless ($user) {
                $c->render(json => { error => 'account not found' }, status => 404);
                return Mojo::Promise->reject($ALREADY_RENDERED);
            }
            $c->stash(_acct => $user);
            return $self->pg->db->query_p(
                q{SELECT r.name FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
                  JOIN api.users u ON u.id = ur.user_id WHERE u.email = ?}, $email);
        })->then(sub ($results) {
            my $roles = $results->hashes->map(sub { $_->{name} })->to_array;
            my $u = $c->stash('_acct');
            $c->render(json => {
                email          => $u->{email},
                created_at     => $u->{created_at},
                recovery_email => $u->{recovery_email},
                active         => ($u->{active} ? \1 : \0),
                roles          => $roles,
            });
        })->catch(sub ($err) {
            return if ref $err eq 'SCALAR' && $err == $ALREADY_RENDERED;
            $c->app->log->error("_account_summary failed: $err");
            $c->render(json => { error => 'internal server error' }, status => 500);
        });

    return;
}

# Shared bearer-JWT check for authenticated self-service writes below:
# verify signature/exp + the session-revocation check (same as
# _introspect), synchronously (these are quick single-row writes).
# Renders a 401 and returns undef on any failure; else returns the
# verified payload ({email, jti, ...}).
sub _require_bearer ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    unless ($jwt) { $c->render(json => { error => 'Token required' }, status => 401); return undef; }
    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    unless ($payload) { $c->render(json => { error => 'invalid or expired token' }, status => 401); return undef; }
    my $sess = $self->pg->db->query('SELECT revoked FROM api.sessions WHERE jti = ?', $payload->{jti} // '')->hash;
    unless ($sess && !$sess->{revoked}) { $c->render(json => { error => 'session revoked' }, status => 401); return undef; }
    return $payload;
}

# POST /api/v1/auth/password { current_password, new_password }
# In-place authenticated change: verifies the current password, sets the
# new one, and revokes the user's OTHER sessions (keeping the caller's
# own) so a stolen old token can't outlive the change. Works with no
# recovery_email on file, unlike the SSO reset-by-email flow.
sub _change_password ($self, $c) {
    my $payload = $self->_require_bearer($c) or return;
    my $body = $c->req->json // {};
    my ($cur, $new) = ($body->{current_password}, $body->{new_password});
    return $c->render(json => { error => 'current_password and new_password are required' }, status => 400)
        unless $cur && $new;
    return $c->render(json => { error => 'new password must be at least 8 characters' }, status => 400)
        if length($new) < 8;

    my $user = $self->pg->db->query('SELECT id, password_hash FROM api.users WHERE email = ?', $payload->{email})->hash;
    return $c->render(json => { error => 'account not found' }, status => 404) unless $user;
    return $c->render(json => { error => 'current password is incorrect' }, status => 403)
        unless verify_password($cur, $user->{password_hash});

    $self->pg->db->query('UPDATE api.users SET password_hash = ? WHERE id = ?', hash_password($new), $user->{id});
    $self->pg->db->query(
        'UPDATE api.sessions SET revoked = TRUE WHERE user_id = ? AND jti <> ? AND revoked = FALSE',
        $user->{id}, $payload->{jti} // '');
    return $c->render(json => { ok => \1 });
}

# POST /api/v1/account/recovery-email { recovery_email }
# Set / change / clear (empty string clears) the caller's recovery email.
sub _set_recovery_email ($self, $c) {
    my $payload = $self->_require_bearer($c) or return;
    my $body = $c->req->json // {};
    my $re = $body->{recovery_email};
    $re = undef if defined $re && $re eq '';
    return $c->render(json => { error => 'recovery_email is not a valid email address' }, status => 400)
        if defined $re && $re !~ /^[^@\s]+\@[^@\s]+\.[^@\s]+$/;
    $self->pg->db->query('UPDATE api.users SET recovery_email = ? WHERE email = ?', $re, $payload->{email});
    return $c->render(json => { ok => \1, recovery_email => $re });
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

# Write side: only a host's own homelab-agent-issued system_agent
# credential may register a feature here (same gate /api/v1/agent/
# heartbeat uses) -- this table is what homelab-api's own gateway
# forwarding trusts to decide where real user traffic goes, so an
# unauthenticated POST here would have let anyone on the network
# silently hijack any feature's backend address. See the commit that
# introduced this check for the incident writeup.
sub _registry_register ($self, $c) {
    $self->_require_system_agent($c) or return;
    my $body = $c->req->json // {};
    for my $field (qw(feature_name host port)) {
        return $c->render(json => { error => "$field is required" }, status => 400)
            unless defined $body->{$field};
    }
    $self->registry->register(%$body);
    return $c->render(json => { ok => \1 });
}

# Read side: any logged-in caller (human or service), not site_admin --
# same "owner doesn't need to be an admin to ask a basic question"
# posture as mail-aliases/mine. Was previously unauthenticated entirely,
# leaking internal service topology to anyone on the network.
sub _registry_lookup ($self, $c) {
    my ($caller, undef) = $self->_authenticate($c) or return;
    my $feature = $c->param('feature');
    my $entry   = $self->registry->lookup($feature);
    return $c->render(json => { error => 'not found' }, status => 404) unless $entry;
    return $c->render(json => $entry);
}

# GET /api/v1/registry -- every currently-registered feature, so a
# client can discover valid feature_name values instead of guessing
# (e.g. "homelab-mailbridge" isn't guessable from the CLI's own `mail`
# subcommand name alone). Same bare-login gate as _registry_lookup.
sub _registry_list ($self, $c) {
    my ($caller, undef) = $self->_authenticate($c) or return;
    return $c->render(json => $self->registry->list_all);
}

# --- Fleet agent (see migrations/010-fleet-agent.sql) --------------
# All blocking/synchronous, deliberately — same reasoning as _register
# staying blocking: low request volume (one enroll per new host ever,
# one heartbeat per host roughly per minute across the whole fleet),
# nowhere near the concurrency that made _login/_introspect/_gateway
# worth converting.

sub _require_system_agent ($self, $c) {
    my $user = $self->_authenticated_user($c);
    unless ($user) {
        $c->render(json => { error => 'authentication required' }, status => 401);
        return undef;
    }
    unless ($self->_is_system_agent($user)) {
        $c->render(json => { error => 'system_agent role required' }, status => 403);
        return undef;
    }
    return $user;
}

# Non-rendering twin of the role check inside _require_system_agent
# above -- for callers that need to know "is this a trusted internal
# caller" without failing the whole request when it isn't (e.g.
# _register below, where a system_agent credential is optional: most
# callers are real public self-registrations with no such thing).
sub _is_system_agent ($self, $user) {
    return !!$self->pg->db->query(
        q{SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          WHERE ur.user_id = ? AND r.name = 'system_agent'}, $user->{id},
    )->hash;
}

# Shared by _agent_enroll_redeem below (a real login mint would be
# _login's own job, but system_agent accounts can never use that path
# -- see its own explicit guard -- so this duplicates just the
# session-minting tail of it, not the password/rate-limit machinery
# that doesn't apply here).
sub _mint_session_blocking ($self, $email, $user_id, $c) {
    my $jti = generate_jti();
    my ($jwt, $expires_in) = generate_jwt(
        $email, secret => $self->config->{jwt}{secret},
        expires_in => $self->config->{jwt}{expiry_seconds}, jti => $jti,
    );
    my $refresh_token    = generate_refresh_token();
    my $refresh_ttl_days = $self->config->{jwt}{refresh_expiry_days} // 30;

    my $refresh_row = $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at)
          VALUES (?, ?, NOW() + (? * INTERVAL '1 day')) RETURNING id},
        $user_id, $refresh_token, $refresh_ttl_days,
    )->hash;
    $self->pg->db->query(
        q{INSERT INTO api.sessions (jti, user_id, refresh_token_id, expires_at, user_agent, ip_address, first_seen_at)
          VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 second'), ?, ?, NOW())},
        $jti, $user_id, $refresh_row->{id}, $expires_in, 'homelab-agent', $c->tx->remote_address,
    );
    return ($jwt, $refresh_token, $expires_in);
}

# POST /api/v1/admin/agent/enroll {hostname, ttl_minutes?}
# site_admin mints a short-lived, single-use code for a new host's
# agent to redeem below for its first JWT + refresh_token -- the one
# genuinely new credential-issuance path this design needs; everything
# downstream of redemption reuses the rotating-refresh-token/session-
# revocation machinery that already exists for human logins.
sub _agent_enroll ($self, $c) {
    my $admin = $self->_require_site_admin($c) or return;
    my $body     = $c->req->json // {};
    my $hostname = $body->{hostname};
    return $c->render(json => { error => 'hostname is required' }, status => 400) unless $hostname;

    my $code        = generate_refresh_token();
    my $ttl_minutes = $body->{ttl_minutes} // 10;
    $self->pg->db->query(
        q{INSERT INTO api.agent_enrollment_codes (code, hostname, issued_by, expires_at)
          VALUES (?, ?, ?, NOW() + (? * INTERVAL '1 minute'))},
        $code, $hostname, $admin->{email}, $ttl_minutes,
    );
    return $c->render(json => { code => $code, hostname => $hostname, expires_in_minutes => $ttl_minutes }, status => 201);
}

# POST /api/v1/agent/enroll/redeem {code}
# Deliberately unauthenticated going in -- the code itself is the
# credential, same as any OAuth2 device-authorization-grant exchange --
# but single-use (used_at) and short-lived (expires_at, set by
# _agent_enroll above). Creates this agent's synthetic identity
# (agent+<hostname>@system.homelab, system_agent role) on first
# redemption; a later re-enrollment of the same hostname (e.g. after its
# refresh_token has fully lapsed from being offline past its own expiry)
# reuses the existing identity rather than creating a duplicate.
sub _agent_enroll_redeem ($self, $c) {
    my $body = $c->req->json // {};
    my $code = $body->{code};
    return $c->render(json => { error => 'code is required' }, status => 400) unless $code;

    my $row = $self->pg->db->query(
        q{SELECT hostname FROM api.agent_enrollment_codes
          WHERE code = ? AND used_at IS NULL AND expires_at > NOW()},
        $code,
    )->hash;
    return $c->render(json => { error => 'invalid, expired, or already-used code' }, status => 401) unless $row;

    $self->pg->db->query('UPDATE api.agent_enrollment_codes SET used_at = NOW() WHERE code = ?', $code);

    my $email = "agent+$row->{hostname}\@system.homelab";
    my $user  = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash;
    unless ($user) {
        # Random, unusable, never disclosed password -- same assumption
        # _login's system_agent guard is belt-and-suspenders on top of.
        $user = $self->pg->db->query(
            q{INSERT INTO api.users (email, password_hash, active) VALUES (?, ?, true) RETURNING id},
            $email, generate_refresh_token(),
        )->hash;
        my $role = $self->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'system_agent'})->hash;
        $self->pg->db->query(
            'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
            $user->{id}, $role->{id},
        );
    }

    my ($jwt, $refresh_token, $expires_in) = $self->_mint_session_blocking($email, $user->{id}, $c);
    return $c->render(json => {
        success => \1, token => $jwt, refresh_token => $refresh_token, expires_in => $expires_in,
    }, status => 201);
}

# POST /api/v1/agent/heartbeat
# {hostname, address, agent_port, agent_version?, services: [{name, package, kind, expected, actual, description}]}
# Requires this agent's own system_agent-roled JWT. Checked in-process
# here (never a remote introspect round trip) because homelab-api
# already holds the signing secret itself -- same reasoning _jwt_jti's
# own comment already gives for why homelab-api specifically never needs
# that round trip for its own authentication checks, unlike every other
# service.
sub _agent_heartbeat ($self, $c) {
    my $caller = $self->_require_system_agent($c) or return;
    my $body   = $c->req->json // {};
    for my $field (qw(hostname address agent_port)) {
        return $c->render(json => { error => "$field is required" }, status => 400)
            unless defined $body->{$field};
    }

    $self->pg->db->query(
        q{INSERT INTO api.hosts (hostname, address, agent_port, agent_version, last_heartbeat)
          VALUES (?, ?, ?, ?, NOW())
          ON CONFLICT (hostname) DO UPDATE
              SET address = EXCLUDED.address, agent_port = EXCLUDED.agent_port,
                  agent_version = EXCLUDED.agent_version, last_heartbeat = NOW()},
        $body->{hostname}, $body->{address}, $body->{agent_port}, $body->{agent_version},
    );

    # Delete-then-insert, not a plain per-service upsert: a pure upsert
    # loop only ever adds/updates rows for services THIS heartbeat
    # mentions, so a service removed from a host's manifest (package
    # uninstalled, or a whole service relocated off this host -- see
    # the PowerDNS-off-the-edge-host move) leaves a permanently stale
    # row behind forever, `fleet status` silently lying about a service
    # still running here long after it's gone. Deleting this host's
    # rows first and re-inserting exactly what THIS heartbeat reports
    # makes the table an accurate mirror of the current manifest, not
    # an accumulating superset of every manifest this host has ever had.
    $self->pg->db->query('DELETE FROM api.host_service_status WHERE hostname = ?', $body->{hostname});

    for my $svc (@{ $body->{services} // [] }) {
        $self->pg->db->query(
            q{INSERT INTO api.host_service_status
                  (hostname, service_name, package_name, kind, expected, actual, description, fronts, checked_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())},
            $body->{hostname}, $svc->{name}, $svc->{package}, $svc->{kind},
            ($svc->{expected} ? 1 : 0), ($svc->{actual} ? 1 : 0), $svc->{description}, $svc->{fronts},
        );
    }

    return $c->render(json => { ok => \1 });
}

# GET /api/v1/admin/agent/hosts -- every host that's ever heartbeated,
# and how long ago. A hostname absent here entirely (not just stale)
# means its agent has never successfully enrolled+heartbeated at all.
sub _agent_list_hosts ($self, $c) {
    $self->_require_site_admin($c) or return;
    return $c->render(json => $self->pg->db->query(
        'SELECT hostname, address, agent_port, agent_version, last_heartbeat FROM api.hosts ORDER BY hostname',
    )->hashes->to_array);
}

# GET /api/v1/admin/agent/status -- every declared-or-observed service
# across the whole fleet, expected vs actual, as of each host's own last
# heartbeat.
sub _agent_list_status ($self, $c) {
    $self->_require_site_admin($c) or return;
    return $c->render(json => $self->pg->db->query(
        q{SELECT hostname, service_name, package_name, kind, expected, actual, description, fronts, checked_at
          FROM api.host_service_status ORDER BY service_name, hostname},
    )->hashes->to_array);
}

# GET /api/v1/admin/agent/status/mismatches -- just the actionable rows:
# expected=true/actual=false (a real outage) or expected=false/
# actual=true (an undeclared surprise -- exactly what the loopback-only
# stock postfix on every ct0N container would have shown up as here).
sub _agent_list_mismatches ($self, $c) {
    $self->_require_site_admin($c) or return;
    return $c->render(json => $self->pg->db->query(
        q{SELECT hostname, service_name, package_name, kind, expected, actual, description, fronts, checked_at
          FROM api.host_service_status WHERE expected != actual ORDER BY service_name, hostname},
    )->hashes->to_array);
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

    # actor_email/affected_user genuinely differ here whenever a
    # site_admin revokes a DIFFERENT user's session via ?user= -- the
    # exact "admin action on someone else's account" case affected_user
    # exists for (this comment block already called this "the safer,
    # auditable primitive"; it wasn't actually enqueuing anything until
    # now).
    enqueue(
        $self->pg->db, actor_email => $caller->{email}, affected_user => $target->{email},
        jti => $self->_jwt_jti($c), action => 'session.revoke',
        resource_type => 'session', resource_id => $row->{jti}, source_service => 'homelab-api',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
    );
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
    # Always self-scoped (see comment above) -- actor and affected_user
    # are always the same account here, one entry per session killed.
    for my $row (@$rows) {
        enqueue(
            $self->pg->db, actor_email => $caller->{email}, affected_user => $caller->{email},
            jti => $jti, action => 'session.revoke',
            resource_type => 'session', resource_id => $row->{jti}, source_service => 'homelab-api',
            ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        );
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
# POST /api/v1/admin/users/:id/active { active: bool } -- suspend or
# re-enable a user's login. api.users.active gates EVERY login path (web,
# SSO, IMAP, SMTP), so this one flag pauses/restores all of them. On
# suspend we also revoke the user's live sessions so they're kicked
# immediately, not just blocked at next login.
sub _admin_set_active ($self, $c) {
    my $admin = $self->_require_site_admin($c) or return;
    my $id = $c->stash('id');
    return $c->render(json => { error => 'invalid user id' }, status => 400)
        unless defined $id && $id =~ /^\d+$/;
    my $active = $c->req->json->{active} ? 1 : 0;
    return $c->render(json => { error => 'you cannot suspend your own account' }, status => 400)
        if !$active && $id == $admin->{id};

    my $row = $self->pg->db->query(
        'UPDATE api.users SET active = ? WHERE id = ? RETURNING id, email, active',
        ($active ? 'true' : 'false'), $id)->hash;
    return $c->render(json => { error => 'user not found' }, status => 404) unless $row;
    $self->pg->db->query('UPDATE api.sessions SET revoked = TRUE WHERE user_id = ? AND revoked = FALSE', $id)
        unless $active;
    return $c->render(json => { ok => \1, id => $row->{id}, email => $row->{email}, active => ($row->{active} ? \1 : \0) });
}

# POST /api/v1/admin/users/:id/mail-quota { limit_bytes } -- site_admin
# sets (or clears, when limit_bytes is omitted/empty) a user's mail-quota
# override. NULL falls back to the fleet default; dovecot's userdb reads
# this column and emits a quota_rule when it's set.
sub _admin_set_mail_quota ($self, $c) {
    $self->_require_site_admin($c) or return;
    my $id = $c->stash('id');
    return $c->render(json => { error => 'invalid user id' }, status => 400)
        unless defined $id && $id =~ /^\d+$/;
    my $limit = $c->req->json->{limit_bytes};
    my $clear = (!defined $limit || $limit eq '');
    return $c->render(json => { error => 'limit_bytes must be a non-negative integer' }, status => 400)
        unless $clear || "$limit" =~ /^\d+$/;
    my $row = $self->pg->db->query(
        'UPDATE api.users SET mail_quota_bytes = ? WHERE id = ? RETURNING email',
        ($clear ? undef : $limit + 0), $id)->hash;
    return $c->render(json => { error => 'user not found' }, status => 404) unless $row;
    return $c->render(json => {
        ok => \1, email => $row->{email},
        mail_quota_bytes => ($clear ? undef : $limit + 0),
        ($clear ? (note => 'reset to default') : ()),
    });
}

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

    my $target = $self->pg->db->query('SELECT id, email FROM api.users WHERE id = ?', $user_id)->hash;
    return $c->render(json => { error => 'user not found' }, status => 404) unless $target;

    my $role_row = $self->pg->db->query('SELECT id FROM api.roles WHERE name = ?', $role)->hash;
    return $c->render(json => { error => "unknown role: $role" }, status => 400) unless $role_row;

    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user_id, $role_row->{id},
    );
    # actor is the admin performing the grant; affected_user is whoever
    # is RECEIVING the role -- these genuinely differ (the whole reason
    # affected_user exists as its own field), so a query for "everything
    # that touched $target's account" (?affecting=) surfaces this even
    # though $target never acted themselves.
    enqueue(
        $self->pg->db, actor_email => $admin->{email}, affected_user => $target->{email},
        jti => $self->_jwt_jti($c), action => 'role.grant',
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

    # api.users is untouched by the DELETE below, so this lookup is safe
    # either side of it -- done first here just to keep the "resolve
    # affected_user" step visually next to $user_id's own definition.
    # Falls back to a synthetic identifier rather than skipping the
    # audit entry outright if $user_id doesn't resolve to a real row
    # (e.g. a stale/garbage id) -- affected_user is a required field,
    # and the revoke attempt itself still happened either way.
    my $target = $self->pg->db->query('SELECT email FROM api.users WHERE id = ?', $user_id)->hash;
    my $affected_user = $target ? $target->{email} : "user_id:$user_id";

    $self->pg->db->query(
        q{DELETE FROM api.user_roles WHERE user_id = ?
          AND role_id = (SELECT id FROM api.roles WHERE name = ?)},
        $user_id, $role,
    );
    enqueue(
        $self->pg->db, actor_email => $admin->{email}, affected_user => $affected_user,
        jti => $self->_jwt_jti($c), action => 'role.revoke',
        resource_type => 'user', resource_id => $user_id, source_service => 'homelab-api',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { role => $role },
    );
    return $c->render(json => { ok => \1 });
}

# POST /api/v1/admin/users/service-account {email, password?}
# Same shape as a normal registration (real api.users row, real
# Argon2id hash, unified identity model) but site_admin-only and with
# no invite_token/require_invite gating -- an operator creating a
# system mailbox (e.g. invites@<domain>) isn't the self-service flow
# that gate exists for, and (see _invite_recipient_domain_check above)
# that gate now actively REJECTS any address on a domain this fleet
# manages mail for -- exactly the domain a real system mailbox or an
# operator's own test/admin account almost always needs to live on.
# `password` is optional: omitted (the original, still-default case)
# auto-generates one and returns it, same reasoning as homelab-sso's
# own client-secret generation -- nobody should be typing a pure
# system identity's password in anywhere, it only ever needs to be
# pasted once into another package's debconf (mailer_smtp_password).
# Given explicitly, it's used as-is (still Argon2id-hashed the same
# way) -- for an operator's own admin account (needs a password they
# already know) or an automated test suite's disposable fixture
# accounts (needs a password the test code itself controls) -- both
# real, site_admin-authenticated callers, so accepting a caller-chosen
# secret here is no different a trust boundary than _register already
# has for a self-service signup.
sub _admin_create_service_account ($self, $c) {
    my $admin = $self->_require_site_admin($c) or return;

    my $body = $c->req->json // {};
    my $email = $body->{email};
    return $c->render(json => { error => 'email is required' }, status => 400) unless $email;
    return $c->render(json => { error => 'password must be at least 8 characters' }, status => 400)
        if defined($body->{password}) && length($body->{password}) < 8;

    my $existing = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash;
    return $c->render(json => { error => 'email already registered' }, status => 409) if $existing;

    my $password = $body->{password}
        // unpack('H*', do { open(my $fh, '<', '/dev/urandom') or die $!; read($fh, my $b, 24); $b });
    my $hash     = hash_password($password);
    my $user     = $self->pg->db->query(
        'INSERT INTO api.users (email, password_hash) VALUES (?, ?) RETURNING id',
        $email, $hash,
    )->hash;

    my $user_role_id = $self->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'user'})->hash->{id};
    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user->{id}, $user_role_id,
    );

    enqueue(
        $self->pg->db, actor_email => $admin->{email}, affected_user => $email,
        jti => $self->_jwt_jti($c), action => 'user.create_service_account',
        resource_type => 'user', resource_id => $user->{id}, source_service => 'homelab-api',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => {},
    );
    return $c->render(json => { id => $user->{id}, email => $email, password => $password }, status => 201);
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
# Confirmed the only caller is _introspect above (see that route's own
# comment) -- converted in place rather than kept alongside a dead
# blocking twin.
sub _has_capability_p ($self, $user_id, $name) {
    return $self->pg->db->query_p(
        q{SELECT 1 FROM api.user_roles ur JOIN api.roles r ON r.id = ur.role_id
          WHERE ur.user_id = ? AND r.name = 'site_admin'},
        $user_id,
    )->then(sub ($results) {
        return 1 if $results->hash;
        return $self->pg->db->query_p(
            q{SELECT 1 FROM api.user_roles ur
              JOIN api.role_permissions rp ON rp.role_id = ur.role_id
              JOIN api.permissions p ON p.id = rp.permission_id
              WHERE ur.user_id = ? AND p.name = ?},
            $user_id, $name,
        )->then(sub ($results2) { return $results2->hash ? 1 : 0 });
    });
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
