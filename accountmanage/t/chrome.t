use Mojo::Base -strict, -signatures;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir path);

# The shared web chrome (homelab-webtheme) is adopted by REGISTERING a plugin
# and INCLUDING partials -- two things that fail silently in different ways:
# a missing plugin makes `theme_base` an unknown helper (500 on every page),
# and a missing helper value makes the account menu vanish without an error.
# This boots the real app against a throwaway config and asserts the chrome
# actually lands in the HTML, on both an authenticated page and the login page
# (which has no signed-in address at all -- the case a raw stash value broke).

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<'YAML');
server:
  listen: "http://127.0.0.1:0"
session:
  secret: "test-only-not-a-real-secret"
public_base_url: "https://myaccount.test"
homelab_api:
  base_url: "http://127.0.0.1:9/api"
sso:
  base_url: "https://sso.test"
  client_id: "test"
  client_secret: "test"
  redirect_uri: "https://myaccount.test/login/callback"
YAML

# The app looks for its templates under HOMELAB_ACCOUNTMANAGE_HOME and the
# shared partials under HOMELAB_WEBTHEME_HOME -- point both at the source
# trees so this runs from a checkout with nothing installed.
$ENV{HOMELAB_ACCOUNTMANAGE_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_ACCOUNTMANAGE_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME}        = '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::Accountmanage::App') };
unless ($t) {
    plan skip_all => "could not start app (Homelab::WebTheme not reachable?): $@";
}

# --- the plugin is registered: its helper resolves ---
my $app = $t->app;
ok($app->renderer->helpers->{theme_base},        'theme_base helper installed');
ok($app->renderer->helpers->{homelab_user_email},'homelab_user_email helper installed');
is($app->build_controller->homelab_app_name, 'My Account', 'app_name reaches the partials');

# A DATA-section template plus a test-only route: the layout must be exercised
# through a REAL template file, because Mojolicious skips layout inheritance
# entirely for `inline` templates (Renderer.pm: `&& !defined $inline`) -- an
# inline render would silently return the bare body and pass nothing.
push @{$app->renderer->classes}, 'main';
$app->routes->get('/t/chrome' => sub ($c) {
    $c->stash(email => 'someone@test.example');
    $c->render(template => 't_chrome', layout => 'default', title => 'My Account');
});
# /login redirects straight to SSO; the login TEMPLATE is only rendered on a
# failed callback, so render it explicitly the way that error path does.
$app->routes->get('/t/login' => sub ($c) {
    $c->render(template => 'login', error => 'Sign-in expired or was invalid.');
});

# --- the LOGIN page must carry the shared theme without exploding on the
#     absent signed-in address (the case a raw stash value broke in drive) ---
$t->get_ok('/t/login')->status_is(200)
  ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, 'login pulls the shared stylesheet')
  ->content_like(qr{theme/v1/logo\.svg},                          'login shows the Silver Linings logo')
  ->content_like(qr{Sign in with Homelab SSO},                    'login still offers SSO')
  ->content_unlike(qr{\bprofile-btn\b}, 'no account menu on a page with no signed-in user');

# --- the layout itself. Rendered through a real request rather than
#     render_to_string, which DELETES `layout` from the stash by design --
#     so a string render would silently test the body with no chrome at all.
{
    $t->get_ok('/t/chrome')->status_is(200);
    my $html = $t->tx->res->text;
    ok($html, 'layout renders with the shared chrome');
    like($html, qr{class="topbar"},                 'shared top bar present');
    like($html, qr{class="topbar__logo"},           'logo in the top bar');
    like($html, qr{data-menu="homelab-account-menu"}, 'account dropdown trigger present');
    like($html, qr{someone\@test\.example},         'signed-in address rendered server-side');
    like($html, qr{class="appfoot"},                'shared footer present');
    like($html, qr{theme/v1/shell\.js},             'shell.js loaded (drives the dropdown)');
    like($html, qr{\Q<p>body</p>\E},                'page content still lands inside the shell');

    # The old hand-rolled dropdown JS must be GONE: shell.js owns it now, and
    # two handlers on one button would toggle it open and shut again.
    unlike($html, qr{getElementById\('profile-btn'\)}, 'app-local dropdown handler removed');

    # Light-theme leftovers. The app is dark-only now; these were the page and
    # card backgrounds that would read as white-on-white if a rule was missed.
    unlike($html, qr{#f6f7f9|#ffffff\b|#e3e5e9}, 'no light-theme literals left in the layout');
}

done_testing;

__DATA__

@@ t_chrome.html.ep
<p>body</p>
