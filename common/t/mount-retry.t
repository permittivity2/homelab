use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File qw(path tempdir);

# homelab-mount-retry (post-cutover #41 H): what it starts, what it leaves
# alone, and when it stops acting. A fake systemctl first on PATH records
# every call and answers `show` from a table; mountinfo, uptime and the
# done-file are files in a temp dir.
my $dir  = tempdir;
my $bin  = $dir->child('bin')->make_path;
my $calls = $dir->child('calls');
my $states = $dir->child('states');
$bin->child('systemctl')->spew(<<"SH")->chmod(0755);
#!/bin/sh
echo "\$*" >> $calls
if [ "\$1" = show ]; then
  unit=\$(eval echo \\\${\$#})
  grep "^\$unit " $states | cut -d" " -f2- | tr " " "\\n"
fi
exit 0
SH
my $script = path("$FindBin::Bin/../script/homelab-mount-retry");
my $lists = $dir->child('lists')->make_path;
my $mi = $dir->child('mountinfo'); my $up = $dir->child('uptime'); my $done = $dir->child('done');
sub run_it ($uptime = 100) {
    $up->spew("$uptime.00 10.00\n");
    $calls->spew('');
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    local $ENV{HOMELAB_BOOT_MOUNTS_DIR} = "$lists";
    local $ENV{HOMELAB_MOUNTINFO} = "$mi";
    local $ENV{HOMELAB_UPTIME} = "$up";
    local $ENV{HOMELAB_MOUNT_RETRY_DONE} = "$done";
    my $out = `perl $script 2>&1`;
    my @c = grep { length } split /\n/, $calls->slurp;
    return ($out, [ grep { !/^show / } @c ]);
}
sub mountinfo (@mps) { $mi->spew(join '', map { "1 1 0:1 / $_ rw - nfs4 10.45.0.105:/x rw\n" } @mps) }
sub set_state ($unit, %p) { my %d = (ActiveState => 'inactive', ActiveEnterTimestampMonotonic => 0, UnitFileState => 'enabled', %p); $states->spew(($states->slurp // '') =~ s/^\Q$unit\E .*\n//mr . "$unit " . join(' ', map { "$_=$d{$_}" } sort keys %d) . "\n") }
$states->spew('');

# --- nothing to do without a list ---------------------------------------------
mountinfo();
my ($out, $c) = run_it;
is_deeply $c, [], 'no list, no action';

# --- the mount is missing: start its unit, nothing else --------------------
$lists->child('dovecot.list')->spew("# the mail store\n/var/mail/vhosts var-mail-vhosts.mount dovecot.service\n");
($out, $c) = run_it;
is_deeply $c, ['start --no-block -- var-mail-vhosts.mount'], 'an unmounted mountpoint starts its mount unit, with --no-block';
like $out, qr{/var/mail/vhosts is not mounted: starting var-mail-vhosts\.mount}, '... and says so';

# --- mounted, the service never ran this boot: start it ---------------------
mountinfo('/var/mail/vhosts');
set_state('dovecot.service');
($out, $c) = run_it;
is_deeply $c, ['start --no-block -- dovecot.service'], 'mounted + enabled + never active this boot = start the service';

# --- mounted, the service is active: nothing --------------------------------
set_state('dovecot.service', ActiveState => 'active', ActiveEnterTimestampMonotonic => 12345);
($out, $c) = run_it;
is_deeply $c, [], 'an active service is left alone';

# --- mounted, the service was active earlier and is stopped now: nothing -----
set_state('dovecot.service', ActiveState => 'inactive', ActiveEnterTimestampMonotonic => 12345);
($out, $c) = run_it;
is_deeply $c, [], 'a service that ran this boot and was stopped is someone\'s decision: left alone';

# --- disabled service: nothing ----------------------------------------------
set_state('dovecot.service', UnitFileState => 'disabled');
($out, $c) = run_it;
is_deeply $c, [], 'a disabled service is never started';

# --- two services on one mount, failed one counts as not active -------------
$lists->child('search.list')->spew("/srv/mail-ro srv-mail\\x2dro.mount homelab-search.service homelab-search-indexer.service\n");
mountinfo('/var/mail/vhosts', '/srv/mail-ro');
set_state('dovecot.service', ActiveState => 'active', ActiveEnterTimestampMonotonic => 5);
set_state('homelab-search.service', ActiveState => 'failed');
set_state('homelab-search-indexer.service', ActiveState => 'active', ActiveEnterTimestampMonotonic => 7);
($out, $c) = run_it;
is_deeply $c, ['start --no-block -- homelab-search.service'], 'a failed-never-active service is started; its active sibling is not';

# --- a mountpoint with a space, as mountinfo escapes it ----------------------
$lists->child('odd.list')->spew("/srv/my\\040share odd.mount odd.service\n");
$mi->spew(($mi->slurp) . "1 1 0:1 / /srv/my\\040share rw - nfs4 x rw\n");
set_state('odd.service', ActiveState => 'active', ActiveEnterTimestampMonotonic => 9);
($out, $c) = run_it;
is_deeply $c, ['start --no-block -- homelab-search.service'], 'a mountpoint with an escaped space is matched as mounted';

# --- a unit name with a backslash reaches systemctl untouched ----------------
# (0.1.39 built a shell command; sh turned \x2d into x2d and started nothing)
$lists->child('bs.list')->spew("/srv/bs srv-bs\\x2dro.mount bs.service\n");
($out, $c) = run_it;
is_deeply $c, ['start --no-block -- srv-bs\\x2dro.mount', 'start --no-block -- homelab-search.service'], 'the \\x2d in a mount unit name survives to systemctl';
$lists->child('bs.list')->remove;

# --- the window: at two hours it writes the done-file -----------------------
ok !-e $done, 'no done-file before two hours';
($out, $c) = run_it(7200);
ok -e $done, 'the done-file is written at 7200 s of uptime';
like $out, qr/done for this boot/, '... and it says so';

done_testing;
