use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# An apex + wildcard certificate (7redlines.org and *.7redlines.org) puts two
# DNS-01 challenges at the ONE name _acme-challenge.7redlines.org. certbot runs
# the auth hook once per name and validates both afterwards, so both TXT
# values must be in the zone at the same time. The endpoint writes with a
# PowerDNS REPLACE, so it must send the union of what is there and what is
# new -- this is the function that builds that union (2026-11-26, found on the
# first wildcard lineage; the hook's comment had promised this behaviour).
require Homelab::DomainAdmin::App::Controller::Dns;
my $m = \&Homelab::DomainAdmin::App::Controller::Dns::_merge_challenge_values;

is_deeply($m->([], ['"aaa"']), ['"aaa"'], 'first challenge at a name: just the new value');
is_deeply($m->(['"aaa"'], ['"bbb"']), ['"aaa"', '"bbb"'],
    'second challenge at the same name KEEPS the first (apex + wildcard)');
is_deeply($m->(['"aaa"', '"bbb"'], ['"ccc"']), ['"aaa"', '"bbb"', '"ccc"'], 'a third is added too');
is_deeply($m->(['"aaa"'], ['"aaa"']), ['"aaa"'], 'a retry republishing the same token does not duplicate it');
is_deeply($m->(['"aaa"', '"bbb"'], ['"bbb"', '"ccc"']), ['"aaa"', '"bbb"', '"ccc"'], 'overlap is deduplicated, order kept');
is_deeply($m->([], ['"x"', '"y"']), ['"x"', '"y"'], 'several new values at once are all kept');

done_testing;
