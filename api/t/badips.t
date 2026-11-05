use strict;
use warnings;
use Test::More;
use lib 'lib';
use Homelab::API::BadIPs qw(parse_address);

# Only single addresses are banned or unbanned through the api; whatever
# arrives in the URL is normalised or refused before it reaches SQL.
is(parse_address('203.0.113.7'), '203.0.113.7', 'plain IPv4');
is(parse_address('2001:DB8:0:0:0:0:0:1'), '2001:db8::1', 'IPv6 is canonicalised');
is(parse_address('::1'), '::1', 'short IPv6');
for my $bad ('', '1.2.3', '1.2.3.4.5', '256.1.1.1', '1.2.3.0/24', 'abc', '1.2.3.4;drop', "1.2.3.4\n", 'g::1', ' 1.2.3.4') {
    is(parse_address($bad), undef, "refused: '" . ($bad =~ s/\n/\\n/r) . "'");
}
is(parse_address(undef), undef, 'undef');
is(parse_address([]), undef, 'a reference');
is(parse_address('1' x 46), undef, 'too long');

done_testing;
