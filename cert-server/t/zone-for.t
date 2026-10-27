use v5.36;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../common/lib";
use Homelab::CertServer::Util qw(zone_for);

my $cfg = { zones => ['mailmasker.org', 'forge.name', 'silverlinings.llc', 'thedude.vip'] };

is(zone_for($cfg, undef, 'mailmasker.org'),          'mailmasker.org',   'apex maps to its own zone');
is(zone_for($cfg, undef, 'mail.mailmasker.org'),     'mailmasker.org',   'a SAN name maps to its zone');
is(zone_for($cfg, undef, 'www.mailmasker.org'),      'mailmasker.org',   'www maps to its zone');
is(zone_for($cfg, undef, 'plex.forge.name'),         'forge.name',       'a different zone resolves');
is(zone_for($cfg, undef, 'projects.thedude.vip'),    'thedude.vip',      'a 2-label TLD-ish zone resolves');
is(zone_for($cfg, undef, 'www.silverlinings.llc'),   'silverlinings.llc','a .llc zone resolves');
is(zone_for($cfg, undef, 'nope.example.com'),        undef,              'an unmanaged name resolves to undef');
# a lookalike must NOT match: notmailmasker.org is not inside mailmasker.org
is(zone_for($cfg, undef, 'notmailmasker.org'),       undef,              'a lookalike suffix does not match');
# longest-suffix wins when zones nest
my $nested = { zones => ['mailmasker.org', 'sub.mailmasker.org'] };
is(zone_for($nested, undef, 'a.sub.mailmasker.org'), 'sub.mailmasker.org','longest suffix wins over the parent zone');
is(zone_for({ zones => [] }, undef, 'x.mailmasker.org'), undef,           'no configured zones -> undef, not a crash');

done_testing;
