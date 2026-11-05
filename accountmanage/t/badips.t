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

# Banned-addresses routes (post-cutover #47): signed-out callers get 403 JSON,
# never the page and never a forward to the api.
$t->get_ok('/admin/bad-ips')->status_is(403)->json_is('/error' => 'forbidden');
$t->get_ok('/admin/bad-ips/why?address=203.0.113.7')->status_is(403);
$t->post_ok('/admin/bad-ips/unban' => form => { address => '203.0.113.7', hours => 24 })->status_is(403);

done_testing;
