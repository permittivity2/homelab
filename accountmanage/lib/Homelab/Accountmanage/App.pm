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
    # Administration actions (site_admin; each re-checks + proxies to the
    # owning service with the admin's token).
    $r->post('/admin/users/:id/active')->to('account#admin_set_active');
    $r->post('/admin/drive-quota')     ->to('account#admin_drive_quota');
    $r->post('/admin/block-link')      ->to('account#admin_block_link');
    $r->post('/admin/dkim')            ->to('account#admin_dkim');
    $r->post('/admin/spf')             ->to('account#admin_spf');
    $r->post('/admin/dmarc')           ->to('account#admin_dmarc');

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
    # Drive usage via the api gateway (/api/v1/drive/* -> homelab-drive);
    # undef if drive is unavailable -> the panel shows "unavailable".
    my $drive_usage = _api_get($c, $jwt, '/api/v1/drive/usage');

    my $roles    = $summary->{roles} // [];
    my $is_admin = grep { $_ eq 'site_admin' } @$roles;

    # Admin pane data (only for site_admins): the user list (to
    # suspend/re-enable + adjust quota) and the managed domains (for
    # block-link toggle + DKIM/SPF/DMARC). Best-effort -- a panel degrades
    # to empty if its backend is unavailable.
    my ($admin_users, $admin_domains) = ([], []);
    if ($is_admin) {
        $admin_users   = _api_get($c, $jwt, '/api/v1/admin/users') // [];
        $admin_domains = _api_get($c, $jwt, '/api/v1/domains') // [];
    }

    return $c->render(
        template     => 'dashboard',
        email        => $email,
        summary      => $summary,
        sessions     => $sessions,
        drive_usage  => $drive_usage,
        roles        => $roles,
        is_admin     => ($is_admin ? 1 : 0),
        admin_users  => $admin_users,
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
    return $c->redirect_to('/#admin');
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
    return $c->redirect_to('/#admin');
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
    return $c->redirect_to('/#admin');
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
        return $c->redirect_to('/#admin');
    }
    my $selector = eval { $rot->res->json->{selector} };
    my $act = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dkim/$selector/activate" => $auth => json => {});
    _admin_flash($c, $act, "DKIM rotated + activated for $domain (selector $selector).");
    return $c->redirect_to('/#admin');
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
    return $c->redirect_to('/#admin');
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
    return $c->redirect_to('/#admin');
}

1;
