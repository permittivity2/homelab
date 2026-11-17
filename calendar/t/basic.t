use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use Mojo::URL;

# The app's shape without a database: start-up checks, sign-in through
# homelab-sso, what is refused before anything is looked up (a dead
# sign-in, a missing CSRF token), the static bundle. homelab-sso and
# homelab-api are pointed at 127.0.0.1:9, where nothing listens, so every
# step up to the server-to-server exchange is real. Data paths are proven
# against the live pool (README.md).

use lib 'lib';

my $dir = tempdir;
sub config ($extra) {
    my $cfg = $dir->child('config-' . int(rand 1e9) . '.yml');
    $cfg->spew(<<"YAML" . $extra);
homelab_api:
  base_url: "http://127.0.0.1:9"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
calendar:
  public_base_url: "https://calendar.example.test/"
  default_timezone: America/Chicago
server:
  listen: "http://127.0.0.1:0"
YAML
    return $cfg->to_string;
}

$ENV{HOMELAB_CALENDAR_HOME} = '.';
$ENV{HOMELAB_WEBTHEME_HOME} = '../webtheme';
$ENV{HOMELAB_CALENDAR_RUNNER} = '0';     # no background timer against the absent database

my $SSO = <<'YAML';
sso:
  base_url: "https://login.example.test"
  internal_base_url: "http://127.0.0.1:9"
  client_id: "calendar"
  client_secret: "test-client-secret"
  redirect_uri: "https://calendar.example.test/oauth/callback"
session:
  secret: "test-session-secret"
  secure: 0
YAML

{
    local $ENV{HOMELAB_CALENDAR_CONFIG} = config($SSO);
    my $t = eval { Test::Mojo->new('Homelab::Calendar::App') };
    plan skip_all => "could not start app: $@" unless $t;
}

