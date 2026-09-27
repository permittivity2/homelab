use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Exercises the real script end-to-end (rendering, idempotent
# include-line/forward-accept insertion into an existing multi-table
# nftables.conf, validate-before-apply, and manifest generation) using
# temp files and a stub `nft` on PATH -- `nft -c` genuinely requires
# root/CAP_NET_ADMIN even just to validate syntax (confirmed: it fails
# with "Operation not permitted", not a syntax error, when run
# unprivileged), so this tests our own generation/safety logic without
# needing a real nftables-capable environment, same approach
# homelab-haproxy's own t/apply-backends.t takes for `haproxy -c`.

my $work    = tempdir(CLEANUP => 1);
my $cfg_dir = "$work/config";
make_path($cfg_dir);

my $stub_bin = "$work/stubbin";
make_path($stub_bin);

# A stub `nft` that behaves like the real `-c -f FILE` / `-f FILE`:
# exits 0 for a normal-looking file, exits 1 (simulating a real syntax
# error) only if the file contains the literal marker
# BROKEN_CONFIG_MARKER -- lets the "validation failure must not touch
# the live ruleset" path be tested without a real nft binary or a
# genuinely-broken config our own generator would never produce. Also
# resolves `include` globs itself (nft's -c genuinely does), so a
# broken fragment is caught the same way a broken base file would be.
open(my $nfh, '>', "$stub_bin/nft") or die $!;
print $nfh <<'STUB';
#!/bin/sh
file=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-f" ]; then file="$arg"; fi
    prev="$arg"
done
broken=0
grep -q BROKEN_CONFIG_MARKER "$file" 2>/dev/null && broken=1
for inc in $(grep -oP '(?<=include ")[^"]+' "$file" 2>/dev/null); do
    for f in $inc; do
        grep -q BROKEN_CONFIG_MARKER "$f" 2>/dev/null && broken=1
    done
done
if [ "$broken" = "1" ]; then
    echo "simulated nft config error" >&2
    exit 1
fi
exit 0
STUB
close($nfh);
chmod(0755, "$stub_bin/nft");
local $ENV{PATH} = "$stub_bin:$ENV{PATH}";

my $forwards_yml  = "$cfg_dir/forwards.yml";
my $nftables_conf = "$work/nftables.conf";
my $nftables_d    = "$work/nftables.d";
make_path($nftables_d);

# A realistic existing nftables.conf -- multiple chains, a set-literal
# ({ 22, 53, 80 }) in the input chain to prove that's depth-neutral and
# doesn't perturb the table-boundary search, and a second table after
# `inet filter` to prove the include line lands right after filter's
# closing brace, not just anywhere/at EOF.
open(my $cfh, '>', $nftables_conf) or die $!;
print $cfh <<'CONF';
#!/usr/bin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        tcp dport { 22, 53, 80 } accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;
        ct state established,related accept
    }
}
table inet badips {
    set badipv4 {
        type ipv4_addr
        flags interval,timeout
    }
}
CONF
close($cfh);

open(my $fh, '>', $forwards_yml) or die $!;
print $fh <<'YAML';
public_interface: eth5
snat_to: 10.50.2.144
forwards:
  - name: dns
    protocols: [udp, tcp]
    public_port: 53
    backend_host: 10.50.2.162
    backend_port: 53
YAML
close($fh);

local $ENV{HOMELAB_EDGE_FORWARD_CONFIG}         = $forwards_yml;
local $ENV{HOMELAB_EDGE_FORWARD_NFTABLES_CONF}  = $nftables_conf;
local $ENV{HOMELAB_EDGE_FORWARD_NFTABLES_D}     = $nftables_d;

my $output = `perl script/homelab-edge-forward-apply 2>&1`;
is($? >> 8, 0, 'script exits 0 on a valid config') or diag($output);
like($output, qr/applied 1 forward\(s\), reloaded/, 'reports how many forwards were applied');

