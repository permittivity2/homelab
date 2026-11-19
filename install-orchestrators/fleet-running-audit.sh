#!/bin/bash
# ============================================================================
# Answer the question fleet-version-audit.sh cannot: is every node RUNNING what
# it should -- and nothing else?  (post-cutover #32)
#
#   ./fleet-running-audit.sh              # the whole fleet
#   ./fleet-running-audit.sh 39 40 41     # just these nodes
#   VERBOSE=1 ./fleet-running-audit.sh    # also list what IS fine
#   KEEP=DIR ./fleet-running-audit.sh     # keep the per-node snapshot (DIR/NN.txt)
#   ./fleet-running-audit.sh --from DIR   # judge a kept snapshot again, no ssh
#   ./fleet-running-audit.sh --selftest   # prove the rules on crafted snapshots
#
# Exit 0 = nothing to look at. Exit 1 = findings. Exit 2 = could not run.
# Read-only: it changes nothing anywhere.
#
# WHAT IT LOOKS FOR
#   MISSING     an installed homelab package (or a stock daemon one of them
#               depends on) whose enabled unit is not running; an agent
#               manifest whose unit is down or whose port has no listener;
#               a failed unit.  (A silently stopped service: the case nothing
#               else catches before an outage.)
#   UNEXPECTED  a daemon running that no installed homelab package needs --
#               prod-homelab39's stray pgbouncer, loopback-only or not; a
#               homelab unit running without its package; an exposed listener
#               nothing explains; a manifest for a package that is not there.
#   LEFTOVERS   (warnings) daemons masked where their package was removed or
#               is still installed; stock daemons installed where nothing
#               needs them; homelab packages removed but not purged.
#   DRIFT       a watched distro package at more than one version across the
#               nodes that have it (postfix was found at two).
#
# WHERE "EXPECTED" COMES FROM (the design question of #32)
#   Today: the homelab-* packages INSTALLED on the node, plus every package
#   they pull in (dpkg Depends and Recommends, followed through, Provides
#   resolved -- what apt installs by default), plus the agent's manifests in
#   /etc/homelab/services. So "installed" means
#   "should run" -- true until #31 makes every host install everything; then
#   only `expected_packages` below changes (read /etc/homelab/homelab.conf),
#   the rest of the rules stay. The manifests are checked, never trusted as
#   the source: a stray manifest is itself a finding.
#
# FALSE POSITIVES IT AVOIDS (each one was hit for real before this existed)
#   systemd-resolved on 127.0.0.53/.54:53 is on every host and is not a DNS
#   server; loopback-only listeners are not exposed, in both spellings
#   (127.0.0.1 and [::1]); the satellite postfix on every container listens on
#   loopback :25 for cron mail and is fine; netplan-configure and
#   systemd-networkd-wait-online are "failed" on every container (a Proxmox
#   quirk, no service behind them); glances is on every node by hand,
#   loopback only; the NFS client's kernel lockd holds random exposed ports
#   with no process behind them on the VMs that mount the NAS; a unit whose
#   Condition* failed (no IPMI in a VM) is not a stopped service.
# ============================================================================
set -uo pipefail

FIRST="${FIRST:-0}"; LAST="${LAST:-72}"     # node NN -> 10.20.2.(144+NN)
PAR="${PAR:-20}"
VERBOSE="${VERBOSE:-0}"
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }

# ---------------------------------------------------------------------------
# The collector: runs ON the node as root, prints one record per line. The
# same text feeds the classifier whether it came over ssh or from a kept
# snapshot, so a finding can always be reproduced from the files.
# ---------------------------------------------------------------------------
read -r -d '' COLLECT <<'COLLECT_EOF' || true
echo "#host|$(hostname)"
# every package: name|version|status|provides|depends|recommends (status: installed / config-files / not-installed;
# the " | " of an alternative becomes " ~ " so the record separator stays unambiguous)
dpkg-query -W -f='#pkg|${Package}|${Version}|${db:Status-Status}|${Provides}|${Depends}|${Recommends}\n' 2>/dev/null | sed 's/ | / ~ /g'
# every service/timer/socket unit: id|load|active|sub|unit-file-state|type|fragment path|remain-after-exit|condition result
units=$(systemctl list-units --all --no-legend --plain --type=service,timer,socket 2>/dev/null | awk '{print $1}')
[ -n "$units" ] && systemctl show -p Id,LoadState,ActiveState,SubState,UnitFileState,Type,FragmentPath,RemainAfterExit,ConditionResult $units 2>/dev/null \
  | awk -F= '
      /^Id=/{id=$2} /^LoadState=/{l=$2} /^ActiveState=/{a=$2} /^SubState=/{s=$2} /^UnitFileState=/{u=$2} /^Type=/{t=$2} /^FragmentPath=/{f=$2} /^RemainAfterExit=/{r=$2} /^ConditionResult=/{c=$2}
      /^$/{ if (id!="") print "#unit|"id"|"l"|"a"|"s"|"u"|"t"|"f"|"r"|"c; id=l=a=s=u=t=f=r=c="" }
      END{ if (id!="") print "#unit|"id"|"l"|"a"|"s"|"u"|"t"|"f"|"r"|"c }'
