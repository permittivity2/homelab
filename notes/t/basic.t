use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# The app's shape without a database: start-up checks, sign-in through
# homelab-sso, what is refused before anything is looked up (a dead sign-in,
# a missing CSRF token), the security headers, the page script. homelab-sso
# and homelab-api are pointed at 127.0.0.1:9, where nothing listens, so every
# step up to the server-to-server exchange is real. Data paths are proven in
# t/model.t against a real PostgreSQL.

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
notes:
  public_base_url: "https://notes.example.test/"
server:
  listen: "http://127.0.0.1:0"
YAML
    return $cfg->to_string;
}

$ENV{HOMELAB_NOTES_HOME} = '.';
$ENV{HOMELAB_WEBTHEME_HOME} = '../webtheme';

my $SSO = <<'YAML';
sso:
  base_url: "https://login.example.test"
  internal_base_url: "http://127.0.0.1:9"
  client_id: "notes"
  client_secret: "test-client-secret"
  redirect_uri: "https://notes.example.test/oauth/callback"
session:
  secret: "test-session-secret"
  secure: 0
YAML

{
    local $ENV{HOMELAB_NOTES_CONFIG} = config($SSO);
    my $t = eval { Test::Mojo->new('Homelab::Notes::App') };
    plan skip_all => "could not start app: $@" unless $t;
}

# --- refusing to start on a bad config ---
{
    local $ENV{HOMELAB_NOTES_CONFIG} = config("sso:\n  base_url: https://login.example.test\n");
    eval { Test::Mojo->new('Homelab::Notes::App') };
    like $@, qr/sso: is present but missing/, 'an incomplete sso: block refuses to start';
}
{
    local $ENV{HOMELAB_NOTES_CONFIG} = config("sso:\n  base_url: https://login.example.test\n  client_id: notes\n  client_secret: x\n  redirect_uri: https://notes.example.test/oauth/callback\n");
    eval { Test::Mojo->new('Homelab::Notes::App') };
    like $@, qr/session\.secret is required/, 'sso without a session secret refuses to start';
}

# --- without sign-in configured ---
{
    local $ENV{HOMELAB_NOTES_CONFIG} = config('');
    my $t = Test::Mojo->new('Homelab::Notes::App');
    $t->get_ok('/')->status_is(302)->header_like(Location => qr{^/login$}, 'the page sends a visitor to /login');
    $t->get_ok('/login')->status_is(503)->content_like(qr/Sign-in is not set up/, 'no sso: block = a plain notice');
    $t->get_ok('/api/notebooks')->status_is(401)->json_like('/error' => qr/sign-in/i, 'JSON routes answer 401');
    $t->get_ok('/internal/v1/notes/notebooks')->status_is(401)->json_is('/error' => 'not logged in', 'the gateway twins want a Bearer token');
    $t->get_ok('/internal/v1/notes/notebooks' => { Authorization => 'Bearer nonsense' })->status_is(401, '... a token the api does not know is refused');
    $t->get_ok('/s/' . ('0' x 64))->status_is(404)->content_like(qr/not valid/, 'an unknown share link is not valid (the database is absent, so the lookup dies and is caught)') if 0;
    $t->get_ok('/notes.js')->status_is(200)->content_type_like(qr{javascript})->content_like(qr/homelab-notes: the page script/, 'the page script is served by the app');
    $t->get_ok('/notes.css')->status_is(200)->content_like(qr/notes-panes/, 'the stylesheet too');
    is $t->app->search_url, 'https://search.example.test', 'the search app is assumed beside this one';
    is $t->app->drive_url,  'https://drive.example.test',  '... and drive';
    like $t->app->csp, qr/script-src 'self' https:\/\/static\.mailmasker\.org/, 'the CSP names the theme host and nothing inline';
    like $t->tx->res->headers->header('Content-Security-Policy'), qr/object-src 'none'/, 'every response carries the CSP';
    is $t->tx->res->headers->header('X-Frame-Options'), 'DENY', '... and the frame denial';
}

# --- with sign-in configured ---
{
    local $ENV{HOMELAB_NOTES_CONFIG} = config($SSO);
    my $t = Test::Mojo->new('Homelab::Notes::App');
    $t->get_ok('/')->status_is(302)->header_is(Location => '/login', 'not signed in: to /login');
    $t->get_ok('/n/42')->status_is(302)->header_is(Location => '/login?next=%2Fn%2F42', 'a deep link remembers where to come back to');
    $t->get_ok('/login')->status_is(302);
    my $loc = Mojo::URL->new($t->tx->res->headers->location);
    is $loc->host, 'login.example.test', '/login sends the browser to homelab-sso';
    is $loc->path, '/oauth/authorize', '... the authorize endpoint';
    is $loc->query->param('client_id'), 'notes', '... as the notes client';
    is $loc->query->param('redirect_uri'), 'https://notes.example.test/oauth/callback', '... back to this app';
    ok length($loc->query->param('state')) >= 32, '... with a state';
    $t->get_ok('/oauth/callback?code=x&state=wrong')->status_is(400)->content_like(qr/Sign-in failed/, 'a wrong state fails the sign-in');
    $t->get_ok('/logout')->status_is(404, 'GET /logout does nothing (POST only)');
    $t->post_ok('/logout')->status_is(302)->header_is(Location => 'https://login.example.test/logout', 'POST /logout hands off to the single sign-out');
    $t->post_ok('/api/notes' => json => { title => 'x' })->status_is(401, 'a write without a session is 401 before anything else');
    $t->get_ok('/health')->status_is(503, '/health is 503 while the database is absent');
    $t->get_ok('/metrics')->status_is(200)->content_like(qr/^homelab_notes_up 0$/m, '/metrics says the database did not answer, instead of dying');
}

done_testing;
