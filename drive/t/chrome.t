use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# Shared web chrome (homelab-webtheme). Unlike every other test in this
# directory this one is SELF-CONTAINED -- no real database, no reachable
# homelab-api -- because what it checks is template/plugin wiring, and that
# should never be skipped just because a dev box has no DB. Mojo::Pg connects
# lazily, so a syntactically valid DSN pointing nowhere is enough to boot.
#
# Worth having because both ways this wiring breaks are SILENT: a missing
# plugin registration turns `theme_base` into an unknown helper (500 on every
# page) and a missing user_email resolver makes the account menu quietly
# vanish.

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<"YAML");
server:
  listen: "http://127.0.0.1:0"
session:
  secret: "test-only-not-a-real-secret"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
storage:
  path: "@{[ $dir->child('storage') ]}"
public_base_url: "https://drive.test"
homelab_api:
  base_url: "http://127.0.0.1:9/api"
sso:
  base_url: "https://sso.test"
  client_id: "test"
  client_secret: "test"
  redirect_uri: "https://drive.test/sso/callback"
YAML

$ENV{HOMELAB_DRIVE_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_DRIVE_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME}= '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::Drive::App') };
unless ($t) {
    plan skip_all => "could not start app (Homelab::WebTheme not reachable?): $@";
}
my $app = $t->app;

ok($app->renderer->helpers->{theme_base},         'theme_base helper installed');
ok($app->renderer->helpers->{homelab_user_email}, 'homelab_user_email helper installed');
is($app->build_controller->homelab_app_name, 'Drive', 'app_name reaches the partials');

# The account-dropdown link used to default to the TEST fleet, and no prod
# config sets the key -- so every production install pointed users at
# myaccount.test.mailmasker.org. Pin the default.
is($app->account_manage_url, 'https://myaccount.mailmasker.org',
    'account_manage_url defaults to the production host');
my $links = $app->build_controller->homelab_menu_links;
is(scalar(@$links), 2, 'drive publishes two cross-app links');
is($links->[0]{href}, 'https://myaccount.mailmasker.org', 'first link is the configured account URL');
unlike(join(' ', map { $_->{label} } @$links), qr/Drive/, 'drive does not link to itself');

# --- the layout, rendered through a real template. NOT `inline`:
#     Mojolicious skips layout inheritance entirely for inline templates
#     (Renderer.pm: `&& !defined $inline`), so an inline render would have
#     returned the bare body and passed with no chrome at all. ---
push @{$app->renderer->classes}, 'main';
$app->routes->get('/t/chrome' => sub ($c) {
    $c->stash(email => 'someone@test.example');
    $c->render(template => 't_chrome', layout => 'default', title => 'Homelab Drive');
});
$app->routes->get('/t/login' => sub ($c) {
    $c->render(template => 'login', error => 'Sign-in failed.');
});

$t->get_ok('/t/chrome')->status_is(200)
  ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, 'shared stylesheet linked')
  ->content_like(qr{class="topbar"},                   'shared top bar present')
  ->content_like(qr{class="topbar__logo"},             'Silver Linings logo in the top bar')
  ->content_like(qr{data-menu="homelab-account-menu"}, 'account dropdown trigger present')
  ->content_like(qr{someone\@test\.example},           'signed-in address rendered server-side')
  ->content_like(qr{class="appfoot"},                  'shared footer present')
  ->content_like(qr{theme/v1/shell\.js},               'shell.js loaded (drives the dropdown)')
  ->content_like(qr{\Q<p>body</p>\E},                  'page content lands inside the shell');

# shell.js owns [data-menu] now; the app-local handler had to go, or two
# handlers on one button would toggle it open and shut again.
$t->get_ok('/t/chrome')
  ->content_unlike(qr{getElementById\('profile-btn'\)}, 'app-local dropdown handler removed');

# Dark-only: the old sheet shipped a light base plus a
# prefers-color-scheme override, so the app flipped look with the OS setting.
$t->get_ok('/t/chrome')
  ->content_unlike(qr{\@media\s*\(prefers-color-scheme}, 'no light/dark branching left')
  ->content_unlike(qr{#f5f6f8|#e3e5e9|#1e2128},  'no hardcoded light-theme or old-dark literals');

# --- the login page: shared theme, no top bar (nobody is signed in) ---
$t->get_ok('/t/login')->status_is(200)
  ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, 'login pulls the shared stylesheet')
  ->content_like(qr{theme/v1/logo\.svg},   'login shows the logo')
  ->content_like(qr{Sign-in failed\.},     'login still surfaces the error')
  ->content_unlike(qr{class="topbar"},     'no top bar on a page with no signed-in user');

done_testing;

__DATA__

@@ t_chrome.html.ep
<p>body</p>
