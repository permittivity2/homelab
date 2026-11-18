package Homelab::Calendar::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::Util qw(secure_compare b64_decode);
use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Calendar::Model;
use Homelab::Calendar::AI;
use Homelab::Calendar::Runner;
use Homelab::Calendar::Recurrence qw(validate_zone);

has 'pg';
has 'model';
has 'api_base';
has 'sso';
has 'public_base_url';
has 'default_zone';
has 'mailer';
has 'ai';

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
        app_name     => 'Calendar',
        signout_url  => '/logout',
        settings_url => '/settings',     # the dropdown's Settings line (#77; webtheme >= 0.1.3)
        user_email   => sub ($c) { $c->session_email },
        ($theme->{base_url} ? (theme_base => $theme->{base_url}) : ()),
    });

    # The AI proposal (#74 phase 4) goes through the fleet's AI service
    # (homelab-ai, #76); this app never holds an Anthropic key. Unconfigured =
    # the button is not offered and the plain parse is all there is.
    my $aic = $config->{ai} // {};
    $self->ai(Homelab::Calendar::AI->new(
        service_url => ($aic->{service_url} // ''), service_token => ($aic->{service_token} // ''),
        model => ($aic->{model} // 'claude-haiku-5-5'), max_tokens => ($aic->{max_tokens} // 1024), log => $self->log,
        research_model => ($aic->{research_model} // 'claude-sonnet-5-5'),
        research_max_uses => ($aic->{research_max_uses} // 5),
    ));

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

    # The background runner (#79 reminders, #80 proposals at arrival): a timer
    # in every hypnotoad worker, sharing one queue in Postgres (Runner.pm).
    # runner.enabled: 0 in the config, or HOMELAB_CALENDAR_RUNNER=0 (the tests),
    # keeps it off. No mailer = reminders queue up and wait for one.
    my $run = $config->{runner} // {};
    unless (($ENV{HOMELAB_CALENDAR_RUNNER} // '') eq '0' || (defined $run->{enabled} && !$run->{enabled})) {
        $self->log->warn('calendar: no mailer: configured -- reminders will queue but cannot be sent') unless $self->mailer;
        Homelab::Calendar::Runner->new(
            model => $self->model, ai => $self->ai, mailer => $self->mailer, log => $self->log,
            public_base_url => $self->public_base_url, default_zone => $self->default_zone,
            interval => ($run->{interval} // 30), propose_max => ($run->{ai_in_flight} // 2),
            holidays => (ref $config->{holidays} eq 'HASH' ? $config->{holidays} : {}),
        )->start;
    }

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

    # The gateway-fronted routes (/internal/v1/calendar/*, reached through
    # homelab-api's /api/v1/calendar/* by myaccount): a Bearer JWT, introspected.
    # Same shape and name as homelab-invite's and block-link's helper.
    $self->helper(authenticated_email_any => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) { $c->render(json => { error => 'not logged in' }, status => 401); return undef }
        my $result = introspect($jwt, api_base => $self->api_base);
        unless ($result && $result->{email}) { $c->render(json => { error => 'not logged in' }, status => 401); return undef }
        $c->stash(current_jti => $result->{jti});
        $c->stash(current_roles => $result->{roles} // []);
        return lc $result->{email};
    });

    # The same, for what only a site administrator may do (#80's entitlements).
    $self->helper(authenticated_site_admin => sub ($c) {
        my $email = $c->authenticated_email_any or return undef;
        unless (grep { $_ eq 'site_admin' } @{ $c->stash('current_roles') // [] }) {
            $c->render(json => { error => 'Only a site administrator can do this.' }, status => 403);
            return undef;
        }
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
        # A Bearer caller (homelab-cli through the gateway, #82) has no page
        # and no CSRF token; its token was introspected already.
        return 1 if $c->stash('calendar.bearer');
        my $csrf = $c->req->headers->header('X-CSRF-Token') // '';
        return 1 if length $csrf && secure_compare($csrf, $c->csrf_token);
        $c->render(json => { error => 'This page is out of date. Reload it and try again.' }, status => 403);
        return 0;
    });

    # CalDAV (#84): HTTP Basic with the account's address and an APP PASSWORD
    # (Settings, Devices; Model::verify_app_password). Never the SSO password
    # and never a Bearer token: a phone keeps this credential for years, so
    # it is one that opens only the calendar and can be revoked alone. On
    # success the request acts as that account for every helper that reads
    # the stash; otherwise a 401 with the challenge, and 0.
    $self->helper(dav_login => sub ($c) {
        my $auth = $c->req->headers->authorization // '';
        if ($auth =~ /\ABasic\s+([A-Za-z0-9+\/=]+)\s*\z/i) {
            my ($user, $secret) = split /:/, (b64_decode($1) // ''), 2;
            if (defined $user && defined $secret && length $user) {
                if (my $row = $self->model->verify_app_password($user, $secret)) {
                    $c->stash('calendar.session_email' => lc $row->{user_email});
                    $c->stash('calendar.bearer' => 1);
                    $c->stash('calendar.dav_password_id' => $row->{id});
                    $self->model->touch_app_password($row->{id}, $c->req->headers->user_agent);
                    return 1;
                }
                $self->log->info('caldav: sign-in refused for ' . lc($user) . ' from ' . ($c->tx->remote_address // '?'));
            }
        }
        my $host = Mojo::URL->new($self->public_base_url)->host // 'calendar';
        $c->res->headers->www_authenticate(qq{Basic realm="$host: your address and an app password from Settings, Devices", charset="UTF-8"});
        $c->res->headers->header(DAV => '1, 3, calendar-access');
        $c->render(text => "Sign in with your address and an app password made in the calendar's Settings under Devices.\n", status => 401);
        return 0;
    });

    # The zone a viewer sees times in: what the page asked for, else the
    # account's own (phase 2), else this app's saved preference, else the
    # default.
    # Since 0.4.0 (#88) the order is: what the request asks for (the page sends
    # the zone it shows, Local or fixed), the calendar's own fixed choice, the
    # device's zone the browser last reported, the account's zone from My
    # Account (a fallback for mail, not an override), the default.
    $self->helper(viewer_zone => sub ($c, $prefs = undef) {
        my $q = $c->param('timeZone') // $c->param('timezone');
        return $q if defined $q && validate_zone($q);
        return $prefs->{timezone} if $prefs && defined $prefs->{timezone} && validate_zone($prefs->{timezone});
        return $prefs->{device_zone} if $prefs && defined $prefs->{device_zone} && validate_zone($prefs->{device_zone});
        my $acct = $c->stash('calendar.account_zone');
        return $acct if defined $acct && validate_zone($acct);
        return $self->default_zone;
    });

    my $r = $self->routes;
    my $tok = [token => qr/[0-9a-f]{64}/];

    # The app itself.
    $r->get('/')                  ->to('auth#index');
    $r->get('/settings')          ->to('auth#settings');
    $r->get('/m/:token' => $tok)  ->to('auth#from_mail');      # the link in an email (phase 3)
    $r->get('/login')             ->to('auth#login');
    $r->get('/oauth/callback')    ->to('auth#oauth_callback');
    $r->post('/logout')           ->to('auth#logout');

    # Per-account switches: the session form for this app's own pages, and
    # the Bearer form homelab-api's gateway fronts for myaccount.
    $r->get('/api/account')       ->to('api#account');
    $r->put('/api/account')       ->to('api#save_account');
    $r->get('/api/mail-links/:token' => $tok)          ->to('api#mail_link');
    $r->post('/api/mail-links/:token/propose' => $tok) ->to('api#propose');
    $r->post('/api/mail-links/:token/research' => $tok)->to('api#research');     # "Find out more" (#78)
    $r->get('/internal/v1/calendar/account')  ->to('api#internal_account_show');
    $r->put('/internal/v1/calendar/account')  ->to('api#internal_account_set');
    # #80: the Suggestions list (proposals made as the email arrived), and the
    # entitlement an administrator grants (a relaxed placeholder: the address
    # has dots).
    $r->get('/api/suggestions')                          ->to('api#suggestions');
    $r->post('/api/suggestions/:token/save' => $tok)     ->to('api#save_suggestion');
    $r->post('/api/suggestions/:token/dismiss' => $tok)  ->to('api#dismiss_suggestion');
    $r->put('/internal/v1/calendar/admin/accounts/#email/entitlements')->to('api#admin_entitlements');
    # homelab-cli through the api gateway (#82): Bearer, no CSRF. The .ics
    # routes keep format detection off so the extension is a literal, as the
    # public /c and /e feeds do.
    $r->get('/internal/v1/calendar/calendars')                   ->to('api#internal_calendars');
    $r->get('/internal/v1/calendar/events')                      ->to('api#internal_events_list');
    $r->post('/internal/v1/calendar/events')                     ->to('api#internal_event_create');
    $r->get('/internal/v1/calendar/events.ics' => [format => 0]) ->to('api#internal_events_ics');
    $r->get('/internal/v1/calendar/export.ics' => [format => 0]) ->to('api#internal_export_ics');
    $r->post('/internal/v1/calendar/import')                     ->to('api#internal_import');
    # 0.2.0 (#83): what the CLI's other verbs need, each the session route's
    # own handler behind a Bearer check.
    $r->get('/internal/v1/calendar/events/:id' => [id => qr/\d+/])           ->to('api#internal_event_show');
    $r->patch('/internal/v1/calendar/events/:id' => [id => qr/\d+/])         ->to('api#internal_event_update');
    $r->post('/internal/v1/calendar/events/:id/delete' => [id => qr/\d+/])   ->to('api#internal_event_delete');
    $r->post('/internal/v1/calendar/events/:id/restore' => [id => qr/\d+/])  ->to('api#internal_event_restore');
    $r->get('/internal/v1/calendar/events/:id/shares' => [id => qr/\d+/])    ->to('api#internal_event_shares');
    $r->post('/internal/v1/calendar/events/:id/shares' => [id => qr/\d+/])   ->to('api#internal_event_share_create');
    $r->get('/internal/v1/calendar/trash')                                   ->to('api#internal_trash');
    $r->get('/internal/v1/calendar/search')                                  ->to('api#internal_search');
    $r->post('/internal/v1/calendar/zone-for-place')                         ->to('api#internal_zone_for_place');
    $r->post('/internal/v1/calendar/calendars')                              ->to('api#internal_calendar_create');
    $r->get('/internal/v1/calendar/calendars/:id/shares' => [id => qr/\d+/]) ->to('api#internal_calendar_shares');
    $r->post('/internal/v1/calendar/calendars/:id/shares' => [id => qr/\d+/])->to('api#internal_calendar_share_create');
    $r->post('/internal/v1/calendar/shares/:id/revoke' => [id => qr/\d+/])   ->to('api#internal_share_revoke');
    $r->get('/internal/v1/calendar/suggestions')                             ->to('api#internal_suggestions');
    $r->post('/internal/v1/calendar/suggestions/:token/save' => $tok)        ->to('api#internal_suggestion_save');
    $r->post('/internal/v1/calendar/suggestions/:token/dismiss' => $tok)     ->to('api#internal_suggestion_dismiss');
    $r->get('/internal/v1/calendar/prefs')                                   ->to('api#internal_prefs');
    $r->put('/internal/v1/calendar/prefs')                                   ->to('api#internal_prefs_save');
    # Prometheus (0.2.0): the fleet's scraper reads this on the service port.
    $r->get('/metrics')                                                      ->to('api#metrics');

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
    # 0.2.0 (#83): the trash, search, a typed draft, a duplicate check, the
    # sidebar's order. (/api/events/similar is safe beside /api/events/:id:
    # the id placeholder takes digits only.)
    $r->get('/api/events/similar')            ->to('api#similar');
    $r->get('/api/trash')                     ->to('api#trash');
    $r->post('/api/events/:id/restore' => [id => qr/\d+/])    ->to('api#restore_event');
    $r->get('/api/search')                    ->to('api#search');
    $r->post('/api/zone-for-place')           ->to('api#zone_for_place');     # #89: the zone of an address, by the AI
    $r->post('/api/quick-add')                ->to('api#quick_add');
    $r->put('/api/calendars/:id/position' => [id => qr/\d+/]) ->to('api#move_calendar');
    $r->get('/api/events/:id' => [id => qr/\d+/])             ->to('api#event');
    $r->patch('/api/events/:id' => [id => qr/\d+/])           ->to('api#update_event');
    $r->post('/api/events/:id/delete' => [id => qr/\d+/])     ->to('api#delete_event');
    $r->get('/api/events/:id/shares' => [id => qr/\d+/])      ->to('api#event_shares');
    $r->post('/api/events/:id/shares' => [id => qr/\d+/])     ->to('api#create_event_share');
    $r->post('/api/shares/:id/revoke' => [id => qr/\d+/])     ->to('api#revoke_share');
    $r->get('/api/prefs')                     ->to('api#prefs');
    $r->put('/api/prefs')                     ->to('api#save_prefs');
    # Invitations (#85): the people asked to an event, an answer from a
    # signed-in attendee, and free/busy for accounts here.
    $r->get('/api/events/:id/attendees' => [id => qr/\d+/])                              ->to('api#attendees');
    $r->post('/api/events/:id/attendees' => [id => qr/\d+/])                             ->to('api#invite');
    $r->post('/api/events/:id/attendees/:aid/remove' => [id => qr/\d+/, aid => qr/\d+/]) ->to('api#uninvite');
    $r->post('/api/events/:id/attendees/:aid/resend' => [id => qr/\d+/, aid => qr/\d+/]) ->to('api#reinvite');
    $r->post('/api/events/:id/rsvp' => [id => qr/\d+/])                                  ->to('api#rsvp');
    $r->get('/api/freebusy')                                                             ->to('api#freebusy');
    $r->get('/internal/v1/calendar/events/:id/attendees' => [id => qr/\d+/])                              ->to('api#internal_attendees');
    $r->post('/internal/v1/calendar/events/:id/attendees' => [id => qr/\d+/])                             ->to('api#internal_invite');
    $r->post('/internal/v1/calendar/events/:id/attendees/:aid/remove' => [id => qr/\d+/, aid => qr/\d+/]) ->to('api#internal_uninvite');
    $r->post('/internal/v1/calendar/events/:id/attendees/:aid/resend' => [id => qr/\d+/, aid => qr/\d+/]) ->to('api#internal_reinvite');
    $r->post('/internal/v1/calendar/events/:id/rsvp' => [id => qr/\d+/])                                  ->to('api#internal_rsvp');
    $r->get('/internal/v1/calendar/freebusy')                                                             ->to('api#internal_freebusy');

    # Links: a calendar or an event, to anyone holding the link (or to the
    # account it was shared with). The .ics forms are what a phone subscribes
    # to. Two routes each, with format detection off: a restricted
    # `format => ['ics']` made the extension REQUIRED and the plain page 404
    # (found live 2026-11-14).
    $r->get('/c/<token>.ics' => $tok => [format => 0])          ->to('public#calendar_page', feed => 1);
    $r->get('/c/:token' => $tok => [format => 0])               ->to('public#calendar_page', feed => 0);
    $r->get('/c/:token/events' => $tok => [format => 0])        ->to('public#calendar_events');
    $r->get('/e/<token>.ics' => $tok => [format => 0])          ->to('public#event_page', feed => 1);
    $r->get('/e/:token' => $tok => [format => 0])               ->to('public#event_page', feed => 0);
    # The invitation (#85): what the links in the mail open. No sign-in; the
    # token is the capability. ?answer= records an answer in one tap.
    $r->get('/i/<token>.ics' => $tok => [format => 0])          ->to('public#rsvp_page', feed => 1);
    $r->any([qw(GET POST)] => '/i/:token' => $tok => [format => 0]) ->to('public#rsvp_page', feed => 0);

    # CalDAV (#84; Controller::Dav): the discovery path, the root a phone asks
    # of the site itself, and the tree under /dav/, every method of it. The
    # sign-in is an app password over HTTP Basic (dav_login); OPTIONS answers
    # before any sign-in, as the protocol has it. Format detection stays off:
    # addresses have dots and objects end in .ics.
    $r->any('/.well-known/caldav' => [format => 0])->to('dav#well_known');
    $r->any([qw(PROPFIND OPTIONS)] => '/')->to('dav#root_alias');
    my $dav = $r->under('/dav' => sub ($c) { return 1 if uc $c->req->method eq 'OPTIONS'; return $c->dav_login });
    $dav->any('/'                                       => [format => 0])->to('dav#root');
    $dav->any('/principals'                             => [format => 0])->to('dav#principals');
    $dav->any('/principals/#email'                      => [format => 0])->to('dav#principal');
    $dav->any('/calendars'                              => [format => 0])->to('dav#homes');
    $dav->any('/calendars/#email'                       => [format => 0])->to('dav#home');
    $dav->any('/calendars/#email/#cal'                  => [format => 0])->to('dav#calendar');
    $dav->any('/calendars/#email/#cal/#obj'             => [format => 0])->to('dav#object');
    # The app passwords themselves: the Settings page's Devices panel, and
    # homelab-cli through the gateway.
    $r->get('/api/devices')                                   ->to('api#devices');
    $r->post('/api/devices')                                  ->to('api#device_create');
    $r->post('/api/devices/:id/revoke' => [id => qr/\d+/])    ->to('api#device_revoke');
    $r->get('/internal/v1/calendar/devices')                                ->to('api#internal_devices');
    $r->post('/internal/v1/calendar/devices')                               ->to('api#internal_device_create');
    $r->post('/internal/v1/calendar/devices/:id/revoke' => [id => qr/\d+/]) ->to('api#internal_device_revoke');
    # Holidays (#92): the built-in US holidays calendar, on or off for this account.
    $r->get('/api/holidays')                                  ->to('api#holidays');
    $r->put('/api/holidays')                                  ->to('api#set_holidays');
    $r->get('/internal/v1/calendar/holidays')                 ->to('api#internal_holidays');
    $r->put('/internal/v1/calendar/holidays')                 ->to('api#internal_holidays_set');

    return;
}

1;
