use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";

# The plugin's job is making the shared partials SAFE to include anywhere --
# including on a page that never thought about them (drive's login page is
# exactly that case, and it is why these are helpers rather than stash values
# populated by a hook: a helper resolves when the template asks, so it can
# never be read "too early" and can never be missing).
$ENV{HOMELAB_WEBTHEME_HOME} = "$FindBin::Bin/..";

use Mojolicious::Lite;
plugin 'Homelab::WebTheme' => {
    app_name    => 'Test App',
    user_email  => sub { $_[0]->param('who') },
    signout_url => '/bye',
};
# render through a TEMPLATE, which is how the partials are actually used
get '/vals' => sub { $_[0]->render(inline =>
    '<%= theme_base %>|<%= homelab_app_name %>|<%= homelab_user_email %>|<%= homelab_signout_url %>') };
get '/head'   => sub { $_[0]->render(inline => '%= include "homelab/head"') };
get '/header' => sub { $_[0]->render(inline => '%= include "homelab/header"') };
get '/footer' => sub { $_[0]->render(inline => '%= include "homelab/footer"') };
get '/override' => sub { $_[0]->stash(app_name => 'Overridden'); $_[0]->render(inline => '<%= homelab_app_name %>') };
# A SECOND app registering the plugin with its own dropdown links -- the case
# drive needs (it must not link to itself, and its account URL is configured).
{
    package Homelab::WebTheme::Test::Custom;
    use Mojo::Base 'Mojolicious', -signatures;
    sub startup ($self) {
        $self->plugin('Homelab::WebTheme' => {
            app_name   => 'Custom',
            user_email => sub ($c) { 'who@test.example' },
            menu_links => [ { href => 'https://acct.test/', label => 'My stuff' } ],
        });
        $self->routes->get('/header' => sub ($c) { $c->render(inline => '%= include "homelab/header"') });
        $self->routes->get('/empty'  => sub ($c) {
            $c->stash(menu_links => []);
            $c->render(inline => '%= include "homelab/header"');
        });
    }
}

my $t = Test::Mojo->new;

