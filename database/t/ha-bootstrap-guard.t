use strict;
use warnings;
use Test::More;
use FindBin;

# Guards the two checks that stop homelab-database-ha from destroying a live
# PostgreSQL cluster during a routine upgrade.
#
# THE INCIDENT THIS PREVENTS (found 2026-10-28, before it fired). The HA
# bootstrap is destructive by design: it unconditionally does
# `rm -rf /var/lib/etcd/...` (the DCS holding cluster membership and the
# leader key) and, with --wipe-existing-cluster, `pg_dropcluster` on the data
# directory. debian/homelab-database-ha.postinst called it on EVERY
# `configure` -- which includes every routine upgrade -- and all three
# production database nodes were still carrying `wipe_existing: true` in
# debconf from their original greenfield install, because nothing reset it
# after the bootstrap succeeded. A plain
# `apt upgrade homelab-database-ha` on prod-homelab06/07/08 would have wiped
# etcd and dropped the live cluster. Nothing in the path warned.
#
# These assertions are about ORDER as much as presence: a guard that sits
# after the `rm -rf` is no guard at all.

my $root = "$FindBin::Bin/..";
my $boot = "$root/scripts/ha-bootstrap.sh";
my $post = "$root/debian/homelab-database-ha.postinst";

ok(-f $boot, 'ha-bootstrap.sh is where the package expects it');
ok(-f $post, 'homelab-database-ha.postinst is present');

my $b = do { open my $fh, '<', $boot or die $!; local $/; <$fh> };
my $p = do { open my $fh, '<', $post or die $!; local $/; <$fh> };

# --- the bootstrap script's live-cluster guard ---------------------------
like $b, qr/is-active --quiet patroni/, 'the bootstrap checks whether patroni is already running';
like $b, qr/refusing to re-bootstrap/,  'and says so in words an operator will understand';
like $b, qr/--rebootstrap-live-cluster/, 'with an explicit opt-in flag to override it';

# Skip comment lines deliberately: this file's own explanatory comments name
# `rm -rf /var/lib/etcd` and `pg_dropcluster`, and so do the ones added above
# the guard in the script. Matching those instead of the real statements made
# the ordering assertions compare a comment against the guard and fail on a
# correctly-placed guard -- a false alarm on exactly the check that matters.
sub line_of {
    my ($text, $re, $what) = @_;
    my @l = split /\n/, $text;
    for my $i (0 .. $#l) {
        next if $l[$i] =~ /^\s*#/;
        return $i + 1 if $l[$i] =~ $re;
    }
    die "could not find $what";
}

my $guard   = line_of($b, qr/is-active --quiet patroni/,        'the patroni guard');
my $etcd    = line_of($b, qr/rm -rf \s*\/var\/lib\/etcd/,       'the etcd rm -rf');
my $dropcl  = line_of($b, qr/pg_dropcluster/,                   'the pg_dropcluster call');

cmp_ok $guard, '<', $etcd,   "the guard runs BEFORE rm -rf /var/lib/etcd (guard=$guard, rm=$etcd)";
cmp_ok $guard, '<', $dropcl, "the guard runs BEFORE pg_dropcluster (guard=$guard, drop=$dropcl)";

# The guard must also sit after the root check it depends on, or it never runs.
my $rootchk = line_of($b, qr/must run as root/, 'the root check');
cmp_ok $rootchk, '<', $guard, 'the root check still precedes the guard';

# --- postinst: never bootstrap on an upgrade -----------------------------
like $p, qr/OLDVER="\$2"/, 'postinst captures $2 (the previously-configured version)';

# $2 must be read BEFORE the `set --` that replaces the positional parameters
# with the bootstrap's own argv. Read afterwards it is --members' VALUE, which
# is always non-empty -- so the "is this an upgrade?" test was always true and
# the bootstrap got skipped even on a FIRST install. Caught on a real upgrade:
# the skip message printed the members string where a version belonged.
my $capture = line_of($p, qr/OLDVER="\$2"/, 'the OLDVER capture');
my $setargs = line_of($p, qr/^\s*set -- /,  'the first `set --`');
cmp_ok $capture, '<', $setargs,
    "\$2 is captured before `set --` clobbers it (capture=$capture, set=$setargs)";
unlike $p, qr/\[ -n "\$2" \]/,
    'the upgrade check does not read a bare $2 (it would be --members by then)';
like $p, qr/not re-running the HA bootstrap/, 'and says what it skipped';

my $upg  = line_of($p, qr/\[ -n "\$OLDVER" \]/,              'the upgrade check');
my $call = line_of($p, qr/homelab-database-ha-bootstrap/, 'the bootstrap invocation');
cmp_ok $upg, '<', $call, "the upgrade check precedes the bootstrap call (check=$upg, call=$call)";

# The wipe flag is still plumbed (a deliberate first-install option) but must
# never be the only thing standing between an upgrade and data loss.
like $p, qr/--wipe-existing-cluster/, 'the wipe option is still available for a genuine rebuild';

done_testing();
