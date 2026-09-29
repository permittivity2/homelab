package Homelab::Accountmanage::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::UserAgent;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);

# Account self-service + administration UI. Deliberately a THIN BFF: it
# owns no data and no database of its own -- it authenticates the browser
# via homelab-sso (same OAuth flow as homelab-drive) and then aggregates
# read/write calls to the existing services (homelab-api for account
# info/sessions/password, homelab-drive for storage usage, etc.) with the
# logged-in user's own token, rendering one themed dashboard. Everything
# it shows is gated by what that token is actually allowed to do.

has 'api_base';
has 'sso_base';
has 'sso_internal_base';
has 'sso_client_id';
has 'sso_client_secret';
has 'sso_redirect_uri';
has 'public_base_url';

sub startup ($self) {
    # Templates land at /usr/share/homelab-accountmanage/templates, not
    # next to the /usr/bin entrypoint -- same HOMELAB_*_HOME convention as
    # every other homelab-* Mojolicious app.
    my $home = $ENV{HOMELAB_ACCOUNTMANAGE_HOME} // '/usr/share/homelab-accountmanage';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_ACCOUNTMANAGE_CONFIG', '/etc/homelab/accountmanage/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2503'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/accountmanage-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);
    # Distinct cookie name (not Mojolicious's shared default) -- holds
    # real OAuth login state, same convention as homelab-drive/sso. If
    # this app is ever pooled, add sticky_cookie: homelab-accountmanage in
    # webproxy's sites.yml (no app change needed).
    $self->sessions->cookie_name('homelab-accountmanage');

    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->public_base_url($config->{public_base_url} // die "config: public_base_url is required\n");

    my $sso = $config->{sso} // die "config: sso.* is required (see config/accountmanage.example.yml)\n";
    $self->sso_base($sso->{base_url} // die "config: sso.base_url is required\n");
    # base_url is the BROWSER redirect target (must be the public SSO
    # vhost); internal_base_url is this app's own server-to-server
    # exchange_code() call (defaults to base_url for the single-host case).
    # Same split + gotcha as homelab-drive -- see its App.pm.
    $self->sso_internal_base($sso->{internal_base_url} // $sso->{base_url});
    $self->sso_client_id($sso->{client_id} // die "config: sso.client_id is required\n");
    $self->sso_client_secret($sso->{client_secret} // die "config: sso.client_secret is required\n");
    $self->sso_redirect_uri($sso->{redirect_uri} // die "config: sso.redirect_uri is required\n");

    # No DB of its own -- health is just "the process is up".
    mount_health_route($self, check => sub { 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-accountmanage',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Account self-service + administration web UI',
            log => $self->log,
        );
    }

    my $r = $self->routes;
    $r->get('/')                 ->to('account#dashboard');
    $r->get('/login')            ->to('account#login_form');
    $r->get('/oauth/callback')   ->to('account#oauth_callback');
    $r->post('/logout')          ->to('account#logout');
    # Session management actions (browser posts here; we proxy to
    # homelab-api with the user's own token).
    $r->post('/sessions/:jti/revoke')->to('account#revoke_session');
    $r->post('/sessions/revoke-others')->to('account#revoke_others');
    # Security actions (proxy to homelab-api with the user's token).
    $r->post('/security/password')->to('account#change_password');
    $r->post('/security/recovery-email')->to('account#set_recovery_email');
    # Self-service Mail settings (any logged-in user; own account only).
    $r->get('/mail/self')       ->to('account#mail_self');
    $r->post('/mail/block-link')->to('account#mail_set_block_link');
    $r->post('/mail/block')     ->to('account#mail_block');
    $r->post('/mail/unblock')   ->to('account#mail_unblock');
    # Invites (self-service) + account activity (self-scoped audit).
    $r->get('/invites')        ->to('account#invites_list');
    $r->post('/invites/send')  ->to('account#invites_send');
    $r->post('/invites/revoke')->to('account#invites_revoke');
    $r->get('/activity')       ->to('account#activity_list');
    # Administration actions (site_admin; each re-checks + proxies to the
    # owning service with the admin's token).
    $r->post('/admin/users/:id/active')->to('account#admin_set_active');
    $r->post('/admin/drive-quota')     ->to('account#admin_drive_quota');
    $r->post('/admin/mail-quota')      ->to('account#admin_mail_quota');
    $r->post('/admin/block-link')      ->to('account#admin_block_link');
    $r->post('/admin/dkim')            ->to('account#admin_dkim');
    $r->post('/admin/spf')             ->to('account#admin_spf');
    $r->post('/admin/dmarc')           ->to('account#admin_dmarc');
    $r->post('/admin/domains/add')     ->to('account#admin_domain_add');
    $r->post('/admin/domains/toggle')  ->to('account#admin_domain_toggle');
    # Send-as grants (mail aliases) + site-wide recipient access (JSON).
    $r->get('/admin/mail-aliases')          ->to('account#admin_aliases_list');
    $r->post('/admin/mail-aliases/add')     ->to('account#admin_alias_add');
    $r->post('/admin/mail-aliases/set-send')->to('account#admin_alias_set_send');
    $r->post('/admin/mail-aliases/remove')  ->to('account#admin_alias_remove');
    $r->get('/admin/recipient-access')       ->to('account#admin_racc_list');
    $r->post('/admin/recipient-access/set')  ->to('account#admin_racc_set');
    $r->post('/admin/recipient-access/remove')->to('account#admin_racc_remove');
    # Live user search for the admin typeahead (JSON; site_admin gated).
    $r->get('/admin/users/search')     ->to('account#admin_users_search');
    # Live usage-by-user for the quota forms (JSON; site_admin gated).
    $r->get('/admin/usage')            ->to('account#admin_user_usage');
    # Service accounts, per-user invite quota, a user's sessions (site_admin).
    $r->post('/admin/users/create-service-account')->to('account#admin_create_service_account');
    $r->get('/admin/invite-quota')     ->to('account#admin_invite_quota_get');
    $r->post('/admin/invite-quota')    ->to('account#admin_invite_quota_set');
    $r->get('/admin/user-sessions')    ->to('account#admin_user_sessions');
    $r->post('/admin/user-sessions/revoke')->to('account#admin_user_session_revoke');
    # Dovecot pool status (JSON; site_admin gated).
    $r->get('/admin/dovecot/status')         ->to('account#admin_dovecot_status');
    # Roles & permissions (RBAC; JSON; site_admin gated).
    $r->get('/admin/roles')             ->to('account#admin_roles_list');
    $r->post('/admin/roles/add')        ->to('account#admin_role_add');
    $r->post('/admin/roles/remove')     ->to('account#admin_role_remove');
    $r->post('/admin/roles/grant-perm') ->to('account#admin_role_grant_perm');
    $r->post('/admin/roles/revoke-perm')->to('account#admin_role_revoke_perm');
    $r->post('/admin/users/grant-role') ->to('account#admin_user_grant_role');
    $r->post('/admin/users/revoke-role')->to('account#admin_user_revoke_role');
    # Domain catch-all routing (JSON; site_admin gated).
    $r->get('/admin/domains/catch-alls')     ->to('account#admin_catchalls');
    $r->post('/admin/domains/catch-all/set')  ->to('account#admin_set_catchall');
    $r->post('/admin/domains/catch-all/clear')->to('account#admin_clear_catchall');
    $r->post('/admin/domains/catch-all/bulk') ->to('account#admin_bulk_catchall');

    return;
}

package Homelab::Accountmanage::App::Controller::Account;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::URL;
use Mojo::UserAgent;
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient qw(exchange_code);

# Server-to-server client for calling homelab-api with the logged-in
# user's bearer token. Short timeout: these are quick JSON calls behind
# the dashboard render; a slow/down backend should degrade to "unavailable"
# in one panel, not hang the whole page.
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 15);

sub _random_state { return join '', map { sprintf '%02x', int rand 256 } 1 .. 16 }

# Bearer header first (unused today, but keeps parity with every other
# homelab app's dual browser/API auth), then the session cookie's token.
sub _current_auth ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    $jwt //= $c->session('token');
    return (undef, undef, undef) unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $result ? ($result->{email}, $jwt, ($result->{roles} // [])) : (undef, undef, undef);
}

# Admin gate for the Administration pane's actions: ($email, $jwt) if the
# caller holds site_admin, else (undef, undef). Backends re-check too;
# this is defense-in-depth + lets the UI fail fast.
sub _admin_auth ($c) {
    my ($email, $jwt, $roles) = _current_auth($c);
    return (undef, undef) unless $email && grep { $_ eq 'site_admin' } @$roles;
    return ($email, $jwt);
}

# GET a homelab-api path with the user's token; returns decoded JSON, or
# undef on any non-2xx / transport error (callers render "unavailable").
sub _api_get ($c, $jwt, $path) {
    my $tx = $UA->get($c->app->api_base . $path => { Authorization => "Bearer $jwt" });
    return undef unless $tx->res->code && $tx->res->code >= 200 && $tx->res->code < 300;
    return $tx->res->json;
}

sub login_form ($c) {
    my ($email) = _current_auth($c);
    return $c->redirect_to('/') if $email;

    my $state = _random_state();
    $c->session(oauth_state => $state);
    my $url = Mojo::URL->new($c->app->sso_base . '/oauth/authorize')->query(
        client_id    => $c->app->sso_client_id,
        redirect_uri => $c->app->sso_redirect_uri,
        state        => $state,
        scope        => 'openid',
    );
    return $c->redirect_to($url);
}

sub oauth_callback ($c) {
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state');
    $c->session(oauth_state => undef);

    unless ($code && $expected && $state eq $expected) {
        return $c->render(template => 'login', error => 'Sign-in expired or was invalid. Please try again.', status => 400);
    }
    my $result = exchange_code($code,
        sso_base      => $c->app->sso_internal_base,
        client_id     => $c->app->sso_client_id,
        client_secret => $c->app->sso_client_secret,
        redirect_uri  => $c->app->sso_redirect_uri,
    );
    unless ($result->{success}) {
        return $c->render(template => 'login', error => 'Could not complete sign-in. Please try again.', status => 502);
    }
    $c->session(token => $result->{access_token}, refresh_token => $result->{refresh_token});
    return $c->redirect_to('/');
}

sub logout ($c) {
    $c->session(expires => 1);
    my $post_logout_uri = Mojo::URL->new($c->app->sso_redirect_uri)->path('/login');
    my $url = Mojo::URL->new($c->app->sso_base . '/logout')->query(redirect_uri => $post_logout_uri);
    return $c->redirect_to($url);
}

sub dashboard ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;

    # Account summary is the source of truth for identity/roles here; a
    # 401 means the cookie's token has expired/been revoked -> re-login.
    my $summary = _api_get($c, $jwt, '/api/v1/account/summary');
    return $c->redirect_to('/login') unless $summary;

    my $sessions = _api_get($c, $jwt, '/api/v1/auth/sessions') // [];
    # Drive + mail usage via the api gateway (/api/v1/drive/* -> homelab-drive,
    # /api/v1/mail/* -> homelab-mailbridge); undef if that backend is
    # unavailable -> the panel shows "unavailable". Both return the same
    # {used_bytes, limit_bytes} shape so the template renders them identically.
    my $drive_usage = _api_get($c, $jwt, '/api/v1/drive/usage');
    my $mail_usage  = _api_get($c, $jwt, '/api/v1/mail/usage');

    my $roles    = $summary->{roles} // [];
    my $is_admin = grep { $_ eq 'site_admin' } @$roles;

    # Admin pane data (only for site_admins): the managed domains (for the
    # block-link toggle + DKIM/SPF/DMARC selects). The USER list is NOT
    # pre-loaded any more -- with potentially thousands of accounts the
    # Users card and the quota forms use the live /admin/users/search
    # typeahead instead. Best-effort -- degrades to empty if unavailable.
    my $admin_domains = [];
    if ($is_admin) {
        $admin_domains = _api_get($c, $jwt, '/api/v1/domains') // [];
    }

    return $c->render(
        template     => 'dashboard',
        email        => $email,
        summary      => $summary,
        sessions     => $sessions,
        drive_usage  => $drive_usage,
        mail_usage   => $mail_usage,
        roles        => $roles,
        is_admin     => ($is_admin ? 1 : 0),
        admin_domains => $admin_domains,
        sso_forgot_url => $c->app->sso_base . '/forgot',
    );
}

sub revoke_session ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $jti = $c->stash('jti');
    if (defined $jti && $jti =~ /\S/) {
        $UA->delete($c->app->api_base . "/api/v1/auth/sessions/$jti" => { Authorization => "Bearer $jwt" });
    }
    return $c->redirect_to('/');
}

sub revoke_others ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    $UA->delete($c->app->api_base . '/api/v1/auth/sessions?except_current=true' => { Authorization => "Bearer $jwt" });
    return $c->redirect_to('/');
}

# In-place password change: proxy to homelab-api's authenticated
# POST /api/v1/auth/password with the user's token. Feedback via flash.
sub change_password ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $cur     = $c->param('current_password') // '';
    my $new     = $c->param('new_password') // '';
    my $confirm = $c->param('confirm_password') // '';
    if ($cur eq '' || $new eq '') { $c->flash(pw_error => 'Both current and new password are required.'); return $c->redirect_to('/#security'); }
    if ($new ne $confirm)         { $c->flash(pw_error => 'The new passwords do not match.'); return $c->redirect_to('/#security'); }
    if (length($new) < 8)         { $c->flash(pw_error => 'New password must be at least 8 characters.'); return $c->redirect_to('/#security'); }

    my $tx = $UA->post($c->app->api_base . '/api/v1/auth/password'
        => { Authorization => "Bearer $jwt" }
        => json => { current_password => $cur, new_password => $new });
    if (($tx->res->code // 0) == 200) {
        $c->flash(pw_ok => 'Password changed. Your other sessions have been signed out.');
    } else {
        $c->flash(pw_error => (eval { $tx->res->json->{error} } // 'Could not change password.'));
    }
    return $c->redirect_to('/#security');
}

# Set / change / clear the recovery email: proxy to homelab-api's
# POST /api/v1/account/recovery-email.
sub set_recovery_email ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $re = $c->param('recovery_email') // '';
    my $tx = $UA->post($c->app->api_base . '/api/v1/account/recovery-email'
        => { Authorization => "Bearer $jwt" }
        => json => { recovery_email => $re });
    if (($tx->res->code // 0) == 200) {
        $c->flash(re_ok => ($re eq '' ? 'Recovery email cleared.' : 'Recovery email saved.'));
    } else {
        $c->flash(re_error => (eval { $tx->res->json->{error} } // 'Could not save recovery email.'));
    }
    return $c->redirect_to('/#security');
}

# --- Administration (site_admin) -----------------------------------------

# Flash the outcome of an admin proxy call, then the caller redirects to
# the Administration pane.
sub _admin_flash ($c, $tx, $ok_msg) {
    if (($tx->res->code // 0) >= 200 && ($tx->res->code // 0) < 300) {
        $c->flash(admin_ok => $ok_msg);
    } else {
        $c->flash(admin_err => (eval { $tx->res->json->{error} } // ('Action failed (HTTP ' . ($tx->res->code // 0) . ').')));
    }
}

# Suspend / re-enable a user's login (api.users.active gates every login
# path). Form posts action=suspend|enable.
sub admin_set_active ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $id     = $c->stash('id');
    my $enable = (($c->param('action') // '') eq 'enable') ? \1 : \0;
    my $tx = $UA->post($c->app->api_base . "/api/v1/admin/users/$id/active"
        => { Authorization => "Bearer $jwt" } => json => { active => $enable });
    _admin_flash($c, $tx, ($$enable ? 'User re-enabled.' : 'User suspended (and signed out).'));
    return $c->redirect_to('/#admin:users');
}

# Set a user's drive quota (GB). Empty limit clears the override (back to
# the 1 TB default).
sub admin_drive_quota ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $user = $c->param('user_email') // '';
    my $gb   = $c->param('limit_gb') // '';
    my %body = (user_email => $user);
    $body{limit_bytes} = int($gb) * 1024 * 1024 * 1024 if $gb ne '' && $gb =~ /^\d+$/;
    my $tx = $UA->put($c->app->api_base . '/api/v1/drive/admin/quota'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    _admin_flash($c, $tx, ($gb eq '' ? "Drive quota for $user reset to default." : "Drive quota for $user set to ${gb} GB."));
    return $c->redirect_to('/#admin:quotas');
}

# Set a user's mail (dovecot) quota (GB). Empty limit clears the override
# (back to the 1 TB default). Unlike drive-quota, the mail-quota API is keyed
# by user id (POST /api/v1/admin/users/:id/mail-quota), so resolve the email
# to an id from the admin user list first.
sub admin_mail_quota ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $user = $c->param('user_email') // '';
    my $gb   = $c->param('limit_gb') // '';
    my $users = _api_get($c, $jwt, '/api/v1/admin/users') // [];
    my ($u) = grep { ($_->{email} // '') eq $user } @$users;
    unless ($u) {
        $c->flash(admin_err => "No such user: $user");
        return $c->redirect_to('/#admin:quotas');
    }
    my %body;
    $body{limit_bytes} = int($gb) * 1024 * 1024 * 1024 if $gb ne '' && $gb =~ /^\d+$/;
    my $tx = $UA->post($c->app->api_base . "/api/v1/admin/users/$u->{id}/mail-quota"
        => { Authorization => "Bearer $jwt" } => json => \%body);
    _admin_flash($c, $tx, ($gb eq '' ? "Mail quota for $user reset to default." : "Mail quota for $user set to ${gb} GB."));
    return $c->redirect_to('/#admin:quotas');
}

# Live user search for the admin typeahead. Proxies to the api gateway's
# GET /api/v1/admin/users?q=... (site_admin gated there too; this handler
# re-checks site_admin locally as defense-in-depth). Returns the JSON
# array straight through for the front-end. >=3-char minimum is enforced
# on both sides.
sub admin_users_search ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $q = $c->param('q') // '';
    return $c->render(json => []) if length($q) < 3;
    # Mojo::URL->query url-encodes q so a '+'/space/'%' in the typed value
    # can't corrupt the forwarded request.
    my $path = Mojo::URL->new('/api/v1/admin/users')->query(q => $q, limit => 20)->to_string;
    return $c->render(json => (_api_get($c, $jwt, $path) // []));
}

# GET /admin/usage?type=drive|mail&user_email=<addr> -- proxies to the
# owning service's admin usage-by-user endpoint so the quota forms can show
# "currently using X of Y" and warn before setting a limit below it. Returns
# {used_bytes, limit_bytes} (or an error the front-end renders as
# "unavailable"). site_admin gated here + re-checked by the backend.
sub admin_user_usage ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    my $type = $c->param('type') // 'drive';
    my $user = $c->param('user_email') // '';
    return $c->render(json => { error => 'bad email' }, status => 400) unless $user =~ /\@/;
    # NB: mail usage is on the API itself (/api/v1/admin/*), NOT under
    # /api/v1/mail/* -- the gateway forwards that whole prefix to mailbridge,
    # which has no DB. The clone-mirrored usage lives in the API's own DB.
    my %backend = (
        drive => '/api/v1/drive/admin/usage',
        mail  => '/api/v1/admin/mail-usage',
    );
    my $base = $backend{$type}
        or return $c->render(json => { error => 'bad type' }, status => 400);
    my $path = Mojo::URL->new($base)->query(user_email => $user)->to_string;
    my $r = _api_get($c, $jwt, $path);
    return $c->render(json => ($r // { error => 'unavailable' }), status => ($r ? 200 : 502));
}

# True iff $addr is a real, active api.users mailbox. Reuses the admin user
# search (ILIKE-prefix on a full address returns it) and checks for an exact
# case-insensitive match -- the black-hole guard for catch-all destinations
# (domain-admin's DB role can't see api.users, so this validation lives here).
sub _user_exists ($c, $jwt, $addr) {
    return 0 unless $addr && $addr =~ /\@/ && length($addr) >= 3;
    my $path = Mojo::URL->new('/api/v1/admin/users')->query(q => $addr, limit => 20)->to_string;
    my $users = _api_get($c, $jwt, $path) // [];
    return scalar grep { lc($_->{email} // '') eq lc($addr) } @$users;
}

# ===== Invites + account activity (self-service) =====

# GET /invites -- your invites + your effective invite quota.
sub invites_list ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => {
        invites => (_api_get($c, $jwt, '/api/v1/invites') // []),
        quota   => (_api_get($c, $jwt, '/api/v1/invites/quota') // {}),
    });
}

# POST /invites/send {recipient_email, message?}
sub invites_send ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient_email') // '');
    return $c->render(json => { error => 'a recipient email is required' }, status => 400) unless $recipient =~ /\@/;
    my %body = (recipient_email => $recipient, channel => 'web');
    my $msg = _trim($c->param('message') // '');
    $body{message} = $msg if length $msg;
    my $tx = $UA->post($c->app->api_base . '/api/v1/invites'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'send failed' }), status => ($tx->res->code // 502));
}

# POST /invites/revoke {invite_id}
sub invites_revoke ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $id = _trim($c->param('invite_id') // '');
    return $c->render(json => { error => 'invite_id required' }, status => 400) unless $id =~ /^\d+$/;
    my $tx = $UA->delete($c->app->api_base . "/api/v1/invites/$id"
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# GET /activity -- your own recent account activity (self-scoped audit trail).
sub activity_list ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/audit/log') // []));
}

# ===== Self-service Mail settings (any logged-in user, own account only) =====

# GET /mail/self -- aggregates the three self-service mail reads in one call:
# send-as grants, click-to-block setting, and self-blocked recipients. All use
# the caller's OWN token against the /mine endpoints (never site_admin).
sub mail_self ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => {
        send_as    => (_api_get($c, $jwt, '/api/v1/domains/mail-aliases/mine') // {}),
        block_link => (_api_get($c, $jwt, '/api/v1/block-link/account') // {}),
        blocked    => (_api_get($c, $jwt, '/api/v1/domains/recipient-access/mine') // []),
    });
}

# POST /mail/block-link {enabled} -- toggle the caller's own click-to-block link.
sub mail_set_block_link ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $enabled = $c->param('enabled') ? \1 : \0;
    my $tx = $UA->put($c->app->api_base . '/api/v1/block-link/account'
        => { Authorization => "Bearer $jwt" } => json => { enabled => $enabled });
    return $c->render(json => (eval { $tx->res->json } // {}), status => ($tx->res->code // 502));
}

# POST /mail/block {recipient} -- reject all future mail to one of the caller's
# own addresses (the api enforces that it must be theirs).
sub mail_block ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'a valid address is required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/recipient-access/mine'
        => { Authorization => "Bearer $jwt" } => json => { recipient => $recipient, action => 'REJECT' });
    return $c->render(json => (eval { $tx->res->json } // { error => 'block failed' }), status => ($tx->res->code // 502));
}

# POST /mail/unblock {recipient} -- undo a self-block.
sub mail_unblock ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'a valid address is required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/recipient-access/mine/' . Mojo::Util::url_escape($recipient)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Service accounts / invite quota / a user's sessions, site_admin -----
sub admin_create_service_account ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $addr = _trim($c->param('email') // '');
    return $c->render(json => { error => 'a valid email is required' }, status => 400) unless $addr =~ /\@/;
    my %body = (email => $addr);
    my $pw = _trim($c->param('password') // '');
    $body{password} = $pw if length $pw;
    my $tx = $UA->post($c->app->api_base . '/api/v1/admin/users/service-account'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'create failed' }), status => ($tx->res->code // 502));
}
sub admin_invite_quota_get ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    return $c->render(json => { error => 'user_email required' }, status => 400) unless $user =~ /\@/;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/invites/quota/' . Mojo::Util::url_escape($user)) // {}));
}
sub admin_invite_quota_set ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my ($mp, $md) = (_trim($c->param('max_pending') // ''), _trim($c->param('max_per_day') // ''));
    return $c->render(json => { error => 'user_email + two non-negative integers required' }, status => 400)
        unless $user =~ /\@/ && $mp =~ /^\d+$/ && $md =~ /^\d+$/;
    my $tx = $UA->put($c->app->api_base . '/api/v1/invites/quota/' . Mojo::Util::url_escape($user)
        => { Authorization => "Bearer $jwt" } => json => { max_pending => $mp + 0, max_per_day => $md + 0 });
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}
sub admin_user_sessions ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    return $c->render(json => { error => 'user_email required' }, status => 400) unless $user =~ /\@/;
    return $c->render(json => (_api_get($c, $jwt, Mojo::URL->new('/api/v1/auth/sessions')->query(user => $user)->to_string) // []));
}
sub admin_user_session_revoke ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my $jti  = _trim($c->param('jti') // '');
    return $c->render(json => { error => 'user_email and jti required' }, status => 400) unless $user =~ /\@/ && length $jti;
    my $url = Mojo::URL->new($c->app->api_base . '/api/v1/auth/sessions/' . Mojo::Util::url_escape($jti))->query(user => $user);
    my $tx = $UA->delete($url => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Roles & permissions (RBAC), site_admin -----
sub admin_roles_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    return $c->render(json => {
        roles       => (_api_get($c, $jwt, '/api/v1/admin/roles') // []),
        permissions => (_api_get($c, $jwt, '/api/v1/admin/permissions') // []),
    });
}
sub admin_role_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $name = _trim($c->param('name') // '');
    return $c->render(json => { error => 'a role name is required' }, status => 400) unless length $name;
    my %body = (name => $name);
    my $desc = _trim($c->param('description') // '');
    $body{description} = $desc if length $desc;
    my $tx = $UA->post($c->app->api_base . '/api/v1/admin/roles'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'add failed' }), status => ($tx->res->code // 502));
}
sub admin_role_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $name = _trim($c->param('name') // '');
    return $c->render(json => { error => 'role name required' }, status => 400) unless length $name;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/admin/roles/' . Mojo::Util::url_escape($name)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub _role_perm_tx ($c, $method) {
    my ($email, $jwt) = _admin_auth($c);
    return (undef) unless $email;
    my $role = _trim($c->param('role') // '');
    my $perm = _trim($c->param('permission') // '');
    return ('bad') unless length $role && length $perm;
    my $url = $c->app->api_base . '/api/v1/admin/roles/' . Mojo::Util::url_escape($role)
            . '/permissions/' . Mojo::Util::url_escape($perm);
    return ($UA->$method($url => { Authorization => "Bearer $jwt" }));
}
sub admin_role_grant_perm ($c) {
    my $tx = _role_perm_tx($c, 'post');
    return $c->render(json => { error => 'forbidden' }, status => 403) unless defined $tx;
    return $c->render(json => { error => 'role and permission required' }, status => 400) if $tx eq 'bad';
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub admin_role_revoke_perm ($c) {
    my $tx = _role_perm_tx($c, 'delete');
    return $c->render(json => { error => 'forbidden' }, status => 403) unless defined $tx;
    return $c->render(json => { error => 'role and permission required' }, status => 400) if $tx eq 'bad';
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
# Grant/revoke a role to a user (the api is keyed by user id, so resolve email).
sub _user_role_change ($c, $grant) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my $role = _trim($c->param('role') // '');
    return $c->render(json => { error => 'user_email and role are required' }, status => 400)
        unless $user =~ /\@/ && length $role;
    my $users = _api_get($c, $jwt, Mojo::URL->new('/api/v1/admin/users')->query(q => $user, limit => 20)->to_string) // [];
    my ($u) = grep { lc($_->{email} // '') eq lc($user) } @$users;
    return $c->render(json => { error => "no such user: $user" }, status => 404) unless $u;
    my $tx = $grant
        ? $UA->post($c->app->api_base . "/api/v1/admin/users/$u->{id}/roles"
            => { Authorization => "Bearer $jwt" } => json => { role => $role })
        : $UA->delete($c->app->api_base . "/api/v1/admin/users/$u->{id}/roles/" . Mojo::Util::url_escape($role)
            => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub admin_user_grant_role  ($c) { _user_role_change($c, 1) }
sub admin_user_revoke_role ($c) { _user_role_change($c, 0) }

# GET /admin/dovecot/status -- the dovecot mailbox-serving pool (active/passive
# roles + live health). First item of the Dovecot admin sub-tab.
sub admin_dovecot_status ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/dovecot/status') // { error => 'unavailable' }));
}

# GET /admin/domains/catch-alls -- every managed domain + its current catch-all
# destination. Feeds the domain search + the "view all domains" bulk picker.
sub admin_catchalls ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/catch-alls') // []));
}

# POST /admin/domains/catch-all/set {domain, destination} -- validate the
# destination is a real mailbox, then upsert the domain's catch-all.
sub admin_set_catchall ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _trim($c->param('domain') // '');
    my $dest   = _trim($c->param('destination') // '');
    return $c->render(json => { error => 'domain and destination are required' }, status => 400)
        unless $domain =~ /\./ && $dest =~ /\@/;
    return $c->render(json => { error => "$dest is not a real, active mailbox" }, status => 400)
        unless _user_exists($c, $jwt, $dest);
    my $tx = $UA->put($c->app->api_base . "/api/v1/domains/$domain/catch-all"
        => { Authorization => "Bearer $jwt" } => json => { destination => $dest });
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}

# POST /admin/domains/catch-all/clear {domain}
sub admin_clear_catchall ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _trim($c->param('domain') // '');
    return $c->render(json => { error => 'domain is required' }, status => 400) unless $domain =~ /\./;
    my $tx = $UA->delete($c->app->api_base . "/api/v1/domains/$domain/catch-all"
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { error => 'clear failed' }), status => ($tx->res->code // 502));
}

# POST /admin/domains/catch-all/bulk {domains (comma-separated), destination}
# -- set the SAME destination on several domains at once. Validates the
# destination once, then applies per-domain, reporting per-domain results.
sub admin_bulk_catchall ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $dest = _trim($c->param('destination') // '');
    my @domains = grep { /\./ } map { _trim($_) } split /,/, ($c->param('domains') // '');
    return $c->render(json => { error => 'select at least one domain' }, status => 400) unless @domains;
    return $c->render(json => { error => "$dest is not a real, active mailbox" }, status => 400)
        unless _user_exists($c, $jwt, $dest);
    my (@set, @failed);
    for my $d (@domains) {
        my $tx = $UA->put($c->app->api_base . "/api/v1/domains/$d/catch-all"
            => { Authorization => "Bearer $jwt" } => json => { destination => $dest });
        if (($tx->res->code // 0) == 200) { push @set, $d }
        else { push @failed, { domain => $d, error => (eval { $tx->res->json->{error} } // ('HTTP ' . ($tx->res->code // 0))) } }
    }
    return $c->render(json => { destination => $dest, set => \@set, failed => \@failed });
}

sub _trim ($s) { $s //= ''; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s; }

# ----- Send-as grants (mail aliases), site_admin -----
sub admin_aliases_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/mail-aliases') // []));
}
sub admin_alias_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src  = _trim($c->param('source_pattern') // '');
    my $dest = _trim($c->param('destination') // '');
    return $c->render(json => { error => 'source_pattern (user@domain or @domain) and destination are required' }, status => 400)
        unless $src =~ /\@/ && $dest =~ /\@/;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/mail-aliases'
        => { Authorization => "Bearer $jwt" }
        => json => { source_pattern => $src, destination => $dest, send_enabled => ($c->param('send_enabled') ? \1 : \0) });
    return $c->render(json => (eval { $tx->res->json } // { error => 'add failed' }), status => ($tx->res->code // 502));
}
sub admin_alias_set_send ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src = _trim($c->param('source_pattern') // '');
    return $c->render(json => { error => 'source_pattern required' }, status => 400) unless $src =~ /\@/;
    my $tx = $UA->patch($c->app->api_base . '/api/v1/domains/mail-aliases/' . Mojo::Util::url_escape($src)
        => { Authorization => "Bearer $jwt" } => json => { send_enabled => ($c->param('send_enabled') ? \1 : \0) });
    return $c->render(json => (eval { $tx->res->json } // {}), status => ($tx->res->code // 502));
}
sub admin_alias_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src = _trim($c->param('source_pattern') // '');
    return $c->render(json => { error => 'source_pattern required' }, status => 400) unless $src =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/mail-aliases/' . Mojo::Util::url_escape($src)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Site-wide recipient access (allow/block), site_admin -----
sub admin_racc_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/recipient-access') // []));
}
sub admin_racc_set ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    my $action    = (($c->param('action') // '') eq 'allow') ? 'OK' : 'REJECT';
    return $c->render(json => { error => 'a valid recipient is required' }, status => 400) unless $recipient =~ /\@/;
    my %body = (recipient => $recipient, action => $action);
    my $reason = _trim($c->param('reason') // '');
    $body{reason} = $reason if length $reason;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/recipient-access'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}
sub admin_racc_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'recipient required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/recipient-access/' . Mojo::Util::url_escape($recipient)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# Add a managed domain (POST /api/v1/domains). dns_managed=true also creates a
# PowerDNS zone; leave it off for a domain whose DNS lives elsewhere.
sub admin_domain_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = _trim($c->param('domain_name') // '');
    unless ($domain =~ /\./) { $c->flash(admin_err => 'Enter a valid domain name.'); return $c->redirect_to('/#admin:mail'); }
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains'
        => { Authorization => "Bearer $jwt" }
        => json => {
            domain_name  => $domain,
            mail_enabled => ($c->param('mail_enabled') ? \1 : \0),
            dns_managed  => ($c->param('dns_managed')  ? \1 : \0),
        });
    _admin_flash($c, $tx, "Domain $domain added.");
    return $c->redirect_to('/#admin:mail');
}

# Enable/disable a domain's mail acceptance (PATCH /api/v1/domains/:domain).
sub admin_domain_toggle ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = _trim($c->param('domain') // '');
    return $c->redirect_to('/#admin:mail') unless $domain =~ /\./;
    my $enable = (($c->param('action') // '') eq 'enable') ? \1 : \0;
    my $tx = $UA->patch($c->app->api_base . "/api/v1/domains/$domain"
        => { Authorization => "Bearer $jwt" } => json => { mail_enabled => $enable });
    _admin_flash($c, $tx, ($$enable ? "Mail enabled for $domain." : "Mail disabled for $domain."));
    return $c->redirect_to('/#admin:mail');
}

# Toggle the block-link footer per domain. mode: header (link only, no
# body append) | body | both. enabled on/off is the master switch.
sub admin_block_link ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain  = $c->param('domain') // '';
    my $enabled = $c->param('enabled') ? \1 : \0;
    my $mode    = $c->param('mode') // 'both';
    my $tx = $UA->put($c->app->api_base . "/api/v1/block-link/domains/$domain"
        => { Authorization => "Bearer $jwt" } => json => { enabled => $enabled, mode => $mode });
    _admin_flash($c, $tx, "Block-link settings for $domain saved.");
    return $c->redirect_to('/#admin:mail');
}

# Force-update DKIM for a domain = rotate a new selector, then activate it.
sub admin_dkim ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $auth = { Authorization => "Bearer $jwt" };
    my $rot = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dkim/rotate" => $auth => json => {});
    if (($rot->res->code // 0) != 201) {
        _admin_flash($c, $rot, '');
        return $c->redirect_to('/#admin:mail');
    }
    my $selector = eval { $rot->res->json->{selector} };
    my $act = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dkim/$selector/activate" => $auth => json => {});
    _admin_flash($c, $act, "DKIM rotated + activated for $domain (selector $selector).");
    return $c->redirect_to('/#admin:mail');
}

# Set SPF (apex TXT). NOTE: this REPLACES the domain's entire apex TXT
# record set (PowerDNS REPLACE semantics) -- documented in the UI.
sub admin_spf ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $value  = $c->param('value') // 'v=spf1 mx ~all';
    my $tx = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dns/records"
        => { Authorization => "Bearer $jwt" }
        => json => { name => $domain, type => 'TXT', content => [$value], ttl => 3600 });
    _admin_flash($c, $tx, "SPF set for $domain.");
    return $c->redirect_to('/#admin:mail');
}

# Set DMARC (_dmarc TXT). Builds the value from a policy + optional rua.
sub admin_dmarc ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $policy = $c->param('policy') // 'none';
    $policy = 'none' unless $policy =~ /^(none|quarantine|reject)$/;
    my $rua    = $c->param('rua') // '';
    my $value  = "v=DMARC1; p=$policy";
    $value .= "; rua=mailto:$rua" if $rua =~ /\S/;
    my $tx = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dns/records"
        => { Authorization => "Bearer $jwt" }
        => json => { name => "_dmarc.$domain", type => 'TXT', content => [$value], ttl => 3600 });
    _admin_flash($c, $tx, "DMARC set for $domain (p=$policy).");
    return $c->redirect_to('/#admin:mail');
}

1;
