use v5.36;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

# The root half of the DKIM key hand-off (#68), exercised unprivileged in
# a temp tree (HOMELAB_OPENDKIM_INSTALL_TEST_ROOT skips chown). What is
# tested is the logic that matters for a daemon that may reload at any
# moment: keys land before the tables that name them, a table naming a
# missing key is refused, stale keys go only when something is staged,
# and nothing but well-named regular files is ever copied.

plan skip_all => 'runs unprivileged only' if $> == 0;

my $script = "$FindBin::Bin/../sbin/homelab-opendkim-install";
ok -x $script, 'installer is executable' or BAIL_OUT("no $script");

my $root  = tempdir(CLEANUP => 1);
my $stage = "$root/stage";
my $live  = "$root/live";
make_path("$stage/keys/example.org", "$live");

sub write_file ($p, $c, $mode = 0600) {
    open(my $fh, '>', $p) or die "$p: $!";
    print $fh $c;
    close $fh;
    chmod $mode, $p;
}
sub slurp ($p) { open(my $fh, '<', $p) or return undef; local $/; <$fh> }
sub mode ($p)  { sprintf '%04o', (stat $p)[2] & 07777 }
sub run_installer {
    local $ENV{HOMELAB_OPENDKIM_INSTALL_TEST_ROOT} = $root;
    my $out = `"$script" 2>&1`;
    return ($? >> 8, $out);
}

write_file("$stage/keys/example.org/20260101a.private", "KEY-A\n");
write_file("$stage/keys/example.org/20260101a.txt",     "public key text\n", 0644);
write_file("$stage/KeyTable",     "20260101a._domainkey.example.org example.org:20260101a:$live/keys/example.org/20260101a.private\n", 0640);
write_file("$stage/SigningTable", "example.org 20260101a._domainkey.example.org\n", 0640);

subtest 'first install mirrors keys and tables' => sub {
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0' or diag $out;
    like $out, qr/3 file\(s\) installed, 0 unchanged, 0 stale/, 'summary: key + two tables installed';
    is slurp("$live/keys/example.org/20260101a.private"), "KEY-A\n", 'key content mirrored';
    is mode("$live/keys/example.org/20260101a.private"), '0600', 'key is 0600';
    is mode("$live/keys/example.org"), '0700', 'domain dir is 0700';
    is mode("$live/keys"), '0700', 'keys dir is 0700';
    ok !-e "$live/keys/example.org/20260101a.txt", 'the .txt companion is not mirrored';
    is slurp("$live/KeyTable"), slurp("$stage/KeyTable"), 'KeyTable mirrored';
    is mode("$live/KeyTable"), '0640', 'KeyTable is 0640';
    is mode("$live/SigningTable"), '0640', 'SigningTable is 0640';
    unlike $out, qr/KEY-A/, 'no key material in the output';
};

subtest 'a second run changes nothing' => sub {
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0';
    like $out, qr/0 file\(s\) installed, 3 unchanged/, 'everything already right';
};

subtest 'a changed key and a stale live key' => sub {
    write_file("$stage/keys/example.org/20260101a.private", "KEY-A2\n");
    make_path("$live/keys/old.example");
    write_file("$live/keys/old.example/20250101a.private", "OLD\n");
    write_file("$live/keys/old.example/20250101a.txt", "old text\n", 0644);
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0' or diag $out;
    is slurp("$live/keys/example.org/20260101a.private"), "KEY-A2\n", 'changed key re-installed';
    like $out, qr/1 file\(s\) installed, 2 unchanged, 1 stale key\(s\) removed/, 'summary counts the stale key';
    ok !-e "$live/keys/old.example/20250101a.private", 'stale key removed';
    ok !-e "$live/keys/old.example", 'its empty directory removed';
};

subtest 'a wrong mode on a live key is corrected' => sub {
    chmod 0640, "$live/keys/example.org/20260101a.private";
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0';
    is mode("$live/keys/example.org/20260101a.private"), '0600', 'back to 0600';
    like $out, qr/1 file\(s\) installed/, 'counted as installed (re-put)';
};

subtest 'a KeyTable naming a key that is not staged is refused' => sub {
    my $good = slurp("$stage/KeyTable");
    write_file("$stage/KeyTable", $good . "x._domainkey.example.org example.org:x:$live/keys/example.org/x.private\n", 0640);
    my ($rc, $out) = run_installer();
    isnt $rc, 0, 'non-zero exit';
    like $out, qr/refusing to install the tables/, 'says why';
    is slurp("$live/KeyTable"), $good, 'live KeyTable untouched';
    write_file("$stage/KeyTable", $good, 0640);
};

subtest 'odd names, symlinks and oversized files are skipped' => sub {
    make_path("$stage/keys/bad name");
    write_file("$stage/keys/bad name/20260101a.private", "X\n");
    symlink("$stage/KeyTable", "$stage/keys/example.org/link.private");
    write_file("$stage/keys/example.org/big.private", "B" x (17 * 1024));
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0 (skips are not failures)' or diag $out;
    like $out, qr/skipped/, 'summary mentions skips';
    ok !-e "$live/keys/bad name", 'odd directory name not mirrored';
    ok !-e "$live/keys/example.org/link.private", 'symlink not mirrored';
    ok !-e "$live/keys/example.org/big.private", 'oversized file not mirrored';
    unlink "$stage/keys/example.org/link.private", "$stage/keys/example.org/big.private", "$stage/keys/bad name/20260101a.private";
    rmdir "$stage/keys/bad name";
};

subtest 'an empty staging tree removes nothing' => sub {
    unlink "$stage/keys/example.org/20260101a.private";
    write_file("$stage/KeyTable", '', 0640);
    write_file("$stage/SigningTable", '', 0640);
    my ($rc, $out) = run_installer();
    is $rc, 0, 'exit 0' or diag $out;
    ok -e "$live/keys/example.org/20260101a.private", 'live key kept (nothing staged = do not sweep)';
    is slurp("$live/KeyTable"), '', 'tables may still go empty (nothing to sign with is a valid state)';
};

subtest 'refuses to run outside test mode as a normal user' => sub {
    my $out = `"$script" 2>&1`;
    isnt $? >> 8, 0, 'non-zero exit';
    like $out, qr/must run as root/, 'says so';
};

done_testing();
