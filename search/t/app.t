use strict;
use warnings;
use Test::More;
use lib 'lib';

# An END-TO-END route test with auth stubbed. This exists because of a bug it
# would have caught and I shipped instead: the rank expression's placeholder
# sits in the SELECT list, which precedes WHERE, but its bind was appended
# last -- so the tsquery parameter got the account id and the bigint
# account_id column got the search term. Every signed-in search 500'd with
#   invalid input syntax for type bigint: "invoice"
# while the unauthenticated checks I had all passed, because none of them
# reaches a query.
#
# "I cannot test a signed-in session without a password" was wrong: the
# session is behind one function, and stubbing it is three lines.
#
# Needs a real database, so it skips where there is none (CI). Run it on a
# search host:
#   sudo -u vmail -g vmail HOMELAB_SEARCH_CONFIG=/etc/homelab/search/config.yml \
#        HOMELAB_SEARCH_HOME=/usr/share/homelab-search prove -Ilib t/app.t
BEGIN {
    plan skip_all => 'set HOMELAB_SEARCH_CONFIG to run (needs a live database)'
        unless $ENV{HOMELAB_SEARCH_CONFIG} && -r $ENV{HOMELAB_SEARCH_CONFIG};
}

use Test::Mojo;
require Homelab::Search::App;

my $EMAIL = $ENV{HOMELAB_SEARCH_TEST_EMAIL} // 'permittivity@mailmasker.org';
{
    no warnings 'redefine';
    *Homelab::Search::App::Controller::Search::_current_auth = sub { return ($EMAIL, 'stub-jwt') };
}

my $t = Test::Mojo->new('Homelab::Search::App');

# The empty search page must render before anything is typed.
$t->get_ok('/')->status_is(200)->content_like(qr/Search your email and files/);

# A real query across both sources -- the case that was broken.
# ASCII-only assertions on purpose: the page uses an em-dash in those
# headings, and matching a literal multi-byte character from a test file
# without `use utf8` compares bytes against decoded text and fails for
# reasons that have nothing to do with the app.
$t->get_ok('/?q=invoice')->status_is(200)
  ->content_like(qr/\bEmail\b/)
  ->content_like(qr/\bFiles\b/)
  ->content_like(qr/result/);

# Each source on its own, and each filter, because each adds binds in a
# different order and the ordering is the thing that broke.
$t->get_ok('/?q=invoice&source=mail')->status_is(200);
$t->get_ok('/?q=invoice&source=drive')->status_is(200);
$t->get_ok('/?person=amazon')->status_is(200);
$t->get_ok('/?q=invoice&person=amazon&from=2026-01-01&to=2026-12-31')->status_is(200);
$t->get_ok('/?q=report&mime=text')->status_is(200);
$t->get_ok('/?q=report&in_trash=1')->status_is(200);
$t->get_ok('/?q=x&has_attachments=1&mailbox=INBOX')->status_is(200);
$t->get_ok('/?from=2026-01-01')->status_is(200);
$t->get_ok('/?q=invoice&min_size=10&max_size=100000')->status_is(200);

# Junk input must not 500: websearch_to_tsquery tolerates it, and the limit
# and offset are clamped rather than trusted.
$t->get_ok('/?q=' . '"unbalanced')->status_is(200);
$t->get_ok('/?q=a&limit=999999&offset=-5')->status_is(200);
$t->get_ok('/?from=not-a-date&to=also-not')->status_is(200);

# JSON for homelab-cli.
$t->get_ok('/api/v1/search?q=invoice')->status_is(200)
  ->json_has('/mail')->json_has('/drive');

$t->get_ok('/health')->status_is(200);

done_testing();
