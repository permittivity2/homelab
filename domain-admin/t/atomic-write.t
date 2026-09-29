use v5.36;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../common/lib";

BEGIN {
    plan skip_all => 'Mojolicious not installed'
        unless eval { require Mojolicious; 1 };
}

use File::Temp qw(tempdir);
require Homelab::DomainAdmin::App::Controller::Dkim;
my $W = \&Homelab::DomainAdmin::App::Controller::Dkim::_atomic_write;

my $d = tempdir(CLEANUP => 1);
my $p = "$d/k.private";
sub mode ($f) { sprintf '%04o', (stat $f)[2] & 07777 }

is($W->($p, "KEY-v1\n", 0640), 1, 'create reports changed=1');
is(mode($p), '0640', 'created directly at 0640 -- no world-readable window');
is($W->($p, "KEY-v1\n", 0640), 0, 'identical content reports changed=0 (no needless rewrite/reload)');
is($W->($p, "KEY-v2\n", 0640), 1, 'new content reports changed=1');

open(my $fh, '<', $p); local $/; is(<$fh>, "KEY-v2\n", 'content updated atomically'); close $fh;

# A file left with loose perms by an older path must be corrected even
# when the content is unchanged (guards the "stale world-readable key
# persists forever" bug).
chmod 0644, $p;
is($W->($p, "KEY-v2\n", 0640), 0, 'unchanged content still reports 0');
is(mode($p), '0640', 'perms re-asserted to 0640 on a no-op write');

# No leftover temp files in the directory.
opendir(my $dh, $d); my @junk = grep { /\.tmp\./ } readdir $dh; closedir $dh;
is(scalar @junk, 0, 'no leftover .tmp files after writes');

done_testing;
