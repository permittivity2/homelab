use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# The invite acceptance page on the shared chrome. Self-contained -- no
# database, no reachable homelab-api -- because what this checks is
# template/plugin wiring. The real /invite/:token route needs the DB for its
# rate limiter and token lookup, so the templates are rendered through
# test-only routes with the same stash the controller passes.
#
# Worth having: this package had NO templates at all until 2026-10-27 (the
# page was qq{} HTML in the controller), so every one of these assertions
# covers something that did not exist and could silently regress to a bare
# unstyled page without erroring.

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<'YAML');
server:
  listen: "http://127.0.0.1:0"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
homelab_api:
  base_url: "http://127.0.0.1:9/api"
invite:
  public_base_url: "https://invite.test"
  account_domain: "example.test"
  default_max_pending: 5
  default_max_per_day: 5
  ttl_days: 7
mailer:
  email: "noreply@example.test"
  smtp_host: "10.50.2.140"
  smtp_port: 587
  smtp_password: "x"
YAML

$ENV{HOMELAB_INVITE_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_INVITE_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME} = '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::Invite::App') };
unless ($t) {
    plan skip_all => "could not start app: $@";
}
my $app = $t->app;

ok($app->renderer->helpers->{theme_base}, 'theme_base helper installed');
is($app->build_controller->homelab_app_name, '',
    "app_name is deliberately empty so the footer names the product, not a verb");

# The sender's free-text message is attacker-influenceable: whoever sent the
# invite wrote it. The old code hand-rolled xml_escape per field; this asserts
# the renderer is actually escaping now.
my $nasty = q{</p><script>alert('xss')</script>};

$app->routes->get('/t/accept' => sub ($c) {
    $c->render(template => 'accept',
        recipient_email => 'invitee@elsewhere.test',
        message         => $nasty,
        token           => 'a' x 64,
        domain          => 'example.test',
        login_url       => 'https://myaccount.example.test/');
});
$app->routes->get('/t/notice' => sub ($c) {
    $c->render(template => 'notice', heading => 'Invite no longer valid',
        body => 'This invite has already been used, been revoked, or expired.');
});

for my $path ('/t/accept', '/t/notice') {
    $t->get_ok($path)->status_is(200)
      ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, "$path: shared stylesheet")
      ->content_like(qr{theme/v1/logo\.svg},   "$path: Silver Linings logo")
      ->content_like(qr{class="appfoot"},      "$path: shared footer")
      ->content_like(qr{MailMasker is a product of}, "$path: footer names the product")
      # No top bar: whoever opens an invite link has no account yet.
      ->content_unlike(qr{class="topbar"},     "$path: no account chrome")
      # Leftovers from the old inline page's palette.
      ->content_unlike(qr{#3562d4|#f5f6f8|#d5d8dd}, "$path: no old-palette literals");
}

# --- the acceptance form still does its job ---
$t->get_ok('/t/accept')
  ->content_like(qr{id="username"},            'username field present')
  ->content_like(qr{id="pw2"},                 'password confirmation present')
  ->content_like(qr{\@example\.test},          'the login domain is shown next to the username')
  ->content_like(qr{value="invitee\@elsewhere\.test"}, 'recovery email pre-filled with the invited address')
  ->content_like(qr{id="card-body"},           'the card body wrapper the success state replaces');

# --- escaping ---
$t->get_ok('/t/accept')
  ->content_unlike(qr{<script>alert\('xss'\)</script>}, "the sender's message cannot inject markup")
  ->content_like(qr{&lt;/p&gt;|&lt;script&gt;},         'it is escaped, not dropped');

# The success state must replace only the card body, never document.body --
# doing the latter threw away the chrome (logo and footer included) at the
# most reassuring moment in the flow.
$t->get_ok('/t/accept')
  ->content_unlike(qr{document\.body\.innerHTML}, 'success state does not overwrite the whole page');

done_testing;