# masked unit files (a mask is a symlink in /etc; the unit may never have been loaded)
systemctl list-unit-files --state=masked --no-legend --plain 2>/dev/null | awk '{print "#masked|"$1}'
# which package owns each unit file: one fixed-string pass over dpkg's file lists
# (dpkg -S does the same scan but took 40+ s cold on the spinning pool)
paths=$(systemctl show -p FragmentPath $units 2>/dev/null | awk -F= '$2 ~ /^\/(usr\/)?lib\/systemd\/system\//{print $2}' | sort -u)
[ -n "$paths" ] && printf '%s\n' "$paths" | grep -H -F -x -f - /var/lib/dpkg/info/*.list 2>/dev/null \
  | sed 's#^/var/lib/dpkg/info/\([^:]*\)\.list:\(.*\)$#\2|\1#' | sed 's/:[a-z0-9]*$//' | awk -F'|' '{print "#owner|"$1"|"$2}'
# listening sockets: proto|addr|port|comm|unit|pid (the FIRST pid of the users list -- systemd, pid 1,
# follows it for socket-activated units; the unit is that pid's cgroup; a socket with no process at
# all is the kernel's, e.g. the NFS client's lockd)
ss -Hlntup 2>/dev/null | while read -r line; do
  set -- $line
  pr=$1; local=$5; p=${local##*:}; a=${local%:*}; a=${a%%%*}; a=${a#[}; a=${a%]}
  pid=$(printf '%s' "$line" | sed -n 's/^.*users:(("[^"]*",pid=\([0-9]*\),.*$/\1/p')
  comm=$(printf '%s' "$line" | sed -n 's/^.*users:(("\([^"]*\)".*$/\1/p')
  unit=""; [ -n "$pid" ] && [ -r /proc/$pid/cgroup ] && unit=$(awk -F/ '{print $NF}' /proc/$pid/cgroup | head -1)
  echo "#listen|$pr|$a|$p|${comm:-?}|${unit:-?}|${pid:-?}"
done
# the agent's service manifests: file|name|package|kind|systemd_unit|tcp_port|remote host:port
# (a file holds one entry or a list of them; parsed with the YAML module the agent itself uses)
if [ -d /etc/homelab/services ] && perl -MYAML::XS -e1 2>/dev/null; then
  perl -MYAML::XS=LoadFile -e '
    for my $f (sort glob "/etc/homelab/services/*.yml") {
      my $doc = eval { LoadFile($f) }; (my $b = $f) =~ s{.*/}{};
      unless ($doc) { print "#manifest|$b|?|?|?|?|?|?|unreadable\n"; next }
      for my $e (ref $doc eq "ARRAY" ? @$doc : ($doc)) {
        next unless ref $e eq "HASH"; my $c = $e->{check} // {};
        my $r = ref $c->{remote_tcp_port} eq "HASH" ? ($c->{remote_tcp_port}{host} // "") . ":" . ($c->{remote_tcp_port}{port} // "") : "";
        print join("|", "#manifest", $b, map { my $v = $_ // ""; $v =~ s/[|\n]/ /g; $v } $e->{name}, $e->{package}, $e->{kind}, $c->{systemd_unit}, $c->{tcp_port}, $r), "\n";
      }
    }'
fi
echo "#end"
COLLECT_EOF

# ---------------------------------------------------------------------------
# The classifier: reads DIR/NN.txt (+ DIR/noreply.txt), prints the findings.
# ---------------------------------------------------------------------------
read -r -d '' CLASSIFY <<'PERL_EOF' || true
use strict; use warnings;
my ($dir, $verbose) = @ARGV; $verbose //= 0;

# --- the knobs: every list here is a decision, see the header -------------
# Stock daemon packages whose running units must be explained by an installed homelab package.
my $WATCHED = qr/^(?:nginx(?:-common|-core|-full|-light)?|apache2|lighttpd|postgresql-common|postgresql-\d+|patroni|etcd-server|pgbouncer|pdns-server|pdns-recursor|dnsdist|bind9|unbound|haproxy|keepalived|postfix|opendkim|opendmarc|dovecot-core|exim4-base|sendmail-bin|php[\d.]+-fpm|roundcube-core|prometheus(?:-[a-z0-9-]+)?|grafana|certbot|redis-server|memcached|mysql-server|mariadb-server|docker(?:\.io|-ce)?|containerd|nfs-kernel-server|samba|vsftpd|proftpd-core|openvpn|wireguard|squid|mosquitto|rabbitmq-server)$/;
# A watched daemon that is fine when it only listens on loopback: the satellite MTA for cron mail.
my %LOOPBACK_OK = (postfix => 1);
# OS units that may hold an exposed listener with no homelab package behind them.
my %OS_LISTENER = map { $_ => 1 } qw(ssh.service ssh.socket rpcbind.service rpcbind.socket rpc-statd.service systemd-networkd.service systemd-resolved.service chrony.service);
# "failed" on every container, a Proxmox quirk with no service behind it.
my %FAILED_NOISE = map { $_ => 1 } qw(netplan-configure.service systemd-networkd-wait-online.service);
# Distro packages whose version must be the same on every node that has them.
my @DRIFT = qw(nginx postgresql-16 postgresql-18 postgresql-common patroni etcd-server pgbouncer pdns-server pdns-backend-pgsql dnsdist haproxy keepalived postfix opendkim dovecot-core roundcube-core php8.4-fpm php8.5-fpm prometheus prometheus-node-exporter prometheus-alertmanager grafana certbot openssh-server systemd nftables bad-ips);
# Unit names judged even when no package owns the unit file (a mask is a symlink in /etc).
my $DAEMON_UNIT = qr/^(?:homelab-|bad_ips|nginx|postgresql|patroni|etcd|pgbouncer|pdns|dnsdist|haproxy|keepalived|postfix|opendkim|dovecot|php[\d.]+-fpm|prometheus|grafana)/;
my %UNIT_PKG = (nginx => 'nginx', postgresql => 'postgresql-common', patroni => 'patroni', etcd => 'etcd-server', pgbouncer => 'pgbouncer',
    pdns => 'pdns-server', dnsdist => 'dnsdist', haproxy => 'haproxy', keepalived => 'keepalived', postfix => 'postfix', opendkim => 'opendkim',
    dovecot => 'dovecot-core', 'grafana-server' => 'grafana', bad_ips => 'bad-ips');

# --- read the snapshot ------------------------------------------------------
my %N;
for my $f (sort glob("$dir/[0-9][0-9].txt")) {
    (my $nn = $f) =~ s{.*/(\d\d)\.txt$}{$1};
    my $n = $N{$nn} = { nn => $nn, host => '?', pkg => {}, unit => {}, masked => {}, owner => {}, listen => [], manifest => [], complete => 0 };
    open my $fh, '<', $f or next;
    while (my $l = <$fh>) {
        chomp $l; next unless $l =~ /^#/;
        my @p = split /\|/, $l, -1; my $k = shift @p; $k =~ s/^#//;
        if    ($k eq 'host')     { $n->{host} = $p[0] }
        elsif ($k eq 'pkg')      { $n->{pkg}{$p[0]} = { ver => $p[1], status => $p[2], provides => $p[3] // '', depends => $p[4] // '', recommends => $p[5] // '' } }
        elsif ($k eq 'unit')     { $n->{unit}{$p[0]} = { load => $p[1], active => $p[2], sub => $p[3], ufs => $p[4] // '', type => $p[5] // '', frag => $p[6] // '', rae => $p[7] // '', cond => $p[8] // '' } }
        elsif ($k eq 'masked')   { $n->{masked}{$p[0]} = 1 }
        elsif ($k eq 'owner')    { $n->{owner}{$p[0]} = $p[1] }
        elsif ($k eq 'listen')   { push @{$n->{listen}}, { proto => $p[0], addr => $p[1], port => $p[2], comm => $p[3], unit => $p[4], pid => $p[5] } }
        elsif ($k eq 'manifest') { push @{$n->{manifest}}, { file => $p[0], name => $p[1], package => $p[2], kind => $p[3], unit => $p[4] // '', port => $p[5] // '', remote => $p[6] // '' } }
        elsif ($k eq 'end')      { $n->{complete} = 1 }
    }
}
my @noreply;
if (open my $fh, '<', "$dir/noreply.txt") { chomp(@noreply = <$fh>); @noreply = sort grep { length } @noreply }
unless (%N) { print "no node answered -- nothing to judge\n"; exit 2 }

# --- helpers ----------------------------------------------------------------
sub status { my ($n, $p) = @_; $n->{pkg}{$p} ? $n->{pkg}{$p}{status} : 'not-installed' }
sub installed { status(@_) eq 'installed' }
# The homelab packages that should be running on this node. TODAY: the ones installed.
# Under #31 this is the one place to change (read the node's homelab.conf instead).
sub expected_packages { my ($n) = @_; return grep { installed($n, $_) } grep { /^homelab-/ || $_ eq 'bad-ips' } sort keys %{$n->{pkg}} }
# ...and everything they depend on (Depends, and Recommends when asked), followed through, with Provides resolved.
sub closure {
    my ($n, $follow_recommends) = @_; my (%need, %prov);
    for my $p (grep { installed($n, $_) } keys %{$n->{pkg}}) {
        for (split /,/, $n->{pkg}{$p}{provides}) { s/^\s+|\s+$//g; s/\s.*//; $prov{$_}{$p} = 1 if length }
    }
    my @todo = expected_packages($n);
    while (defined(my $p = shift @todo)) {
        next if $need{$p}++;
        my $rel = $n->{pkg}{$p}{depends} // '';
        $rel .= ',' . $n->{pkg}{$p}{recommends} if $follow_recommends && length($n->{pkg}{$p}{recommends} // '');
        for my $alt (split /,/, $rel) {
            for my $c (split /~/, $alt) {
                $c =~ s/^\s+|\s+$//g; $c =~ s/\s.*//; $c =~ s/:.*//; next unless length $c;
                push @todo, $c if installed($n, $c) && !$need{$c};
                push @todo, grep { !$need{$_} } keys %{ $prov{$c} || {} };
            }
        }
    }
    return \%need;
}
sub owner_pkg {   # the package behind a unit: the unit file's owner, else by name
    my ($n, $u) = @_;
    my $frag = $n->{unit}{$u} ? $n->{unit}{$u}{frag} : '';
    return $n->{owner}{$frag} if $frag && $n->{owner}{$frag};
    (my $base = $u) =~ s/\.(service|timer|socket)$//; $base =~ s/@.*//;
    return 'bad-ips' if $base =~ /^bad_ips/;
    for my $m (@{$n->{manifest}}) {      # a manifest naming this unit says which package it is (homelab-cert-server's homelab-cert-sign)
        next unless length $m->{unit};
        (my $mu = $m->{unit}) =~ s/\.(service|timer|socket)$//;
        return $m->{package} if $mu eq $base;
    }
    if ($base =~ /^homelab-/) {
        my @w = split /-/, $base;
        while (@w > 1) { my $cand = join '-', @w; return $cand if $n->{pkg}{$cand}; pop @w }
        return '';
    }
    return $UNIT_PKG{$base} if $UNIT_PKG{$base};
    return $base if $base =~ /^php[\d.]+-fpm$/ || $base =~ /^prometheus(?:-[a-z0-9-]+)?$/;
    return '';
}
sub judged { my ($n, $u, $o) = @_; return 1 if $o && ($o =~ $WATCHED || $o =~ /^homelab-/ || $o eq 'bad-ips'); return $u =~ $DAEMON_UNIT ? 1 : 0 }
sub loopback { my $a = shift; return $a =~ /^127\./ || $a eq '::1' }
sub should_run { my $s = shift; return 0 unless $s->{ufs} =~ /^enabled(?:-runtime)?$/; return 0 if $s->{type} eq 'oneshot' && $s->{rae} ne 'yes';
    return 0 if $s->{cond} eq 'no';   # systemd tried and a Condition* said no (node-exporter's ipmitool/mellanox timers on a VM): not a stopped service
    1 }
sub listeners { my ($n, $u) = @_; grep { $_->{unit} eq $u } @{$n->{listen}} }
sub ports_str { my @l = @_; my %s; my @e = sort grep { !$s{$_}++ } map { "$_->{proto}:$_->{port}" } grep { !loopback($_->{addr}) } @l; my @lo = grep { loopback($_->{addr}) } @l;
    return @e ? "listening on " . join(', ', @e) : @lo ? 'loopback only' : 'no listener' }
sub short { my $l = shift; my @n = sort @$l; return @n <= 12 ? "@n" : "@n[0..9] +" . (@n - 10) . " more" }

# --- findings ---------------------------------------------------------------
my %F;   # section -> severity -> message -> [nodes]
sub add { my ($sec, $sev, $nn, $msg) = @_; push @{ $F{$sec}{$sev}{$msg} }, $nn }
sub fail { add($_[0], 'FAIL', $_[1], $_[2]) }
sub warn_ { add($_[0], 'warn', $_[1], $_[2]) }
sub note { add($_[0], 'ok', $_[1], $_[2]) if $verbose }

for my $nn (sort keys %N) {
    my $n = $N{$nn};
    unless ($n->{complete}) { fail('MISSING', $nn, 'the collector did not finish on this node (timed out) -- not judged'); next }
    my $need = closure($n, 1);   # Depends and Recommends: both are what apt installs by default (measured 2026-11-18: Recommends adds only node-exporter's collectors)

    # units
    for my $u (sort keys %{$n->{unit}}) {
        my $s = $n->{unit}{$u};
        next unless $u =~ /\.(service|timer)$/;
        my $o = owner_pkg($n, $u);
        my $exp = $o && $need->{$o};
        if ($s->{active} eq 'failed') {
            if ($s->{load} eq 'not-found') { warn_('LEFTOVERS', $nn, "$u: failed state of a unit that no longer exists (systemctl reset-failed $u)") }
            elsif ($FAILED_NOISE{$u})       { note('NOTES', $nn, "$u failed (every container; Proxmox quirk, no service behind it)") }
            else                            { fail('MISSING', $nn, "$u has FAILED ($s->{sub})" . ($o ? " [$o]" : '')) }
            next;
        }
        next if $s->{load} eq 'masked';     # judged from the #masked records below
        next unless judged($n, $u, $o);
        if ($s->{active} eq 'active') {
            if ($exp) { note('NOTES', $nn, "$u running as expected [$o]") }
            elsif ($o && ($o =~ /^homelab-/ || $o eq 'bad-ips')) { fail('UNEXPECTED', $nn, "$u is running but its package $o is " . status($n, $o) . " here") }
            elsif ($o && $o =~ $WATCHED) {
                my @l = listeners($n, $u); my $exposed = grep { !loopback($_->{addr}) } @l;
                if (!$exposed && $LOOPBACK_OK{$o}) { note('NOTES', $nn, "$u loopback only (satellite $o, fine)") }
                else { fail('UNEXPECTED', $nn, "$u is running though no installed homelab package needs $o: " . ports_str(@l)) }
            }
            else { fail('UNEXPECTED', $nn, "$u is running and nothing explains it: " . ports_str(listeners($n, $u))) }
        }
        elsif ($exp && should_run($s)) { fail('MISSING', $nn, "$u is $s->{active}/$s->{sub} though enabled [$o]") }
        elsif ($exp) { note('NOTES', $nn, "$u $s->{active} ($s->{ufs}, " . ($s->{type} || 'timer') . "; not required to run) [$o]") }
    }

    # masked
    for my $m (sort keys %{$n->{masked}}) {
        next unless $m =~ $DAEMON_UNIT;
        my $o = owner_pkg($n, $m); my $st = $o ? status($n, $o) : 'unknown';
        if    ($o && $need->{$o})        { fail('LEFTOVERS', $nn, "$m is masked though $o is installed and needed here (purge the package if this node should not run it, else unmask)") }
        elsif ($o && $st eq 'installed') { warn_('LEFTOVERS', $nn, "$m is masked; $o is installed but nothing here needs it (purge it)") }
        else                             { warn_('LEFTOVERS', $nn, "$m is masked and its package is gone ($st): rm /etc/systemd/system/$m && systemctl daemon-reload") }
    }

    # manifests
    for my $m (@{$n->{manifest}}) {
        if ($m->{name} eq '?') { fail('MISSING', $nn, "manifest $m->{file} is unreadable"); next }
        unless (installed($n, $m->{package})) { fail('UNEXPECTED', $nn, "manifest $m->{file} declares $m->{name} for $m->{package}, which is " . status($n, $m->{package}) . " here (stray manifest: rm /etc/homelab/services/$m->{file}; systemctl restart homelab-agent)"); next }
        if (length $m->{unit}) {
            my $uu = $m->{unit} =~ /\.(service|timer|socket)$/ ? $m->{unit} : "$m->{unit}.service";
            my $s = $n->{unit}{$uu};
            fail('MISSING', $nn, "manifest $m->{file} ($m->{name}): $uu is " . ($s ? "$s->{active}/$s->{sub}" : 'unknown to systemd')) unless $s && $s->{active} eq 'active';
        }
        if (length $m->{port}) {
            fail('MISSING', $nn, "manifest $m->{file} ($m->{name}): nothing listens on tcp $m->{port}") unless grep { $_->{proto} eq 'tcp' && $_->{port} eq $m->{port} } @{$n->{listen}};
        }
    }

    # exposed listeners nothing explains
    my %seen;
    for my $l (@{$n->{listen}}) {
        next if loopback($l->{addr});
        my $u = $l->{unit};
        next if $OS_LISTENER{$u};
        if ($u eq '?' && $l->{pid} eq '?') {
            next if installed($n, 'nfs-common');   # the kernel NFS client (lockd) on the VMs that mount the NAS
            fail('UNEXPECTED', $nn, "exposed $l->{proto} $l->{port} held by the kernel (no process) and nfs-common is not installed");
            next;
        }
        my $o = owner_pkg($n, $u);
        next if $o && $need->{$o};
        next if judged($n, $u, $o);            # reported above, with its ports
        next if $seen{$u}++;
        fail('UNEXPECTED', $nn, "exposed listener(s) held by $u ($l->{comm}), nothing explains it: " . ports_str(listeners($n, $u)));
    }

    # installed stock daemons nothing needs, not running
    for my $p (sort grep { $_ =~ $WATCHED && installed($n, $_) && !$need->{$_} } keys %{$n->{pkg}}) {
        next if grep { owner_pkg($n, $_) eq $p && $n->{unit}{$_}{active} eq 'active' } keys %{$n->{unit}};
        if ($LOOPBACK_OK{$p}) { warn_('LEFTOVERS', $nn, "$p (the satellite MTA every node has) is installed but not running here") }
        else { warn_('LEFTOVERS', $nn, "$p is installed, nothing here needs it, not running (purge it)") }
    }
    # homelab packages removed but not purged
    my @cf = sort grep { /^homelab-/ && status($n, $_) eq 'config-files' } keys %{$n->{pkg}};
    warn_('LEFTOVERS', $nn, "removed but not purged (apt purge): @cf") if @cf;
}

# drift across nodes
for my $p (@DRIFT) {
    my %v;
    for my $nn (sort keys %N) { my $n = $N{$nn}; push @{ $v{ $n->{pkg}{$p}{ver} } }, $nn if installed($n, $p) }
    next if keys %v < 2;
    my $msg = "$p: " . join(' | ', map { "$_ on " . scalar(@{$v{$_}}) . " (" . short($v{$_}) . ")" } sort keys %v);
    $F{DRIFT}{FAIL}{$msg} = [];
}

# --- report -----------------------------------------------------------------
my $checked = scalar keys %N;
print "Checked $checked node(s) (prod-homelabNN; the numbers below are NN)\n";
print "No reply from " . scalar(@noreply) . " node(s) -- NOT covered: @noreply\n" if @noreply;
my ($nfail, $nwarn) = (0, 0);
for my $sec (qw(MISSING UNEXPECTED LEFTOVERS DRIFT NOTES)) {
    next unless $F{$sec};
    print "\n$sec\n";
    for my $sev (qw(FAIL warn ok)) {
        next unless $F{$sec}{$sev};
        for my $msg (sort keys %{ $F{$sec}{$sev} }) {
            my $nodes = $F{$sec}{$sev}{$msg};
            $nfail++ if $sev eq 'FAIL'; $nwarn++ if $sev eq 'warn';
            printf "  %-4s %s%s\n", $sev, $msg, (@$nodes ? "  [" . short($nodes) . "]" : '');
        }
    }
}
print "\n";
if ($nfail) { print "$nfail finding(s) to look at" . ($nwarn ? ", $nwarn warning(s)" : '') . " (see above)\n"; exit 1 }
print "FLEET RUNNING WHAT IT SHOULD, AND NOTHING ELSE" . ($nwarn ? " -- $nwarn leftover warning(s) above" : '') . ".\n";
exit 0;
PERL_EOF

classify(){ perl -e "$CLASSIFY" -- "$1" "$VERBOSE"; }

# ---------------------------------------------------------------------------
# --selftest: crafted snapshots for the cases this must catch, and one it must not.
# ---------------------------------------------------------------------------
selftest(){
    local T; T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' RETURN
    local base='#host|test
#pkg|homelab-common|0.1.37|installed||perl
#pkg|homelab-agent|0.1.9|installed||homelab-common
#pkg|homelab-notes|0.2.0|installed||homelab-common, homelab-webtheme
#pkg|homelab-webtheme|0.2.0|installed||
#pkg|postfix|3.10.6-4ubuntu2.1|installed||
#pkg|openssh-server|1:10.2p1|installed||
#pkg|glances|4.3.3|installed||
#unit|homelab-agent.service|loaded|active|running|enabled|notify|/usr/lib/systemd/system/homelab-agent.service|no
#unit|postfix.service|loaded|active|running|enabled|forking|/usr/lib/systemd/system/postfix.service|no
#unit|ssh.service|loaded|active|running|enabled|notify|/usr/lib/systemd/system/ssh.service|no
#unit|netplan-configure.service|loaded|failed|failed|enabled|oneshot|/usr/lib/systemd/system/netplan-configure.service|yes
#unit|glances.service|loaded|active|running|enabled|simple|/usr/lib/systemd/system/glances.service|no
#unit|homelab-certsync.service|loaded|inactive|dead|enabled|oneshot|/usr/lib/systemd/system/homelab-certsync.service|no
#owner|/usr/lib/systemd/system/homelab-agent.service|homelab-agent
#owner|/usr/lib/systemd/system/homelab-notes.service|homelab-notes
#owner|/usr/lib/systemd/system/postfix.service|postfix
#owner|/usr/lib/systemd/system/ssh.service|openssh-server
#owner|/usr/lib/systemd/system/glances.service|glances
#owner|/usr/lib/systemd/system/homelab-certsync.service|homelab-certsync
#listen|tcp|0.0.0.0|22|sshd|ssh.service|300
#listen|tcp|0.0.0.0|2520|/usr/bin/homela|homelab-agent.service|401
#listen|tcp|127.0.0.1|25|master|postfix.service|402
#listen|tcp|::1|25|master|postfix.service|402
#listen|tcp|127.0.0.53|53|systemd-resolve|systemd-resolved.service|86
#listen|tcp|127.0.0.1|61209|glances|glances.service|279
#manifest|notes.yml|notes|homelab-notes|http_service|homelab-notes|2518|'
    local running='#unit|homelab-notes.service|loaded|active|running|enabled|notify|/usr/lib/systemd/system/homelab-notes.service|no
#listen|tcp|0.0.0.0|2518|/usr/bin/homela|homelab-notes.service|400'
    local rc=0 out
    check(){ # dir, case name, expected exit, text that must appear (or "")
        out="$(classify "$T/$1" 2>&1)"; local got=$?
        if [ "$got" != "$3" ]; then echo "  FAIL $2: exit $got, expected $3"; echo "$out" | sed 's/^/       /'; rc=1; return; fi
        if [ -n "$4" ] && ! printf '%s\n' "$out" | grep -q -F -- "$4"; then echo "  FAIL $2: no line containing '$4'"; echo "$out" | sed 's/^/       /'; rc=1; return; fi
        echo "  ok   $2"
    }
    # 1. a healthy node: satellite postfix on loopback, resolved on loopback :53, the Proxmox failed unit, glances -- nothing to report
    mkdir -p "$T/clean"; printf '%s\n%s\n#end\n' "$base" "$running" > "$T/clean/90.txt"
    check clean clean 0 'FLEET RUNNING WHAT IT SHOULD'
    # 2. prod-homelab39's case: a stray pgbouncer, loopback only, with no homelab-pgbouncer
    mkdir -p "$T/stray"; { printf '%s\n%s\n' "$base" "$running"; cat <<'X'
#pkg|pgbouncer|1.25.1-1|installed||
#unit|pgbouncer.service|loaded|active|running|enabled|notify|/usr/lib/systemd/system/pgbouncer.service|no
#owner|/usr/lib/systemd/system/pgbouncer.service|pgbouncer
#listen|tcp|127.0.0.1|6432|pgbouncer|pgbouncer.service|500
#listen|tcp|::1|6432|pgbouncer|pgbouncer.service|500
#end
X
    } > "$T/stray/91.txt"
    check stray stray-pgbouncer-loopback 1 'pgbouncer.service is running though no installed homelab package needs pgbouncer: loopback only'
    # 3. a silently stopped service: the unit is enabled but dead, the manifest's port has no listener
    mkdir -p "$T/stopped"; { printf '%s\n' "$base"; cat <<'X'
#unit|homelab-notes.service|loaded|inactive|dead|enabled|notify|/usr/lib/systemd/system/homelab-notes.service|no
#end
X
    } > "$T/stopped/92.txt"
    check stopped stopped-service 1 'homelab-notes.service is inactive/dead though enabled'
    check stopped stopped-service-manifest 1 'nothing listens on tcp 2518'
    # 4. postfix at two versions across two nodes
    mkdir -p "$T/drift"; printf '%s\n%s\n#end\n' "$base" "$running" > "$T/drift/93.txt"
    printf '%s\n%s\n#end\n' "$base" "$running" | sed 's/^#pkg|postfix|3.10.6-4ubuntu2.1|/#pkg|postfix|3.10.6-4ubuntu2.2|/' > "$T/drift/94.txt"
    check drift drift 1 'postfix: 3.10.6-4ubuntu2.1 on 1 (93) | 3.10.6-4ubuntu2.2 on 1 (94)'
    # 5. an exposed listener nothing explains (a hand-started daemon), and a stray manifest
    mkdir -p "$T/exposed"; { printf '%s\n%s\n' "$base" "$running"; cat <<'X'
#unit|python3-http.service|loaded|active|running|enabled|simple|/etc/systemd/system/python3-http.service|no
#listen|tcp|0.0.0.0|8000|python3|python3-http.service|600
#manifest|drive.yml|drive|homelab-drive|http_service|homelab-drive|2501|
#end
X
    } > "$T/exposed/95.txt"
    check exposed exposed-listener 1 'exposed listener(s) held by python3-http.service (python3), nothing explains it: listening on tcp:8000'
    check exposed stray-manifest 1 'manifest drive.yml declares drive for homelab-drive, which is not-installed here'
    # 6. leftovers only: a masked daemon of a removed package, a removed-not-purged package -- warnings, exit 0
    mkdir -p "$T/leftover"; { printf '%s\n%s\n' "$base" "$running"; cat <<'X'
#pkg|homelab-api|0.1.61|config-files||
#masked|pdns.service
#end
X
    } > "$T/leftover/96.txt"
    check leftover leftovers-warn-only 0 'pdns.service is masked and its package is gone'
    # 7. a homelab unit running without its package (the package was removed, the process lived on)
    mkdir -p "$T/orphan"; { printf '%s\n%s\n' "$base" "$running"; cat <<'X'
#pkg|homelab-drive|0.1.51|config-files||
#unit|homelab-drive.service|loaded|active|running|enabled|notify|/usr/lib/systemd/system/homelab-drive.service|no
#listen|tcp|0.0.0.0|2501|/usr/bin/homela|homelab-drive.service|700
#end
X
    } > "$T/orphan/97.txt"
    check orphan orphan-homelab-unit 1 'homelab-drive.service is running but its package homelab-drive is config-files here'
    [ "$rc" = 0 ] && echo "selftest: every case behaves." || echo "selftest: FAILED."
    return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --selftest) selftest; exit $? ;;
    --from)     [ -d "${2:-}" ] || { echo "usage: $0 --from DIR"; exit 2; }; classify "$2"; exit $? ;;
    -*)         echo "unknown option '$1' (see the header of $0)"; exit 2 ;;
esac

NODES=("$@")
if [ ${#NODES[@]} -eq 0 ]; then for n in $(seq "$FIRST" "$LAST"); do NODES+=("$(printf '%02d' "$n")"); done; fi
if [ -n "${KEEP:-}" ]; then DIR="$KEEP"; mkdir -p "$DIR"; rm -f "${DIR:?}"/[0-9][0-9].txt "${DIR:?}/noreply.txt"
else DIR="$(mktemp -d)"; trap 'rm -rf "${DIR:?}"' EXIT; fi

collect(){ # NN
    local nn="$1" ip out; ip="$(ip_of "$nn")"
    out=$(timeout 150 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$ip" 'sudo bash -s' <<<"$COLLECT" 2>/dev/null)
    if [ -n "$out" ]; then printf '%s\n' "$out" > "$DIR/$nn.txt"; else echo "$nn" >> "$DIR/noreply.txt"; fi
}
i=0
for nn in "${NODES[@]}"; do
    collect "$nn" &
    i=$((i+1)); [ $((i % PAR)) -eq 0 ] && wait
done
wait
[ -n "${KEEP:-}" ] && echo "snapshot kept in $DIR"
classify "$DIR"