# --- refusing to start on a bad config ---
{
    local $ENV{HOMELAB_CALENDAR_CONFIG} = config("sso:\n  base_url: \"https://login.example.test\"\n  client_id: x\nsession:\n  secret: s\n");
    ok !eval { Test::Mojo->new('Homelab::Calendar::App') }, 'sso: without client_secret and redirect_uri: refuses to start';
    like $@, qr/missing client_secret redirect_uri/, '... and names what is missing';
}
{
    local $ENV{HOMELAB_CALENDAR_CONFIG} = config(($SSO =~ s/^session:.*\z//msr));
    ok !eval { Test::Mojo->new('Homelab::Calendar::App') }, 'sso: without a session secret: refuses to start';
    like $@, qr/session\.secret is required/, '... and says so';
}
{
    local $ENV{HOMELAB_CALENDAR_CONFIG} = config($SSO =~ s/America\/Chicago/Mars\/Olympus/r);
    local $ENV{HOMELAB_CALENDAR_CONFIG} = do { my $c = $dir->child('bad-zone.yml'); $c->spew(Mojo::File->new(config($SSO))->slurp =~ s/America\/Chicago/Mars\/Olympus/r); $c->to_string };
    ok !eval { Test::Mojo->new('Homelab::Calendar::App') }, 'a default_timezone that is not a zone: refuses to start';
    like $@, qr/not an IANA zone/, '... and says so';
}

$ENV{HOMELAB_CALENDAR_CONFIG} = config($SSO);
my $t = Test::Mojo->new('Homelab::Calendar::App');
my $app = $t->app;
ok $app->sso, 'sso: block loaded';
is $app->public_base_url, 'https://calendar.example.test', 'public_base_url without its trailing slash';
is $app->model->uid_domain, 'calendar.example.test', 'new UIDs end in the public host';
is $app->default_zone, 'America/Chicago', 'the default zone';
is $app->sessions->cookie_name, 'homelab-calendar', 'its own cookie name';

# --- the page needs a sign-in ---
$t->get_ok('/')->status_is(302)->header_is(Location => '/login', 'signed out: straight to sign-in');
$t->get_ok('/settings')->status_is(302)->header_is(Location => '/login?next=%2Fsettings', 'the settings page too, and it comes back here');
$t->get_ok('/m/' . ('d' x 64))->status_is(302, 'a link from an email: sign in first (nothing is looked up)');
$t->get_ok('/api/account')->status_is(401, 'the account switches: 401 signed out');
$t->get_ok('/api/mail-links/' . ('d' x 64))->status_is(401, 'a mail link\'s JSON: 401 signed out');
$t->get_ok('/internal/v1/calendar/account')->status_is(401)->json_is('/error', 'not logged in', 'the gateway form needs a Bearer token');
$t->put_ok('/internal/v1/calendar/account' => { Authorization => 'Bearer not-live' } => json => {})->status_is(401, '... and one the api confirms');
$t->get_ok('/api/calendars')->status_is(401)->json_like('/error', qr/sign-in/, 'the JSON routes answer 401 signed out');
$t->get_ok('/api/events?start=2026-11-01T00:00:00&end=2026-12-13T00:00:00&timeZone=America/Chicago')->status_is(401, '... events too');
$t->get_ok('/health')->status_is(503, '/health without a database says unhealthy');

# --- /login sends the browser to homelab-sso ---
$t->get_ok('/login?next=/')->status_is(302);
my $loc = Mojo::URL->new($t->tx->res->headers->location);
is $loc->host, 'login.example.test', 'to the public SSO name';
is $loc->path, '/oauth/authorize', '... its authorize endpoint';
is $loc->query->param('client_id'), 'calendar', '... as client calendar';
is $loc->query->param('redirect_uri'), 'https://calendar.example.test/oauth/callback', '... back to the registered callback';
my $state = $loc->query->param('state');
like $state, qr/\A[0-9a-f]{32}\z/, '... with a random state';
$t->get_ok('/login');
isnt(Mojo::URL->new($t->tx->res->headers->location)->query->param('state'), $state, 'every sign-in gets a new state');
$state = Mojo::URL->new($t->tx->res->headers->location)->query->param('state');

# --- the callback checks the state first ---
$t->get_ok('/oauth/callback?code=abc&state=' . ('0' x 32))->status_is(400)->content_like(qr/Sign-in failed/, 'a state that does not match: refused');
$t->get_ok("/oauth/callback?code=abc&state=$state")->status_is(400, '... and a refused state cannot be replayed');
$t->get_ok('/login'); $state = Mojo::URL->new($t->tx->res->headers->location)->query->param('state');
$t->get_ok("/oauth/callback?code=abc&state=$state")->status_is(502)->content_like(qr/could not be completed/, 'right state, SSO unreachable: a clear failure');
my $fresh = Test::Mojo->new($app);
$fresh->get_ok("/oauth/callback?code=abc&state=$state")->status_is(400, 'a callback with no session of its own is refused');

# --- where a sign-in may come back to ---
my $safe = \&Homelab::Calendar::App::Controller::Auth::_safe_next;
is $safe->('/'), '/', 'the front page';
is $safe->('/c/' . ('a' x 64)), '/c/' . ('a' x 64), 'a link page on this site';
is $safe->('https://evil.example/'), '/', 'another site: the front page';
is $safe->('//evil.example/x'), '/', 'a protocol-relative URL: the front page';
is $safe->("/x\nSet-Cookie: y"), '/', 'a header injection: the front page';
is $safe->(undef), '/', 'nothing: the front page';

# --- a dead sign-in is signed out; writes need the page's CSRF token ---
$app->routes->get('/t/set-token' => sub ($c) { $c->session(token => 'not-a-live-token'); $c->render(text => 'set') });
$app->routes->get('/t/who' => sub ($c) { $c->render(text => 'who=' . $c->session_email) });
$app->routes->get('/t/csrf' => sub ($c) { $c->render(text => $c->csrf_token) });
$t->get_ok('/t/set-token')->content_is('set');
$t->get_ok('/t/who')->content_is('who=', 'a token the api cannot confirm means signed out');
my $csrf = $t->get_ok('/t/csrf')->tx->res->body;
$t->post_ok('/api/events' => json => { title => 'x' })->status_is(401, 'a write signed out: 401 (sign-in is checked first)');
$t->get_ok('/')->status_is(302, 'the dead token is dropped and the page goes to sign-in');
$t->post_ok('/api/shares/1/revoke' => { 'X-CSRF-Token' => 'f' x 40 } => json => {})->status_is(401, 'a wrong CSRF token with no sign-in: still 401 first');
$t->post_ok('/logout')->status_is(302)->header_is(Location => 'https://login.example.test/logout', 'sign-out hands off to homelab-sso');
$t->get_ok('/logout')->status_is(404, 'sign-out is POST only');

# --- suggestions and the admin route (#79/#80): signed out, Bearer-less, wrong shapes ---
$t->get_ok('/api/suggestions')->status_is(401, 'the Suggestions list needs a sign-in');
$t->post_ok('/api/suggestions/' . ('a' x 64) . '/save')->status_is(401, '... so does saving one');
$t->post_ok('/api/suggestions/short/save')->status_is(404, 'a token of the wrong shape is not even routed');
$t->put_ok('/internal/v1/calendar/admin/accounts/someone@example.test/entitlements' => json => { research_at_arrival_allowed => 1 })
  ->status_is(401, 'the entitlement route wants a Bearer token (an address with dots routes: relaxed placeholder)');

# --- the range words homelab-cli may send (#82, more in 0.2.0) ---
{
    require DateTime;
    my $today = DateTime->new(year => 2026, month => 11, day => 14, time_zone => 'America/Chicago');   # a Saturday
    my $w = sub ($s, $base = undef) { Homelab::Calendar::App::Controller::Api::_read_when($s, $today, 'America/Chicago', $base) };
    is $w->('today')->ymd, '2026-11-14', 'today';
    is $w->('Tomorrow')->ymd, '2026-11-15', 'tomorrow, any case';
    is $w->('yesterday')->ymd, '2026-11-13', 'yesterday';
    is $w->('saturday')->ymd, '2026-11-14', 'a weekday name: today when today is that day';
    is $w->('mon')->ymd, '2026-11-16', '... else the next one';
    is $w->('+7d')->ymd, '2026-11-21', '+7d from today';
    is $w->('+2w', $today->clone->add(days => 1))->ymd, '2026-11-29', '+2w counted from the other end when given';
    is $w->('+1m')->ymd, '2026-12-14', '+1m';
    is $w->('2026-12-01T09:30')->strftime('%H:%M'), '09:30', 'a wall clock';
    is $w->('nonsense'), undef, 'anything else is undef';
    ok Homelab::Calendar::App::Controller::Api::_names_a_day('friday'), 'a weekday names a whole day';
    ok !Homelab::Calendar::App::Controller::Api::_names_a_day('+7d'), '... a relative count does not';
}

# --- homelab-cli's routes through the gateway (#82): every one wants a Bearer token ---
$t->get_ok('/internal/v1/calendar/calendars')->status_is(401, 'the calendars list wants a Bearer token');
$t->get_ok('/internal/v1/calendar/events?from=today')->status_is(401, '... so does the events list');
$t->post_ok('/internal/v1/calendar/events' => json => { title => 'x', start => '2026-11-20T14:30:00' })->status_is(401, '... and adding one');
$t->get_ok('/internal/v1/calendar/events.ics?from=today')->status_is(401, '... and the range as iCalendar (the .ics route is routed)');
$t->get_ok('/internal/v1/calendar/export.ics')->status_is(401, '... and the export');
$t->post_ok('/internal/v1/calendar/import' => { 'Content-Type' => 'text/calendar' } => "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
  ->status_is(401, '... and the import');
# 0.2.0: the CLI's other verbs, the page's new routes, Prometheus.
$t->get_ok('/internal/v1/calendar/events/7')->status_is(401, 'one event wants a Bearer token');
$t->get_ok('/internal/v1/calendar/trash')->status_is(401, '... so does the trash');
$t->get_ok('/internal/v1/calendar/search?q=den')->status_is(401, '... and search');
$t->get_ok('/api/trash')->status_is(401, 'the page\'s trash needs a sign-in');
$t->get_ok('/api/search?q=den')->status_is(401, '... and its search');
$t->get_ok('/api/events/similar?title=x&start=2026-11-20T09:00:00')->status_is(401, '... and the duplicate check routes beside /api/events/:id');
$t->get_ok('/metrics')->status_is(200, '/metrics answers without a sign-in')
  ->content_type_like(qr{text/plain}, '... as Prometheus text')
  ->content_like(qr/^homelab_calendar_up 0$/m, '... saying the database did not answer here');

# --- invitations (#85): every route wants a sign-in or a Bearer token; the RSVP link is routed ---
$t->get_ok('/api/events/7/attendees')->status_is(401, 'the attendee list needs a sign-in');
$t->post_ok('/api/events/7/attendees' => json => { emails => ['x@example.com'] })->status_is(401, '... so does inviting');
$t->post_ok('/api/events/7/attendees/3/remove')->status_is(401, '... and taking someone off');
$t->post_ok('/api/events/7/rsvp' => json => { answer => 'yes' })->status_is(401, '... and answering');
$t->get_ok('/api/freebusy?emails=x@example.com&start=2026-11-20T09:00:00')->status_is(401, '... and free/busy');
$t->get_ok('/internal/v1/calendar/events/7/attendees')->status_is(401, 'the Bearer twins want a token');
$t->post_ok('/internal/v1/calendar/events/7/attendees' => json => { emails => ['x@example.com'] })->status_is(401, '... inviting');
$t->post_ok('/internal/v1/calendar/events/7/rsvp' => json => { answer => 'yes' })->status_is(401, '... answering');
$t->get_ok('/internal/v1/calendar/freebusy?emails=x@example.com&start=2026-11-20T09:00:00')->status_is(401, '... free/busy');
$t->get_ok('/i/short')->status_is(404, 'an RSVP token of the wrong shape is a 404 without touching anything');
for my $p ('/i/' . ('d' x 64), '/i/' . ('d' x 64) . '.ics', '/i/' . ('d' x 64) . '?answer=accepted') {
    $t->get_ok($p);
    isnt $t->tx->res->code, 404, "$p is routed (the lookup needs the database)";
}
$t->post_ok('/i/' . ('d' x 64) => form => { answer => 'accepted' });
isnt $t->tx->res->code, 404, 'a POSTed answer is routed too';

# --- public links: the shape of the routes (the lookup itself needs the database) ---
$t->get_ok('/c/not-a-token')->status_is(404, 'a token of the wrong shape is a 404 without touching anything');
$t->get_ok('/e/short')->status_is(404, '... for events too');
$t->get_ok('/c/' . ('a' x 64) . '.txt')->status_is(404, 'only .ics is a known extension');
# Routed (the 500 is the missing database, not the router): the plain page,
# the feed, the event page and its feed all reach the controller.
for my $p ('/c/' . ('a' x 64), '/c/' . ('a' x 64) . '.ics', '/c/' . ('a' x 64) . '/events', '/e/' . ('b' x 64), '/e/' . ('b' x 64) . '.ics') {
    $t->get_ok($p);
    isnt $t->tx->res->code, 404, "$p is routed (found live 2026-11-14: a restricted format made the extension required)";
}

# --- the link pages render (template compile errors are 500s only a render finds) ---
{
    require DateTime;
    my $share = { id => 1, token => 'c' x 64, shared_with_email => undef, detail => 'full', owner_email => 'o@example.test' };
    my $cal   = { id => 1, name => 'Team & co', color => '#6f94b8', description => 'A <calendar>', timezone => 'America/Chicago', owner_email => 'o@example.test' };
    my $ev    = { id => 2, title => 'Standup <weekly>', description => "Line 1\nLine 2", location => 'Room 4', color => undef, rrule => 'FREQ=WEEKLY;BYDAY=MO', all_day => 0, calendar_id => 1 };
    my $s = DateTime->new(year => 2026, month => 11, day => 16, hour => 9, time_zone => 'America/Chicago');
    my @occ = map { { all_day => 0, start => $s->clone->add(weeks => $_), end => $s->clone->add(weeks => $_, minutes => 30), title => 'Standup <weekly>', location => 'Room 4', description => 'x' } } 0 .. 2;
    $app->routes->get('/t/public_calendar' => sub ($c) {
        $c->render(template => 'public_calendar', share => $share, calendar => $cal, detail => 'full', boot => '{}');
    });
    $app->routes->get('/t/public_event' => sub ($c) {
        $c->render(template => 'public_event', share => $share, event => $ev, calendar => $cal, zone => 'America/Chicago',
            occurrences => \@occ, more => 1, ics_url => 'https://calendar.example.test/e/' . ('c' x 64) . '.ics');
    });
    $app->routes->get('/t/public_event_allday' => sub ($c) {
        my $d = DateTime->new(year => 2026, month => 11, day => 20, time_zone => 'America/Chicago');
        $c->render(template => 'public_event', share => $share, event => { %$ev, all_day => 1, rrule => undef }, calendar => $cal, zone => 'America/Chicago',
            occurrences => [ { all_day => 1, start => $d, end => $d->clone->add(days => 2), title => 'Conf', location => undef, description => undef } ], more => 0,
            ics_url => 'https://calendar.example.test/e/x.ics');
    });
    $t->get_ok('/t/public_calendar')->status_is(200)->content_like(qr/Subscribe \(\.ics\)/, 'the link page renders (found live 2026-11-14: an undeclared variable 500ed it)')
      ->content_like(qr{/c/c{64}\.ics}, '... with the feed link')->content_like(qr/Team &amp; co/, '... and escapes the name');
    $t->get_ok('/t/public_event')->status_is(200)->content_like(qr/Monday, November 16, 2026\s+9:00 AM - 9:30 AM/, 'the event page renders a timed occurrence')
      ->content_like(qr/Next occurrences/, '... and lists the next ones')->content_like(qr/and more/, '... with the "more" note')
      ->content_like(qr/Standup &lt;weekly&gt;/, '... escaping the title');
    $t->get_ok('/t/public_event_allday')->status_is(200)->content_like(qr/Fri, Nov 20 - Sat, Nov 21, 2026/, 'an all-day span shows its last day');
    # The invitation page (#85): waiting, answered, and cancelled.
    require Homelab::Calendar::Invite;
    my $att = { id => 5, email => 'ann@example.com', name => 'Ann <A>', status => 'needs-action', token => 'e' x 64, comment => undef };
    my %rsvp = (attendee => $att, event => $ev, calendar => $cal, zone => 'America/Chicago', cancelled => 0,
        when => 'Monday, November 16, 2026 9:00 AM to 9:30 AM (America/Chicago)', occurrences => [ 'Monday, November 16, 2026 9:00 AM to 9:30 AM (America/Chicago)', 'Monday, November 23, 2026 9:00 AM to 9:30 AM (America/Chicago)' ],
        others => [ { email => 'bob@example.com', name => undef, status => 'accepted' } ], status_word => \&Homelab::Calendar::Invite::status_word,
        saved => 0, error => undef, ics_url => 'https://calendar.example.test/i/' . ('e' x 64) . '.ics', in_my_calendar => undef);
    $app->routes->get('/t/rsvp' => sub ($c) { $c->render(template => 'rsvp', %rsvp) });
    $app->routes->get('/t/rsvp_saved' => sub ($c) { $c->render(template => 'rsvp', %rsvp, attendee => { %$att, status => 'declined', comment => 'Sorry "no"' }, saved => 1, in_my_calendar => 'https://calendar.example.test/?date=2026-11-16&event=2') });
    $app->routes->get('/t/rsvp_cancelled' => sub ($c) { $c->render(template => 'rsvp', %rsvp, cancelled => 1, occurrences => []) });
    $t->get_ok('/t/rsvp')->status_is(200)->content_like(qr/Are you coming\?/, 'the invitation page renders')
      ->content_like(qr{<form method="post" action="/i/e{64}"}, '... with the answer form on this token')
      ->content_like(qr/You have not answered yet/, '... waiting')->content_like(qr/Ann &lt;A&gt; \(ann\@example\.com\)/, '... escaping the name')
      ->content_like(qr/Also invited/, '... listing the others')->content_like(qr/bob\@example\.com.*accepted/s, '... with their answers')
      ->content_like(qr/Next occurrences/, '... and the next occurrences of a series');
    $t->get_ok('/t/rsvp_saved')->status_is(200)->content_like(qr/Your answer was saved\. You said no\./, 'an answer just saved is confirmed')
      ->content_like(qr/value="Sorry &quot;no&quot;"/, '... the note is kept in the field, escaped')
      ->content_like(qr/Open in my calendar here/, '... an account here is pointed at its own calendar');
    $t->get_ok('/t/rsvp_cancelled')->status_is(200)->content_like(qr/This event was cancelled by o\@example\.test/, 'a cancelled event says so')
      ->content_unlike(qr/Are you coming\?/, '... and asks nothing')->content_like(qr/Download the cancellation/, '... but offers the CANCEL .ics');
    # The page itself (0.3.2): what the phone layout hangs on is in the markup
    # and the layout, so a renamed id cannot quietly leave a dead button.
    $app->routes->get('/t/index_markup' => sub ($c) { $c->render(template => 'index', boot => '{}') });
    $t->get_ok('/t/index_markup')->status_is(200)
      ->element_exists('#cal-actions #side-toggle[aria-controls="cal-side"]', 'the action row has the drawer toggle')
      ->element_exists('#cal-actions #btn-search-m', '... search')
      ->element_exists('#cal-actions #btn-new-event-m', '... and new event')
      ->element_exists('#cal-actions #btn-suggestions-m.hide', '... with the suggestions pill hidden until there are any')
      ->element_exists('#cal-side .cal-side__head #side-close', 'the drawer has its close button')
      ->element_exists('#side-backdrop.cal-side-backdrop', '... and a backdrop')
      ->element_exists('#cal-side .cal-side__twin #btn-new-event', 'the sidebar\'s new event is marked as a twin (hidden in the drawer)')
      ->element_exists('#cal-side .cal-side__twin #q', '... so is its search box')
      ->element_exists('#search-modal #q2', 'the search dialog has its own box')
      ->content_like(qr/\.cal-side\.open \{ transform: translateX\(0\)/, 'the layout carries the drawer rule')
      ->content_like(qr/\.cal-actions, \.cal-side__head, \.cal-side-backdrop \{ display: none; \}/, '... and hides the phone pieces on a wide screen');
}

# --- the vendored bundle and the chrome ---
$t->get_ok('/vendor/fullcalendar/index.global.min.js')->status_is(200)->content_like(qr/FullCalendar Standard Bundle v6\.1\.22/, 'the FullCalendar bundle is served by the app');
$t->get_ok('/vendor/fullcalendar/LICENSE.md')->status_is(200)->content_like(qr/MIT/, '... with its licence');

# --- the page script has no template syntax (it runs as-is in the browser and under gjs) ---
my $js = Mojo::File->new('templates/calendar.js.ep')->slurp;
unlike $js, qr/^\s*%|<%/m, 'calendar.js.ep has no template tags';

done_testing;