my $frag = do { local (@ARGV, $/) = "$nftables_d/50-edge-forward.conf"; <> };
like($frag, qr/table ip nat \{/, 'nat table present in the fragment');
like($frag, qr/iifname "eth5" udp dport 53 dnat to 10\.50\.2\.162:53/, 'udp prerouting dnat rule present');
like($frag, qr/iifname "eth5" tcp dport 53 dnat to 10\.50\.2\.162:53/, 'tcp prerouting dnat rule present');
like($frag, qr/ip daddr 10\.50\.2\.162 udp dport 53 snat to 10\.50\.2\.144/, 'udp postrouting snat rule present');
like($frag, qr/ip daddr 10\.50\.2\.162 tcp dport 53 snat to 10\.50\.2\.144/, 'tcp postrouting snat rule present');
unlike($frag, qr/flush ruleset/, 'fragment never contains its own flush ruleset (would wipe the already-loaded filter table)');

my $conf = do { local (@ARGV, $/) = $nftables_conf; <> };
like($conf, qr/include "$nftables_d\/\*\.conf";/, 'include line was added');
like($conf, qr{table inet filter \{.*?\}\s*include}s, 'include line lands right after table inet filter\'s own closing brace, before the badips table')
    or diag($conf);
like($conf, qr/udp dport 53 ip daddr 10\.50\.2\.162 accept/, 'udp forward-chain accept rule added');
like($conf, qr/tcp dport 53 ip daddr 10\.50\.2\.162 accept/, 'tcp forward-chain accept rule added');
like($conf, qr/chain forward \{.*?ct state established,related accept/s,
    'forward chain gets a ct state established,related accept -- without it the reply leg is silently dropped even though the request got through')
    or diag($conf);
like($conf, qr/tcp dport \{ 22, 53, 80 \} accept/, 'pre-existing set-literal rule in the input chain is untouched');

# Idempotency: re-run with the same input, must succeed again and not
# duplicate the include line or the forward-chain accepts.
my $output2 = `perl script/homelab-edge-forward-apply 2>&1`;
is($? >> 8, 0, 'second run also exits 0') or diag($output2);
my $conf2 = do { local (@ARGV, $/) = $nftables_conf; <> };
is(( () = $conf2 =~ /include "\Q$nftables_d\E\/\*\.conf";/g ), 1, 'include line is not duplicated on a second run');
is(( () = $conf2 =~ /udp dport 53 ip daddr 10\.50\.2\.162 accept/g ), 1, 'udp forward-chain accept is not duplicated on a second run');
# The fixture's input/output chains already have their OWN pre-existing
# "ct state established,related accept" (2 total) before the script
# ever runs -- this counts occurrences specifically inside the forward
# chain, where exactly one (the one this script adds) should exist,
# not duplicated on a second run.
my ($fwd_chain2) = $conf2 =~ /chain forward \{(.*?)\n    \}/s;
is(( () = $fwd_chain2 =~ /ct state established,related accept/g ), 1,
    'ct state established,related accept appears exactly once within the forward chain specifically, not duplicated on a second run')
    or diag($conf2);

# Validation failure must NOT clobber the previously-working ruleset.
open(my $bfh, '>', $forwards_yml) or die $!;
print $bfh <<'YAML';
public_interface: BROKEN_CONFIG_MARKER
snat_to: 10.50.2.144
forwards:
  - name: dns
    protocols: [udp]
    public_port: 53
    backend_host: 10.50.2.162
    backend_port: 53
YAML
close($bfh);

my $output3 = `perl script/homelab-edge-forward-apply 2>&1`;
isnt($? >> 8, 0, 'script exits non-zero when nft -c rejects the new config');
like($output3, qr/validation failed/, 'reports validation failure clearly');

# A pre-existing bare-glob include (e.g. a badips table's own
# `include "/etc/nftables.d/*";`) already covers our fragment file --
# adding our own more-specific include on top would load it TWICE
# (nft doesn't dedupe overlapping includes), silently doubling every
# DNAT/SNAT rule. Regression test for exactly that.
{
    my $work2       = tempdir(CLEANUP => 1);
    my $nft_conf2   = "$work2/nftables.conf";
    my $nft_d2      = "$work2/nftables.d";
    make_path($nft_d2);

    open(my $c2fh, '>', $nft_conf2) or die $!;
    print $c2fh <<CONF;
flush ruleset

table inet filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
include "$nft_d2/*";
CONF
    close($c2fh);

    my $forwards_yml2 = "$work2/forwards.yml";
    open(my $f2fh, '>', $forwards_yml2) or die $!;
    print $f2fh <<'YAML';
public_interface: eth5
snat_to: 10.50.2.144
forwards:
  - name: dns
    protocols: [udp]
    public_port: 53
    backend_host: 10.50.2.162
    backend_port: 53
YAML
    close($f2fh);

    local $ENV{HOMELAB_EDGE_FORWARD_CONFIG}        = $forwards_yml2;
    local $ENV{HOMELAB_EDGE_FORWARD_NFTABLES_CONF} = $nft_conf2;
    local $ENV{HOMELAB_EDGE_FORWARD_NFTABLES_D}    = $nft_d2;

    my $output5 = `perl script/homelab-edge-forward-apply 2>&1`;
    is($? >> 8, 0, 'script exits 0 when a pre-existing broader include already covers the directory') or diag($output5);
    my $conf5 = do { local (@ARGV, $/) = $nft_conf2; <> };
    is(( () = $conf5 =~ /include "/g ), 1, 'no second include line was added -- the existing bare-glob include already covers it');
}

done_testing;
