use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# The public block-link pages: the shared mailmasker chrome, and what each
# kind of visitor is shown. Self-contained -- no database, no reachable
# homelab-api -- because what this checks is template/plugin wiring. The real
# /l/:token route needs the DB to look the token up, so the templates are
# rendered through test-only routes with the same stash the controller passes,
# built with the same Visibility::view() it uses (t/basic.t covers the real
# route against a real deployment).
#
# Worth having: until 2026-11-03 these pages were qq{} HTML in the
# controller, so every assertion here covers something that could silently
# regress to a bare, unstyled page without erroring. Rendered from real
# template files, never `inline`: Mojolicious skips the layout entirely for
# inline templates, so an inline test would pass with no chrome at all.

use lib 'lib';
use Homelab::BlockLink::Visibility qw(view);

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
  manage_account_url: "https://myaccount.example.test/#mailself"
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
is($app->manage_account_url, 'https://myaccount.example.test/#mailself', 'manage_account_url comes from config');

# An address is whatever the sender put in To:/Cc:, so it is
# attacker-influenceable.
my $nasty = q{"><script>alert('xss')</script>@example.test};
my $token = 'ab' x 32;
my $alice = 'alice@example.test';
my $bob   = 'bob@example.test';

my $one = [
    { account_email => $alice, address => 'shop1@alice.example' },
    { account_email => $alice, address => $nasty },
];
my $two = [
    { account_email => $alice, address => 'shop1@alice.example' },
    { account_email => $bob,   address => 'secret-bcc@bob.example' },
];

# The controller's stash, for a given visitor.
sub page ($c, %o) {
    my $view = view($o{candidates}, $o{signed_in} // '');
    my %already = map { lc($_) => 1 } @{ $o{blocked} // [] };
    $c->stash(user_email => $o{signed_in}) if $o{signed_in};   # what the header shows
    $c->render(
        template    => 'manage',
        token       => $token,
        view        => $view,
        add         => [ grep { !$already{ lc $_->{address} } } @{ $view->{offer} } ],
        blocked     => $o{blocked} // [],
        list_error  => $o{list_error} // 0,
        signed_in   => $o{signed_in} // '',
        can_sign_in => $o{can_sign_in} // 1,
        manage_url  => $c->app->manage_account_url,
    );
}

my $r = $app->routes;
$r->get('/t/link'          => sub ($c) { page($c, candidates => $one) });
$r->get('/t/link-nosso'    => sub ($c) { page($c, candidates => $one, can_sign_in => 0) });
$r->get('/t/owner'         => sub ($c) { page($c, candidates => $one, signed_in => $alice,
    blocked => ['a-first@x.example', 'B-second@x.example', $nasty]) });
$r->get('/t/owner-done'    => sub ($c) { page($c, candidates => [$one->[0]], signed_in => $alice,
    blocked => ['shop1@alice.example']) });
$r->get('/t/owner-empty'   => sub ($c) { page($c, candidates => [$one->[0]], signed_in => $alice, blocked => []) });
$r->get('/t/owner-error'   => sub ($c) { page($c, candidates => $one, signed_in => $alice, list_error => 1) });
$r->get('/t/several'       => sub ($c) { page($c, candidates => $two) });
$r->get('/t/several-other' => sub ($c) { page($c, candidates => $two, signed_in => 'carol@example.test') });
$r->get('/t/several-alice' => sub ($c) { page($c, candidates => $two, signed_in => $alice, blocked => []) });
$r->get('/t/link-other'    => sub ($c) { page($c, candidates => $one, signed_in => 'carol@example.test') });
$r->get('/t/main'          => sub ($c) { page($c, candidates => [
    { account_email => $alice, address => $alice },
    { account_email => $alice, address => 'shop1@alice.example' } ]) });
$r->get('/t/notice' => sub ($c) {
    $c->render(template => 'notice', status => 410, heading => 'Link expired',
        body => 'This management link has expired.');
});

$t->get_ok('/t/link')->status_is(200);
$t->get_ok('/t/notice')->status_is(410, 'the notice page keeps the status it is given');

# --- the shared chrome, on every page ---
for my $path ('/t/link', '/t/owner', '/t/several', '/t/notice') {
    $t->get_ok($path)
      ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, "$path: shared stylesheet")
      ->content_like(qr{class="topbar"},                     "$path: shared top bar")
      ->content_like(qr{theme/v1/logo\.svg},                 "$path: Silver Linings logo")
      ->content_like(qr{class="topbar__app">Block email<},   "$path: app name in the top bar")
      ->content_like(qr{class="appfoot"},                    "$path: shared footer")
      ->content_like(qr{theme/v1/shell\.js},                 "$path: shared script")
      # Leftovers from the old qq{} page.
      ->content_unlike(qr{font-family:sans-serif|color:#b00|color:#080}, "$path: none of the old inline look")
      ->content_unlike(qr{prefers-color-scheme},             "$path: dark-only, like every other app");
}
$t->get_ok('/t/link')->content_unlike(qr{class="profile"}, 'signed out: no account menu');
$t->get_ok('/t/owner')
  ->content_like(qr{class="profile"}, 'signed in: the shared account menu')
  ->content_like(qr{class="who">alice\@example\.test<}, '... with the address')
  ->content_like(qr{<form method="post" action="/logout">}, '... and Sign out posts to /logout');

# --- one account on the link, signed out: the one-click block, no list ---
$t->get_ok('/t/link')
  ->content_like(qr{<h1>Manage blocked addresses</h1>},  'heading unchanged')
  ->content_like(qr{id="blockform"},                     'the form the script binds to')
  ->content_like(qr{data-token="$token"},                'the token the form posts back to')
  ->content_like(qr{name="block" value="shop1\@alice\.example" checked}, 'each address is a pre-checked box')
  ->content_like(qr{>Add to Block List</button>},       'the button says Add to Block List')
  ->content_unlike(qr{>Save<},                           'not Save')
  ->content_like(qr{id="msg"},                           'the status line')
  ->content_unlike(qr{id="bl-list"},                     'no block list without signing in')
  ->content_unlike(qr{data-csrf=|id="bl-confirm"},       '... so nothing to unblock with either')
  ->content_like(qr{href="/login\?next=%2Fl%2F$token"},  'a sign-in button that comes back to this link')
  ->content_like(qr{Sign in to see your block list},     '... saying what it is for');
my $link_html = $t->tx->res->body;
my @manage = $link_html =~ m{<a class="btn" href="https://myaccount\.example\.test/\#mailself">Manage Account</a>}g;
is(scalar @manage, 2, 'two Manage Account buttons, both to myaccount\'s Mail section');
like($link_html, qr{Manage Account</a>.*id="add-section".*id="blocklist-section".*Manage Account</a>}s,
    '... one above the add section, one below the list');

$t->get_ok('/t/link-nosso')
  ->content_unlike(qr{href="/login}, 'no sign-in configured: no sign-in button')
  ->content_like(qr{Your whole block list is in Manage Account}, '... points at Manage Account instead');

# --- signed in as the link's account: the whole list ---
$t->get_ok('/t/owner')
  ->content_like(qr{<section id="add-section">},               'the add section, shown')
  ->content_like(qr{<div class="cand-row" data-addr="shop1\@alice\.example"><label class="check"><input type="checkbox" name="block" value="shop1\@alice\.example" checked>},
                 '... with what is not blocked yet, ticked')
  ->content_like(qr{<div class="cand-row hide" data-addr="&quot;&gt;&lt;script[^"]*"><label class="check"><input type="checkbox" name="block" value="[^"]*" disabled>},
                 '... and what is, hidden and left out of the form (unblocking it brings it back)')
  ->content_like(qr{the address<span id="add-es"></span> below},  '... counting only what it shows: one address')
  ->content_like(qr{id="bl-list" class="blocklist" data-token="$token" data-csrf="[0-9a-f]{40}"},
                 'the block list, with what an unblock sends back')
  ->content_like(qr{<li data-addr="a-first\@x\.example"><span class="bl-addr">a-first\@x\.example</span></li>}, '... one entry per address')
  ->content_like(qr{<div class="modal" id="bl-confirm" role="dialog" aria-modal="true"}, 'the unblock question, in the theme\'s modal')
  ->content_like(qr{Unblock this address\?},                   '... asking first')
  ->content_like(qr{data-modal-close>Cancel</button>\s*<button type="button" class="btn btn-primary" id="bl-confirm-yes">Unblock</button>},
                 '... Cancel first (it gets the focus), then Unblock')
  ->content_like(qr{id="bl-sort"[^>]*>Sort: A &rarr; Z<},      'the sort button, starting at A to Z')
  ->content_like(qr{id="bl-filter"},                           'the filter box')
  ->content_like(qr{3 characters},                             '... which says when it starts')
  ->content_like(qr{id="bl-count"[^>]*>3 addresses<},         'the count')
  ->content_like(qr{var BlockList = \(function},               'the script is inline')
  ->content_like(qr{BlockList\.wire\(document\);},             '... and wired up')
  ->content_unlike(qr{href="/login},                           'no sign-in button once signed in');
like($t->tx->res->body, qr{a-first.*B-second}s, 'the list keeps the order it was given (the controller sorts it)');

$t->get_ok('/t/owner-done')
  ->content_like(qr{<section id="add-section" class="hide">}, 'everything already blocked: the add section is hidden')
  ->content_like(qr{class="cand-row hide"[^>]*><label class="check"><input type="checkbox" name="block" value="shop1\@alice\.example" disabled>},
                 '... its row too, ready to come back if that address is unblocked')
  ->content_like(qr{id="add-done" class="banner banner--ok"><span>Everything this message was sent to is already on your block list}, '... and it says so');
$t->get_ok('/t/owner-empty')
  ->content_like(qr{id="bl-none" class="text-muted">Your block list is empty\.}, 'an empty list says so');
$t->get_ok('/t/owner-error')
  ->content_like(qr{couldn't be loaded just now}, 'a list that cannot be read says so')
  ->content_unlike(qr{id="bl-list"},             '... and draws no list')
  ->content_unlike(qr{id="bl-confirm"},          '... nor anything to unblock with')
  ->content_like(qr{<section id="add-section">.*value="shop1\@alice\.example" checked}s, '... but the add section still works');

# --- the regression: a link that covers two accounts ---
$t->get_ok('/t/several')
  ->content_unlike(qr{secret-bcc},               'signed out: the other account\'s (Bcc\'d) address is not on the page')
  ->content_unlike(qr{shop1\@alice},             '... nor this one: nothing until you sign in')
  ->content_unlike(qr{id="blockform"},           '... no form to block anything with')
  ->content_like(qr{more than one account},      '... it says why')
  ->content_like(qr{href="/login\?next=},        '... and offers a sign-in');
$t->get_ok('/t/several-alice')
  ->content_like(qr{value="shop1\@alice\.example"}, 'signed in as alice: her address')
  ->content_unlike(qr{secret-bcc},                  '... and NOT bob\'s');
$t->get_ok('/t/several-other')
  ->content_unlike(qr{secret-bcc|shop1\@alice}, 'signed in as neither: no addresses')
  ->content_like(qr{isn't one of them},        '... and it says so');
$t->get_ok('/t/link-other')
  ->content_like(qr{value="shop1\@alice\.example"}, 'one-account link, signed in as someone else: the link still blocks')
  ->content_like(qr{This link is for another account}, '... but the list is not theirs to see here')
  ->content_unlike(qr{id="bl-list"},                 '... and no list is drawn')
  ->content_unlike(qr{data-csrf=|id="bl-confirm"},   '... nor anything to unblock with');

# --- an account's main address ---
$t->get_ok('/t/main')
  ->content_unlike(qr{name="block" value="alice\@example\.test"}, 'the main address is not a checkbox')
  ->content_like(qr{your account's main address},                 '... the page says why')
  ->content_like(qr{name="block" value="shop1\@alice\.example"},  '... the others still are');

# --- escaping ---
for my $path ('/t/link', '/t/owner') {
    $t->get_ok($path)
      ->content_unlike(qr{<script>alert\('xss'\)</script>}, "$path: an address cannot inject markup")
      ->content_like(qr{&lt;script&gt;},                    "$path: it is escaped, not dropped");
}

# The logo links to "/": that must lead somewhere, not to a 404.
$t->get_ok('/')->status_is(302)->header_is(Location => 'https://mailmasker.org/');

# No sso: block, so the sign-in routes go home instead of failing.
$t->get_ok('/login')->status_is(302)->header_is(Location => '/');
$t->get_ok('/oauth/callback?code=x&state=y')->status_is(302)->header_is(Location => '/');

done_testing;
