use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

# Unlike homelab-database's bootstrap-role.t, this needs no root/sudo and
# no live pgbouncer — the userlist add-or-replace logic is pure file
# manipulation, and `is_local_host($host)` matching our own hostname is
# enough to exercise the real run_local() path end-to-end. The
# `systemctl reload pgbouncer` call inside it will warn (no pgbouncer
# installed in a test environment) but that's non-fatal by design — the
# script only warns, never dies, on a reload failure.

my $script = 'script/homelab-bootstrap-pgbouncer-entry';
my (undef, $userlist) = tempfile(UNLINK => 1);
unlink($userlist);    # script should create it fresh
chomp(my $hostname = `hostname`);

sub run_bootstrap {
    my (%opts) = @_;
    # List-form system(): no shell ever sees these arguments, so a `$`
    # inside the SCRAM secret (real ones always have one, as a
    # structural separator — e.g. "SCRAM-SHA-256$4096:salt$...") can't be
    # misread as a shell variable reference. This is exactly the bug an
    # earlier, sprintf-into-a-shell-string version of this test had.
    system(
        'perl', $script,
        '--role', $opts{role}, '--scram-secret', $opts{secret},
        '--pgbouncer-host', $hostname, '--userlist', $userlist,
    );
    return $? == 0;
}

ok(run_bootstrap(role => 'homelab_drive_runtime', secret => 'SCRAM-SHA-256$first-secret'), 'first registration succeeds');

open(my $fh, '<', $userlist) or die "cannot read $userlist: $!";
my @lines = <$fh>;
close($fh);
chomp @lines;
is(scalar @lines, 1, 'userlist has exactly one line after one registration');
is($lines[0], q{"homelab_drive_runtime" "SCRAM-SHA-256$first-secret"}, 'line format matches pgbouncer userlist.txt convention');

ok(run_bootstrap(role => 'homelab_sso_runtime', secret => 'SCRAM-SHA-256$second-secret'), 'second, different role registers alongside the first');
{
    open(my $fh2, '<', $userlist) or die "cannot read $userlist: $!";
    my @l = <$fh2>;
    close($fh2);
    is(scalar @l, 2, 'userlist now has two lines');
}

# The idempotency property this whole script exists for: re-registering
# the SAME role with a NEW secret (e.g. a credential rotation) replaces
# its line in place rather than appending a duplicate.
ok(run_bootstrap(role => 'homelab_drive_runtime', secret => 'SCRAM-SHA-256$rotated-secret'), 're-registering the same role (rotation) succeeds');
{
    open(my $fh3, '<', $userlist) or die "cannot read $userlist: $!";
    my @l = <$fh3>;
    close($fh3);
    chomp @l;
    is(scalar @l, 2, 'still exactly two lines after rotation — no duplicate appended');
    ok((grep { $_ eq q{"homelab_drive_runtime" "SCRAM-SHA-256$rotated-secret"} } @l), 'the rotated role now has its NEW secret');
    ok((grep { $_ eq q{"homelab_sso_runtime" "SCRAM-SHA-256$second-secret"} } @l), 'the other role is untouched by the rotation');
}

done_testing;
