use Mojo::Base -strict;
use Test::More;
use Mojo::File qw(path);

# Guards on the SHIPPED unit files. Both bugs asserted here were live, both
# were silent, and both had the same shape: the certificate lands correctly on
# disk and nothing ever looks at it again.
#
#  1. A timer whose only periodic trigger is OnUnitActiveSec cannot re-arm if
#     the service it triggers never goes inactive (Type=oneshot +
#     RemainAfterExit=yes stays "active (exited)" forever). systemd reported
#     Trigger: n/a and NextElapseUSecMonotonic=infinity -- it ran once at boot
#     and never again, so a renewal published to the store would never be
#     picked up and the certificate would expire in service.
#  2. A blocking `systemctl reload` inside a unit ordered Before= that same
#     service SELF-DEADLOCKS and is killed at TimeoutStartSec, leaving the new
#     certificate on disk with the service never told about it.

my $svc_file   = path(__FILE__)->dirname->sibling('systemd', 'homelab-certsync.service');
my $timer_file = path(__FILE__)->dirname->sibling('systemd', 'homelab-certsync.timer');
ok(-f $svc_file,   'service unit ships');
ok(-f $timer_file, 'timer unit ships');

my $svc   = $svc_file->slurp;
my $timer = $timer_file->slurp;

# Strip comments -- these files carry long explanatory ones that would
# otherwise satisfy a naive directive match.
my $strip = sub { join "\n", grep { !/^\s*[#;]/ } split /\n/, shift };
my $svc_d   = $strip->($svc);
my $timer_d = $strip->($timer);

# --- (1) the timer must be able to fire more than once ---
my $remains      = $svc_d   =~ /^\s*RemainAfterExit\s*=\s*(?:yes|true|1|on)\s*$/mi;
my $has_calendar = $timer_d =~ /^\s*OnCalendar\s*=\s*\S/mi;
my $has_active   = $timer_d =~ /^\s*OnUnitActiveSec\s*=\s*\S/mi;
my $has_inactive = $timer_d =~ /^\s*OnUnitInactiveSec\s*=\s*\S/mi;

ok($has_calendar || $has_active || $has_inactive, 'the timer has a periodic trigger at all');
ok(!($remains && !$has_calendar && !$has_inactive),
    'a RemainAfterExit service is not paired with an OnUnitActiveSec-only timer (it could never re-arm)');
ok($has_calendar, 'the periodic trigger is absolute (OnCalendar), so it re-arms regardless of unit state');
like($timer_d, qr/^\s*Persistent\s*=\s*(?:yes|true|1|on)\s*$/mi,
    'Persistent=yes, so a host powered off past a window catches up -- the normal state for a standby edge');

# --- (2) the reload must not self-deadlock against the Before= ordering ---
like($svc_d, qr/^\s*Before\s*=.*\bnginx\.service\b/mi,
    'ordered before nginx so the cert on disk is current from the first connection');
# Comments stripped first -- this script's own comments explain the deadlock
# at length, and matching those instead of the code would make the assertion
# pass no matter what the code does.
my $script = join "\n",
    grep { !/^\s*#/ }
    split /\n/, path(__FILE__)->dirname->sibling('script', 'homelab-certsync')->slurp;
my @reloads = $script =~ /(systemctl'?,?\s*'?reload'?[^\n]*)/g;
ok(scalar(@reloads), 'the sync script does reload the consuming service');
for my $r (@reloads) {
    like($r, qr/--no-block/,
        "reload is --no-block (a blocking reload self-deadlocks against Before=): $r");
}

# --- the script must never let an unreachable store block a service start ---
like($svc_d, qr/^\s*TimeoutStartSec\s*=\s*\d/mi, 'the boot run is bounded');

done_testing;
