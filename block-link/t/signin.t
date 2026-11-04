use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use Mojo::URL;

# Signing in to the link page through homelab-sso (post-cutover item 48).
# No mocks: homelab-sso and homelab-api are pointed at 127.0.0.1:9, where
# nothing listens, so every step up to the server-to-server code exchange is
# real and the exchange itself fails the way an unreachable SSO would. The
# full round trip is checked live against production (see README.md).

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
block_link:
  link_ttl_days: 90
  public_base_url: "https://blockemail.example.test"
server:
  listen: "http://127.0.0.1:0"
YAML
    return $cfg->to_string;
}

$ENV{HOMELAB_BLOCK_LINK_HOME} = '.';
$ENV{HOMELAB_WEBTHEME_HOME}   = '../webtheme';

my $SSO = <<'YAML';
sso:
  base_url: "https://login.example.test"
  internal_base_url: "http://127.0.0.1:9"
  client_id: "block-link"
  client_secret: "test-client-secret"
  redirect_uri: "https://blockemail.example.test/oauth/callback"
session:
  secret: "test-session-secret"
  secure: 0
YAML


# The app needs homelab-common and homelab-webtheme, which CI does not put on
# @INC (it runs `prove -I lib`). Start it once with a good config first, so a
# missing library skips this file rather than passing for the wrong reason
# below.
{
    local $ENV{HOMELAB_BLOCK_LINK_CONFIG} = config($SSO);
    my $t = eval { Test::Mojo->new('Homelab::BlockLink::App') };
    plan skip_all => "could not start app: $@" unless $t;
}

