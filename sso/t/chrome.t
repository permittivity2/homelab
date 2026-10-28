use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# Shared web chrome (homelab-webtheme) on the auth pages. Self-contained: no
# database, no reachable homelab-api, because what this checks is
# template/plugin wiring -- and both ways that breaks are silent. A missing
# plugin makes `theme_base` an unknown helper (500 on the LOGIN page, i.e.
# nobody can sign in to anything), and a template that still carries its own
# copy of the chrome drifts away from the rest of the fleet without erroring.

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<'YAML');
server:
  listen: "http://127.0.0.1:0"
session:
  secret: "test-only-not-a-real-secret"
public_base_url: "https://login.test"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
jwt:
  secret: "test-only-not-a-real-secret"
homelab_api:
  base_url: "http://127.0.0.1:9/api"
YAML

$ENV{HOMELAB_SSO_CONFIG}    = $cfg->to_string;
$ENV{HOMELAB_SSO_HOME}      = '.';
$ENV{HOMELAB_WEBTHEME_HOME} = '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::SSO::App') };
unless ($t) {
    plan skip_all => "could not start app: $@";
}
my $app = $t->app;

ok($app->renderer->helpers->{theme_base}, 'theme_base helper installed');

# app_name is empty on purpose so the shared footer says "MailMasker is a
# product of ...", not "Sign in is a product of ...".
is($app->build_controller->homelab_app_name, '', 'app_name is deliberately empty');

# Render each auth page through the layout. A real request, not
# render_to_string -- Mojolicious deletes `layout` from the stash when
# rendering to a string, so those would silently test the bare body.
my %pages = (
    '/t/login'   => { template => 'oauth/login',
                      stash => { error => '', client_id => 'c', redirect_uri => 'https://x.test/cb',
                                 state => 's', scope => 'openid' } },
    '/t/out'     => { template => 'oauth/logged_out', stash => {} },
    '/t/err'     => { template => 'oauth/error', stash => { message => 'bad request' } },
    '/t/forgot'  => { template => 'reset/forgot',  stash => {} },
    '/t/reset'   => { template => 'reset/reset',   stash => { token => 'tok' } },
    '/t/done'    => { template => 'reset/done',    stash => {} },
    '/t/sent'    => { template => 'reset/forgot_sent', stash => {} },
);
for my $path (sort keys %pages) {
    my $p = $pages{$path};
    $app->routes->get($path => sub ($c) {
        $c->stash(%{ $p->{stash} });
        $c->render(template => $p->{template}, layout => 'auth');
    });
}

for my $path (sort keys %pages) {
    my $tmpl = $pages{$path}{template};
    $t->get_ok($path)->status_is(200)
      ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, "$tmpl: shared stylesheet")
      ->content_like(qr{theme/v1/logo\.svg},                          "$tmpl: Silver Linings logo")
      ->content_like(qr{class="appfoot"},                             "$tmpl: shared footer")
      ->content_like(qr{MailMasker is a product of},                  "$tmpl: footer names the product, not the verb")
      # No top bar: nobody is signed in on an auth page, so a header would
      # render an empty account cluster.
      ->content_unlike(qr{class="topbar"},                            "$tmpl: no top bar")
      # Each page must get its chrome from the LAYOUT. login/error/logged_out
      # used to be standalone documents with their own copy of it.
      ->content_unlike(qr{\@media\s*\(prefers-color-scheme},           "$tmpl: no light/dark branching")
      ->content_unlike(qr{#f5f6f8|#1e2128|#3562d4},                   "$tmpl: no leftover palette literals");
}

# The login form still does its actual job.
$t->get_ok('/t/login')
  ->content_like(qr{name="client_id"},    'login carries client_id through')
  ->content_like(qr{name="redirect_uri"}, 'login carries redirect_uri through')
  ->content_like(qr{name="state"},        'login carries state through')
  ->content_like(qr{name="scope"},        'login carries scope through')
  ->content_like(qr{href="/forgot"},      'the forgot-password link survives');

done_testing;
