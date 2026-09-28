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
    return (undef, undef) unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $result ? ($result->{email}, $jwt) : (undef, undef);
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

    return $c->render(
        template     => 'dashboard',
        email        => $email,
        summary      => $summary,
        sessions     => $sessions,
        drive_usage  => $drive_usage,
        roles        => $roles,
        is_admin     => ($is_admin ? 1 : 0),
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

1;
