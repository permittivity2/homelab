use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# The public block-link pages on the shared mailmasker chrome. Self-contained
# -- no database, no reachable homelab-api -- because what this checks is
# template/plugin wiring. The real /l/:token route needs the DB to look the
# token up, so the templates are rendered through test-only routes with the
# same stash the controller passes (t/basic.t covers the real route against
# a real deployment).
#
# Worth having: until 2026-11-03 these pages were qq{} HTML in the
# controller, so every assertion here covers something that could silently
# regress to a bare, unstyled page without erroring. Rendered from real
# template files, never `inline`: Mojolicious skips the layout entirely for
# inline templates, so an inline test would pass with no chrome at all.

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<'YAML');
homelab_api:
  base_url: "http://127.0.0.1:9/api"
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

$ENV{HOMELAB_BLOCK_LINK_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_BLOCK_LINK_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME}     = '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::BlockLink::App') };
unless ($t) {
    plan skip_all => "could not start app: $@";
}
my $app = $t->app;

ok($app->renderer->helpers->{theme_base}, 'theme_base helper installed');

# An address is whatever the sender put in To:/Cc:, so it is
# attacker-influenceable.
my $nasty = q{"><script>alert('xss')</script>@example.test};
my $token = 'ab' x 32;

$app->routes->get('/t/manage' => sub ($c) {
    $c->render(template => 'manage', token => $token, candidates => [
        { account_email => 'owner@example.test', address => 'shop1@example.test' },
        { account_email => 'owner@example.test', address => $nasty },
    ]);
});
$app->routes->get('/t/notice' => sub ($c) {
    $c->render(template => 'notice', status => 410, heading => 'Link expired',
        body => 'This management link has expired.');
});

$t->get_ok('/t/manage')->status_is(200);
$t->get_ok('/t/notice')->status_is(410, 'the notice page keeps the status it is given');

for my $path ('/t/manage', '/t/notice') {
    $t->get_ok($path)
      ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, "$path: shared stylesheet")
      ->content_like(qr{class="topbar"},                     "$path: shared top bar")
      ->content_like(qr{theme/v1/logo\.svg},                 "$path: Silver Linings logo")
      ->content_like(qr{class="topbar__app">Block email<},   "$path: app name in the top bar")
      ->content_like(qr{class="appfoot"},                    "$path: shared footer")
      ->content_like(qr{theme/v1/shell\.js},                 "$path: shared script")
      # Nobody is signed in here: the link's token is the only credential.
      ->content_unlike(qr{class="profile"},                  "$path: no account menu")
      # Leftovers from the old qq{} page.
      ->content_unlike(qr{font-family:sans-serif|color:#b00|color:#080}, "$path: none of the old inline look")
      ->content_unlike(qr{prefers-color-scheme},             "$path: dark-only, like every other app");
}

# --- the form still does its job ---
$t->get_ok('/t/manage')
  ->content_like(qr{<h1>Manage blocked addresses</h1>},  'heading unchanged')
  ->content_like(qr{id="blockform"},                     'the form the script binds to')
  ->content_like(qr{data-token="$token"},                'the token Save posts back to')
  ->content_like(qr{name="block" value="shop1\@example\.test" checked}, 'each address is a pre-checked box')
  ->content_like(qr{id="msg"},                           'the status line');

# --- escaping ---
$t->get_ok('/t/manage')
  ->content_unlike(qr{<script>alert\('xss'\)</script>},  'an address cannot inject markup')
  ->content_like(qr{&lt;script&gt;},                     'it is escaped, not dropped');

# The logo links to "/": that must lead somewhere, not to a 404.
$t->get_ok('/')->status_is(302)->header_is(Location => 'https://mailmasker.org/');

done_testing;
