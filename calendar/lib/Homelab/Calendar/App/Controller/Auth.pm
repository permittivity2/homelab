package Homelab::Calendar::App::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::URL;
use Mojo::Util qw(secure_compare url_escape);
use Mojo::JSON qw(encode_json);
use Homelab::Common::SSOClient qw(exchange_code);

# Sign-in through homelab-sso, the same flow as block-link, drive and search:
# /login starts it, /oauth/callback finishes it, /logout hands off to the
# single sign-out. Plus the one page of the app.

# GET / -- the calendar. Everything else the page needs comes from /api/*.
sub index ($c) {
    my $me = $c->require_login or return;
    my $model = $c->app->model;
    my $prefs = $model->prefs($me);
    my $zone  = $c->viewer_zone($prefs);
    $model->ensure_default_calendar($me, $zone);
    return $c->render(
        template => 'index',
        prefs    => $prefs,
        boot     => encode_json({
            me            => $me,
            prefs         => $prefs,
            account_zone  => $c->stash('calendar.account_zone'),
            default_zone  => $c->app->default_zone,
            public_base   => $c->app->public_base_url,
            csrf          => $c->csrf_token,
        }),
    );
}

# Where a sign-in may return to: a path on this site, or the front page.
sub _safe_next ($next) {
    return (defined $next && $next =~ m{\A/(?:[A-Za-z0-9_\-/.]*)(?:\?[A-Za-z0-9_\-=&%.]*)?\z} && $next !~ m{\A//}) ? $next : '/';
}

sub login ($c) {
    my $sso = $c->app->sso or return $c->render(template => 'notice', status => 503, heading => 'Sign-in is not set up',
        body => 'This calendar has no sign-in configured yet.');
    my $state = Homelab::Calendar::Model::_random_hex(16);
    $c->session(oauth_state => $state, next => _safe_next($c->param('next')));
    return $c->redirect_to(Mojo::URL->new($sso->{base_url} . '/oauth/authorize')->query(
        response_type => 'code',
        client_id     => $sso->{client_id},
        redirect_uri  => $sso->{redirect_uri},
        state         => $state,
        scope         => 'openid',
    ));
}

sub oauth_callback ($c) {
    my $sso = $c->app->sso or return $c->redirect_to('/');
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state') // '';
    my $next     = _safe_next($c->session('next'));
    delete @{ $c->session }{qw(oauth_state next)};

    return $c->render(template => 'notice', status => 400, heading => 'Sign-in failed',
        body => 'Sign-in expired or was not valid. Please try again.')
        unless $code && length $expected && secure_compare($state, $expected);

    my $r = exchange_code($code,
        sso_base      => $sso->{internal_base_url},
        client_id     => $sso->{client_id},
        client_secret => $sso->{client_secret},
        redirect_uri  => $sso->{redirect_uri},
    );
    return $c->render(template => 'notice', status => 502, heading => 'Sign-in failed',
        body => 'Sign-in could not be completed just now. Please try again.')
        unless $r->{success} && $r->{access_token};

    $c->session(token => $r->{access_token}, refresh_token => $r->{refresh_token});
    return $c->redirect_to($next);
}

# POST only: a GET sign-out is prefetchable and can be triggered cross-site.
sub logout ($c) {
    $c->session(expires => 1);
    my $sso = $c->app->sso or return $c->redirect_to('/');
    return $c->redirect_to($sso->{base_url} . '/logout');
}

1;