$t->get_ok('/vals')->status_is(200)
  ->content_like(qr{\A\Qhttps://static.mailmasker.org/theme/v1|Test App||/bye\E\s*\z},
      'defaults resolve; unresolvable user_email is empty string, never undef');
$t->get_ok('/vals?who=a@b.test')->status_is(200)
  ->content_like(qr{\|a\@b\.test\|}, 'user_email comes from the configured resolver');
$t->get_ok('/override')->content_like(qr{\AOverridden\s*\z}, 'stash overrides the configured default');

# --- the partials actually render ---
$t->get_ok('/head')->status_is(200)
  ->content_like(qr{static\.mailmasker\.org/theme/v1/theme\.css}, 'head links the remote stylesheet')
  ->content_like(qr{<link rel="shortcut icon" href="/favicon\.ico">}, 'head links /favicon.ico too (Safari ignores SVG icons; #100)')
  ->content_like(qr{preconnect}, 'fonts are preconnected (not @import-ed, which chains blocking round trips)');

# the account menu appears ONLY when there is a signed-in address
$t->get_ok('/header')->status_is(200)
  ->content_unlike(qr{profile-btn}, 'no account menu when nobody is signed in (the login-page case)')
  ->content_like(qr{topbar__logo}, 'logo still renders when signed out');
$t->get_ok('/header?who=zoe@example.test')->status_is(200)
  ->content_like(qr{profile-btn}, 'account menu appears when signed in')
  ->content_like(qr{data-menu="homelab-account-menu"}, 'trigger is wired to the panel id')
  ->content_unlike(qr{href="https://search\.mailmasker\.org/">Search<}, 'the dropdown no longer lists the sites (the launcher does, #94)')
  ->content_like(qr{class="menu-item" role="menuitem" href="https://myaccount\.mailmasker\.org/">Manage your account<}, 'the dropdown keeps the account page')
  ->content_like(qr{<span class="avatar" aria-hidden="true">Z</span>}, 'avatar shows the uppercased initial')
  ->content_like(qr{<form method="post" action="/bye">}, 'sign-out POSTs (a GET sign-out is prefetchable / CSRF-able)')
  ->content_unlike(qr{<a[^>]*href="/bye"}, 'sign-out is not a plain link');

$t->get_ok('/footer')->status_is(200)
  ->content_like(qr{Silver Linings}, 'footer credits Silver Linings')
  ->content_like(qr{shell\.js}, 'footer loads the shell script');

# --- a resolver that DIES must not take the page down ---
{
    package TestDies;
    use Mojo::Base 'Mojolicious', -signatures;
    sub startup ($self) {
        $self->plugin('Homelab::WebTheme' => { user_email => sub { die "no session\n" } });
        $self->routes->get('/' => sub { $_[0]->render(inline => 'ok:<%= homelab_user_email %>') });
    }
}
Test::Mojo->new('TestDies')->get_ok('/')->status_is(200)
  ->content_like(qr{\Aok:\s*\z}, 'a dying resolver degrades to empty, it does not 500');

# --- trailing slash normalised so partials can concatenate safely ---
{
    package TestSlash;
    use Mojo::Base 'Mojolicious', -signatures;
    sub startup ($self) {
        $self->plugin('Homelab::WebTheme' => { theme_base => 'https://example.test/theme/v9/' });
        $self->routes->get('/' => sub { $_[0]->render(inline => '<%= theme_base %>') });
    }
}
Test::Mojo->new('TestSlash')->get_ok('/')->content_like(qr{\A\Qhttps://example.test/theme/v9\E\s*\z},
    'a trailing slash is stripped');

# --- the .fade-in trap must not reach the shared partials ---
my $hdr = do { open(my $fh,'<',"$FindBin::Bin/../templates/homelab/header.html.ep") or die $!; local $/; <$fh> };
unlike($hdr, qr/\bfade-in\b/, 'header does not use .fade-in (it needs JS or content stays invisible)');


# --- configurable dropdown links ---
my $tc = Test::Mojo->new('Homelab::WebTheme::Test::Custom');
$tc->get_ok('/header')->status_is(200)
  ->content_like(qr{href="https://acct\.test/">My stuff<}, 'configured menu_links are used')
  ->content_unlike(qr{class="menu-item" role="menuitem" href="https://myaccount\.mailmasker\.org/"}, 'the default dropdown links are replaced, not appended (the launcher still has the Account tile)')
  ->content_like(qr{class="menu-sep"},                     'separator still divides links from sign-out');
# An app with no cross-app links at all must not render a dangling separator.
$tc->get_ok('/empty')->status_is(200)
  ->content_unlike(qr{class="menu-sep"}, 'no separator when there are no links')
  ->content_like(qr{Sign out},           'sign-out survives an empty link list');

# --- the default dropdown lists Calendar after Search (#74) and has no Settings line unless asked (#77) ---
$t->get_ok('/header?who=a@b.test')->status_is(200)
  ->content_unlike(qr{href="https://calendar\.mailmasker\.org/">Calendar</a>\s*<a class="menu-item"}s, 'the dropdown has no site links any more')
  ->content_unlike(qr{>Settings<}, 'no Settings line when the app has no settings page');

# --- the app launcher (#94): signed in only, every site alphabetical, with icons ---
$t->get_ok('/header')->status_is(200)
  ->content_unlike(qr{homelab-app-launcher}, 'no launcher when nobody is signed in');
$t->get_ok('/header?who=zoe@example.test')->status_is(200)
  ->content_like(qr{<div class="launcher">\s*<button class="launcher-btn" type="button" data-menu="homelab-app-launcher"}, 'the dotted button, wired to its panel')
  ->content_like(qr{launcher-btn.*?<div class="profile">}s, '... left of the account button')
  ->content_like(qr{Account</span>.*?Calendar</span>.*?Drive</span>.*?Email</span>.*?Notes</span>.*?Search</span>}s, 'the six sites, alphabetical')
  ->content_like(qr{href="https://notes\.mailmasker\.org/"><svg class="launcher__icon"}, 'each tile has its icon')
  ->content_unlike(qr{class="menu-item" role="menuitem" href="https://drive\.mailmasker\.org/"}, 'Drive is in the launcher, not the dropdown');
{
    package Homelab::WebTheme::Test::Sites;
    use Mojo::Base 'Mojolicious', -signatures;
    sub startup ($self) {
        $self->plugin('Homelab::WebTheme' => {
            user_email => sub ($c) { 'who@test.example' },
            sites => [ { href => 'https://zed.test/', label => 'Zed', icon => 'nope' }, { href => 'https://alpha.test/', label => 'alpha' } ],
        });
        $self->routes->get('/header' => sub ($c) { $c->render(inline => '%= include "homelab/header"') });
    }
}
Test::Mojo->new('Homelab::WebTheme::Test::Sites')->get_ok('/header')->status_is(200)
  ->content_like(qr{alpha</span>.*?Zed</span>}s, 'a configured list is sorted, case ignored')
  ->content_unlike(qr{notes\.mailmasker\.org}, '... and replaces the default')
  ->content_like(qr{href="https://zed\.test/"><svg class="launcher__icon"[^>]*><circle cx="12" cy="12" r="8"/>}, 'an unknown icon name gets the generic icon');

# --- an app with a settings page gets "Settings" first, under the address ---
{
    package Homelab::WebTheme::Test::Settings;
    use Mojo::Base 'Mojolicious', -signatures;
    sub startup ($self) {
        $self->plugin('Homelab::WebTheme' => {
            app_name => 'With settings', user_email => sub ($c) { 'who@test.example' }, settings_url => '/settings',
        });
        $self->routes->get('/header' => sub ($c) { $c->render(inline => '%= include "homelab/header"') });
    }
}
my $ts = Test::Mojo->new('Homelab::WebTheme::Test::Settings');
$ts->get_ok('/header')->status_is(200)
  ->content_like(qr{class="menu-sub">Signed in</div>\s*</div>\s*<a class="menu-item" role="menuitem" href="/settings">Settings</a>\s*<div class="menu-sep"></div>}s,
      'Settings sits directly under the address, then a separator')
  ->content_like(qr{Settings</a>.*?Manage your account}s, '... before the cross-app links');

# --- /favicon.ico is the Silver Linings mark, not the framework's cloud (#100) ---
$t->get_ok('/favicon.ico')->status_is(200)
  ->header_like('Content-Type', qr{image/(?:x-icon|vnd\.microsoft\.icon)}, 'an icon')
  ->content_like(qr{\A\x00\x00\x01\x00}, '... in ICO form');
isnt length($t->tx->res->body), 15086, "... not Mojolicious's own 15,086-byte favicon";
is length($t->tx->res->body), -s "$ENV{HOMELAB_WEBTHEME_HOME}/public/favicon.ico", '... the one the package ships';

done_testing;
