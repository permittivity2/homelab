package Homelab::Calendar::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::Util qw(secure_compare);
use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Calendar::Model;
use Homelab::Calendar::Recurrence qw(validate_zone);

has 'pg';
has 'model';
has 'api_base';
has 'sso';
has 'public_base_url';
has 'default_zone';
has 'mailer';

# calendar.<domain>: calendars, events that repeat, sharing, an ICS feed.
# Same skeleton as homelab-block-link: sign-in through homelab-sso, the token
# held in this app's own session cookie and introspected against homelab-api
# on every request; the shared chrome from homelab-webtheme; one session
# secret for the whole pool. See README.md for the model.

sub startup ($self) {
    my $home = $ENV{HOMELAB_CALENDAR_HOME} // '/usr/share/homelab-calendar';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);
    # The vendored FullCalendar bundle and this app's own files, served by the
    # app itself: nothing is loaded from a CDN.
    $self->static->paths([("$home/public"), @{ $self->static->paths }]);

    my $config = load_config('HOMELAB_CALENDAR_CONFIG', '/etc/homelab/calendar/config.yml');
    $self->config($config);

    my $cal = $config->{calendar} // {};
    $self->public_base_url(($cal->{public_base_url} // 'https://calendar.test.mailmasker.org') =~ s{/\z}{}r);
    my $zone = $cal->{default_timezone} // 'America/Chicago';
    die "config: calendar.default_timezone '$zone' is not an IANA zone\n" unless validate_zone($zone);
    $self->default_zone($zone);

    my $theme = $config->{web_theme} // {};
    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'Calendar',
        signout_url => '/logout',
        user_email  => sub ($c) { $c->session_email },
        ($theme->{base_url} ? (theme_base => $theme->{base_url}) : ()),
    });

    if (my $sso = $config->{sso}) {
        my @missing = grep { !$sso->{$_} } qw(base_url client_id client_secret redirect_uri);
        die "config: sso: is present but missing @missing (see config/calendar.example.yml)\n" if @missing;
        $sso->{internal_base_url} //= $sso->{base_url};
        $self->sso($sso);
    }
    my $session = $config->{session} // {};
    die "config: session.secret is required once sso: is configured\n" if $self->sso && !$session->{secret};
    $self->secrets([$session->{secret} // Homelab::Calendar::Model::_random_hex(32)]);
    $self->sessions->cookie_name('homelab-calendar');
    $self->sessions->secure($session->{secure} // 1);
    $self->sessions->default_expiration(14 * 86400);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2519'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/calendar-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->model(Homelab::Calendar::Model->new(
        pg => $self->pg, default_zone => $self->default_zone,
        uid_domain => (Mojo::URL->new($self->public_base_url)->host // 'calendar.example'),
    ));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->mailer($config->{mailer}) if ref $config->{mailer} eq 'HASH' && $config->{mailer}{smtp_host};

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-calendar',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Calendar web app: events, repeating events, sharing, ICS feeds at calendar.<domain>',
            log => $self->log,
        );
    }

    # The address signed in here, or ''. One introspect per request; a token
    # that no longer introspects (expired, revoked by a sign-out anywhere, the
    # api unreachable) simply means signed out.
    $self->helper(session_email => sub ($c) {
        my $cached = $c->stash('calendar.session_email');
        return $cached if defined $cached;
        my $email = '';
        if ($self->sso and my $jwt = $c->session('token')) {
            my $result = eval { introspect($jwt, api_base => $self->api_base) };
            if ($result && $result->{email}) {
                $email = lc $result->{email};
                $c->stash('calendar.session_jwt' => $jwt);
                $c->stash('calendar.session_jti' => $result->{jti});
                # Phase 2 of the plan: the account carries its own zone.
                $c->stash('calendar.account_zone' => $result->{timezone}) if $result->{timezone};
            }
        }
        $c->stash('calendar.session_email' => $email);
        return $email;
    });

    # Pages: send a visitor to sign in; JSON routes: 401. Both return the
    # address or an empty string after rendering.
    $self->helper(require_login => sub ($c) {
        my $email = $c->session_email;
        return $email if length $email;
        if ($c->req->url->path =~ m{^/api/}) {
            $c->render(json => { error => 'Your sign-in has ended. Reload the page and sign in again.' }, status => 401);
            return '';
        }
        delete @{ $c->session }{qw(token refresh_token)};
        my $next = $c->req->url->path->to_string;
        $c->redirect_to('/login' . (length $next && $next ne '/' ? '?next=' . Mojo::Util::url_escape($next) : ''));
        return '';
    });

    # Every JSON write must carry the CSRF token the page was drawn with: the
    # session cookie is the credential, so the request has to prove it came
    # from this site's own page and not from another site.
    $self->helper(csrf_ok => sub ($c) {
        my $csrf = $c->req->headers->header('X-CSRF-Token') // '';
        return 1 if length $csrf && secure_compare($csrf, $c->csrf_token);
        $c->render(json => { error => 'This page is out of date. Reload it and try again.' }, status => 403);
        return 0;
    });

    # The zone a viewer sees times in: what the page asked for, else the
    # account's own (phase 2), else this app's saved preference, else the
    # default.
    $self->helper(viewer_zone => sub ($c, $prefs = undef) {
        my $q = $c->param('timeZone') // $c->param('timezone');
        return $q if defined $q && validate_zone($q);
        my $acct = $c->stash('calendar.account_zone');
        return $acct if defined $acct && validate_zone($acct);
        return $prefs->{timezone} if $prefs && defined $prefs->{timezone} && validate_zone($prefs->{timezone});
        return $self->default_zone;
    });

    my $r = $self->routes;
    my $tok = [token => qr/[0-9a-f]{64}/];

    # The app itself.
    $r->get('/')                  ->to('auth#index');
    $r->get('/login')             ->to('auth#login');
    $r->get('/oauth/callback')    ->to('auth#oauth_callback');
    $r->post('/logout')           ->to('auth#logout');

    # JSON, same-origin, signed in.
    $r->get('/api/calendars')                 ->to('api#calendars');
    $r->post('/api/calendars')                ->to('api#create_calendar');
    $r->patch('/api/calendars/:id' => [id => qr/\d+/])        ->to('api#update_calendar');
    $r->post('/api/calendars/:id/delete' => [id => qr/\d+/])  ->to('api#delete_calendar');
    $r->put('/api/calendars/:id/visible' => [id => qr/\d+/])  ->to('api#set_visible');
    $r->get('/api/calendars/:id/shares' => [id => qr/\d+/])   ->to('api#calendar_shares');
    $r->post('/api/calendars/:id/shares' => [id => qr/\d+/])  ->to('api#create_calendar_share');
    $r->get('/api/calendars/:id/export' => [id => qr/\d+/, format => ['ics']]) ->to('api#export');
    $r->get('/api/events')                    ->to('api#events');
    $r->post('/api/events')                   ->to('api#create_event');
    $r->get('/api/events/:id' => [id => qr/\d+/])             ->to('api#event');
    $r->patch('/api/events/:id' => [id => qr/\d+/])           ->to('api#update_event');
    $r->post('/api/events/:id/delete' => [id => qr/\d+/])     ->to('api#delete_event');
    $r->get('/api/events/:id/shares' => [id => qr/\d+/])      ->to('api#event_shares');
    $r->post('/api/events/:id/shares' => [id => qr/\d+/])     ->to('api#create_event_share');
    $r->post('/api/shares/:id/revoke' => [id => qr/\d+/])     ->to('api#revoke_share');
    $r->get('/api/prefs')                     ->to('api#prefs');
    $r->put('/api/prefs')                     ->to('api#save_prefs');

    # Links: a calendar or an event, to anyone holding the link (or to the
    # account it was shared with). The .ics forms are what a phone subscribes to.
    $r->get('/c/:token' => $tok => [format => ['ics']])         ->to('public#calendar_page');
    $r->get('/c/:token/events' => $tok)                         ->to('public#calendar_events');
    $r->get('/e/:token' => $tok => [format => ['ics']])         ->to('public#event_page');

    return;
}

1;
