use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Exercises homelab-keepalived-apply's config rendering end-to-end using
# temp paths (env overrides) + PATH-stub systemctl/nft, so no real
# keepalived/nftables is touched. Focus: the generated keepalived.conf.

my $work = tempdir(CLEANUP => 1);
my $stub = "$work/stubbin";
make_path($stub);
for my $cmd (qw(systemctl nft)) {
    open(my $fh, '>', "$stub/$cmd") or die $!;
    if ($cmd eq 'systemctl') {
        # is-active --quiet -> "not active" (exit 3) so the script takes the
        # start path; every other systemctl call succeeds.
        print $fh qq{#!/bin/sh\nfor a in "\$\@"; do [ "\$a" = is-active ] && exit 3; done\nexit 0\n};
    } else {
        # nft: succeed, print nothing (so \$have_out is false, no rules parsed)
        print $fh "#!/bin/sh\nexit 0\n";
    }
    close $fh;
    chmod 0755, "$stub/$cmd";
}
local $ENV{PATH} = "$stub:$ENV{PATH}";

my $cfg = "$work/vrrp.yml";
my $out = "$work/keepalived.conf";
local $ENV{HOMELAB_KEEPALIVED_CFG} = $cfg;
local $ENV{HOMELAB_KEEPALIVED_OUT} = $out;
local $ENV{HOMELAB_KEEPALIVED_NFT} = "$work/15-homelab-vrrp.nft";

# ---- new multi-VIP form (one public IP per interface) --------------------
open(my $f, '>', $cfg) or die $!;
print $f <<'YAML';
enabled: true
instance: EDGE_PUBLIC
router_id: 66
state: BACKUP
priority: 150
vrrp_interface: eth4
unicast_src: 10.50.2.144
peers:
  - 10.50.2.145
  - 10.50.2.146
auth_pass: hlvrrp
vips:
  - address: 23.116.91.66/24
    interface: eth7
  - address: 23.116.91.68/24
    interface: eth6
track_services:
  - nginx
  - haproxy
YAML
close $f;

my $o = `perl script/homelab-keepalived-apply 2>&1`;
is($? >> 8, 0, 'apply exits 0 for a multi-VIP config') or diag($o);
ok(-f $out, 'keepalived.conf was written');
my $conf = do { local (@ARGV, $/) = $out; <> };
like($conf, qr/vrrp_instance EDGE_PUBLIC \{/, 'vrrp_instance rendered');
like($conf, qr/priority 150/, 'priority rendered');
like($conf, qr{\Q23.116.91.66/24 dev eth7\E}, 'VIP .66 floats on eth7');
like($conf, qr{\Q23.116.91.68/24 dev eth6\E}, 'VIP .68 floats on eth6');
like($conf, qr/unicast_peer \{\s*10\.50\.2\.145\s*10\.50\.2\.146\s*\}/s, 'both peers in unicast_peer');
like($conf, qr/track_script \{\s*chk_edge/s, 'service health tracking wired');
unlike($conf, qr/virtual_routes/, 'no default route managed when default_route_via is omitted');
my $ob = ($conf =~ tr/{//);
my $cb = ($conf =~ tr/}//);
is($ob, $cb, 'braces balanced in generated config');

# ---- back-compat single-vip form + default route ------------------------
open($f, '>', $cfg) or die $!;
print $f <<'YAML';
instance: EDGE1
router_id: 67
priority: 100
vrrp_interface: eth4
unicast_src: 10.50.2.44
peers: [10.50.2.77]
vip: 23.116.91.67/24
vip_interface: eth5
default_route_via: 23.116.91.70
YAML
close $f;
my $o2 = `perl script/homelab-keepalived-apply 2>&1`;
is($? >> 8, 0, 'apply exits 0 for the single-vip back-compat form') or diag($o2);
my $conf2 = do { local (@ARGV, $/) = $out; <> };
like($conf2, qr{\Q23.116.91.67/24 dev eth5\E}, 'single vip rendered on its interface');
like($conf2, qr{virtual_routes \{\s*default via 23\.116\.91\.70 dev eth5}s,
    'default route installed via gw on the vip interface');

done_testing;
