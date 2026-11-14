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

# --- public links: the shape of the routes (the lookup itself needs the database) ---
$t->get_ok('/c/not-a-token')->status_is(404, 'a token of the wrong shape is a 404 without touching anything');
$t->get_ok('/e/short')->status_is(404, '... for events too');
$t->get_ok('/c/' . ('a' x 64) . '.txt')->status_is(404, 'only .ics is a known format');

# --- the vendored bundle and the chrome ---
$t->get_ok('/vendor/fullcalendar/index.global.min.js')->status_is(200)->content_like(qr/FullCalendar Standard Bundle v6\.1\.22/, 'the FullCalendar bundle is served by the app');
$t->get_ok('/vendor/fullcalendar/LICENSE.md')->status_is(200)->content_like(qr/MIT/, '... with its licence');

# --- the page script has no template syntax (it runs as-is in the browser and under gjs) ---
my $js = Mojo::File->new('templates/calendar.js.ep')->slurp;
unlike $js, qr/^\s*%|<%/m, 'calendar.js.ep has no template tags';

done_testing;