# --- refusing to start on a half-written config ---
{
    local $ENV{HOMELAB_BLOCK_LINK_CONFIG} = config("sso:\n  base_url: \"https://login.example.test\"\n  client_id: x\nsession:\n  secret: s\n");
    my $t = eval { Test::Mojo->new('Homelab::BlockLink::App') };
    ok !$t, 'sso: without client_secret and redirect_uri: refuses to start';
    like $@, qr/missing client_secret redirect_uri/, '... and names what is missing';
}
{
    local $ENV{HOMELAB_BLOCK_LINK_CONFIG} = config(($SSO =~ s/^session:.*\z//msr));
    my $t = eval { Test::Mojo->new('Homelab::BlockLink::App') };
    ok !$t, 'sso: without a session secret: refuses to start';
    like $@, qr/session\.secret is required/, '... and says so';
}

$ENV{HOMELAB_BLOCK_LINK_CONFIG} = config($SSO);
my $t = Test::Mojo->new('Homelab::BlockLink::App');
my $app = $t->app;
ok $app->sso, 'sso: block loaded';
is $app->sso->{internal_base_url}, 'http://127.0.0.1:9', 'internal_base_url kept';
is $app->sessions->cookie_name, 'homelab-block-link', 'its own cookie name, like every other app';

my $token = 'cd' x 32;

# --- /login sends the browser to homelab-sso ---
$t->get_ok("/login?next=/l/$token")->status_is(302);
my $loc = Mojo::URL->new($t->tx->res->headers->location);
is $loc->host, 'login.example.test', 'to the public SSO name (the browser has to reach it)';
is $loc->path, '/oauth/authorize', '... its authorize endpoint';
is $loc->query->param('client_id'), 'block-link', '... as client block-link';
is $loc->query->param('redirect_uri'), 'https://blockemail.example.test/oauth/callback', '... back to the registered callback';
is $loc->query->param('response_type'), 'code', '... for an authorization code';
my $state = $loc->query->param('state');
like $state, qr/\A[0-9a-f]{32}\z/, '... with a random state';
ok $t->tx->res->cookie('homelab-block-link'), 'the state is kept in the session cookie';

# A second /login gets a different state.
$t->get_ok("/login?next=/l/$token");
isnt(Mojo::URL->new($t->tx->res->headers->location)->query->param('state'), $state, 'every sign-in gets a new state');
$state = Mojo::URL->new($t->tx->res->headers->location)->query->param('state');

# --- the callback checks the state before anything else ---
$t->get_ok('/oauth/callback?code=abc&state=' . ('0' x 32))->status_is(400)
  ->content_like(qr{Sign-in failed}, 'a state that does not match: refused');
# A refused callback uses the state up, as a used one would be.
$t->get_ok("/oauth/callback?code=abc&state=$state")->status_is(400, '... and that state cannot be replayed afterwards');

$t->get_ok("/login?next=/l/$token");
$state = Mojo::URL->new($t->tx->res->headers->location)->query->param('state');
$t->get_ok("/oauth/callback?state=$state")->status_is(400, 'no code: refused');

$t->get_ok("/login?next=/l/$token");
$state = Mojo::URL->new($t->tx->res->headers->location)->query->param('state');
$t->get_ok("/oauth/callback?code=abc&state=$state")->status_is(502)
  ->content_like(qr{could not be completed}, 'right state, SSO unreachable for the exchange: a clear failure, not a crash');

# A fresh browser (no session at all) cannot complete anyone's callback.
my $fresh = Test::Mojo->new($app);
$fresh->get_ok("/oauth/callback?code=abc&state=$state")->status_is(400, 'a callback with no session of its own is refused');

# --- where a sign-in may come back to ---
my $safe = \&Homelab::BlockLink::App::Controller::BlockLink::_safe_next;
is $safe->("/l/$token"), "/l/$token", 'a link page on this site: allowed';
is $safe->('https://evil.example/'), '', 'another site: dropped';
is $safe->('//evil.example/l/' . $token), '', 'a protocol-relative URL: dropped';
is $safe->("/l/$token/../../x"), '', 'a path that wanders off: dropped';
is $safe->("/l/$token\nSet-Cookie: x"), '', 'a header injection: dropped';
is $safe->('/l/short'), '', 'not a token: dropped';
is $safe->(undef), '', 'nothing: nothing';

# --- a session token that no longer introspects means signed out ---
$app->routes->get('/t/set-token' => sub ($c) { $c->session(token => 'not-a-live-token'); $c->render(text => 'set') });
$app->routes->get('/t/who' => sub ($c) { $c->render(text => 'who=' . $c->session_email) });
$t->get_ok('/t/set-token')->content_is('set');
$t->get_ok('/t/who')->content_is('who=', 'a dead token (api unreachable here) is simply signed out');

# --- unblocking from the list: only from this site's own page, signed in ---
# The session cookie is the credential for an unblock, so a request must carry
# the CSRF token the page was drawn with. Both checks come before the link is
# looked up, which is why they can be tested here with no database.
$app->routes->get('/t/csrf' => sub ($c) { $c->render(text => $c->csrf_token) });
my $csrf = $t->get_ok('/t/csrf')->tx->res->body;
like $csrf, qr/\A[0-9a-f]{40}\z/, 'the page\'s CSRF token';
$t->post_ok("/l/$token/unblock" => json => { address => 'a@b.example' })->status_is(403)
  ->json_like('/error', qr/out of date/, 'unblock without the page\'s token: refused (a cross-site request has none)');
$t->post_ok("/l/$token/unblock" => { 'X-CSRF-Token' => 'f' x 40 } => json => { address => 'a@b.example' })->status_is(403)
  ->json_like('/error', qr/out of date/, '... and with the wrong one');
my $other = Test::Mojo->new($app);
my $theirs = $other->get_ok('/t/csrf')->tx->res->body;
$t->post_ok("/l/$token/unblock" => { 'X-CSRF-Token' => $theirs } => json => { address => 'a@b.example' })->status_is(403,
  '... and with another browser\'s');
$t->post_ok("/l/$token/unblock" => { 'X-CSRF-Token' => $csrf } => json => { address => 'a@b.example' })->status_is(401)
  ->json_like('/error', qr/sign-in has ended/, 'the right token, but the session\'s sign-in is dead: refused, and it says why');
$t->get_ok("/l/$token/unblock")->status_is(404, 'unblock is POST only');

# --- /logout ---
$t->post_ok('/logout')->status_is(302)->header_is(Location => 'https://login.example.test/logout',
    'sign-out hands off to homelab-sso\'s single sign-out');
like $t->tx->res->headers->set_cookie // '', qr/homelab-block-link=;|expires=Thu, 01 Jan 1970/i, '... and clears this app\'s cookie';
$t->get_ok('/logout')->status_is(404, 'sign-out is POST only (a GET can be triggered cross-site)');

done_testing;
