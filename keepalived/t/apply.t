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
my $dvips_spec = "$work/dhcp-vips.conf";
local $ENV{HOMELAB_KEEPALIVED_CFG} = $cfg;
local $ENV{HOMELAB_KEEPALIVED_OUT} = $out;
local $ENV{HOMELAB_KEEPALIVED_NFT} = "$work/15-homelab-vrrp.nft";
local $ENV{HOMELAB_KEEPALIVED_DHCP_VIPS} = $dvips_spec;
local $ENV{HOMELAB_KEEPALIVED_NOTIFY}    = '/usr/bin/homelab-keepalived-notify';

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

# ---- notify-managed dhcp_vips (macvlan + reservation MAC + DHCP) ---------
open($f, '>', $cfg) or die $!;
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
auth_pass: hledge
vips:
  - address: 10.50.2.140/22
    interface: eth4
dhcp_vips:
  - name: pub66
    parent: eth7
    mac: bc:24:11:73:51:b4
    mode: dhcp
  - name: pub68
    parent: eth6
    mac: bc:24:11:8f:08:b4
    mode: dhcp
track_services:
  - nginx
  - haproxy
  - dnsdist
YAML
close $f;
my $o3 = `perl script/homelab-keepalived-apply 2>&1`;
is($? >> 8, 0, 'apply exits 0 for a dhcp_vips config') or diag($o3);
my $conf3 = do { local (@ARGV, $/) = $out; <> };
# notify hooks wired for all three transitions
like($conf3, qr{notify_master "/usr/bin/homelab-keepalived-notify master"},
    'notify_master wired to the hook');
like($conf3, qr{notify_backup "/usr/bin/homelab-keepalived-notify backup"},
    'notify_backup wired');
like($conf3, qr{notify_fault\s+"/usr/bin/homelab-keepalived-notify fault"},
    'notify_fault wired');
like($conf3, qr{notify_stop\s+"/usr/bin/homelab-keepalived-notify backup"},
    'notify_stop wired to teardown (graceful stop tears macvlans down)');
# keepalived-managed internal VIP still rendered as a virtual_ipaddress
like($conf3, qr{\Q10.50.2.140/22 dev eth4\E}, 'keepalived-managed internal VIP kept');
# public VIPs must NOT appear as keepalived virtual_ipaddress entries
unlike($conf3, qr{23\.116\.91\.6[68]}, 'public dhcp_vips are NOT keepalived virtual_ipaddress');
my $ob3 = ($conf3 =~ tr/{//);
my $cb3 = ($conf3 =~ tr/}//);
is($ob3, $cb3, 'braces balanced with notify hooks');
# the notify spec file was written with one line per dhcp VIP
ok(-f $dvips_spec, 'dhcp-vips.conf spec written');
my $spec = do { local (@ARGV, $/) = $dvips_spec; <> };
like($spec, qr{^pub66 eth7 bc:24:11:73:51:b4 dhcp -$}m, 'pub66 spec line');
like($spec, qr{^pub68 eth6 bc:24:11:8f:08:b4 dhcp -$}m, 'pub68 spec line');

# ---- static+dhcp mode requires an address -------------------------------
open($f, '>', $cfg) or die $!;
print $f <<'YAML';
instance: EDGE_PUBLIC
router_id: 66
priority: 150
vrrp_interface: eth4
unicast_src: 10.50.2.144
peers: [10.50.2.145]
dhcp_vips:
  - name: pub66
    parent: eth7
    mac: bc:24:11:73:51:b4
    mode: static+dhcp
YAML
close $f;
my $o4 = `perl script/homelab-keepalived-apply 2>&1`;
isnt($? >> 8, 0, 'static+dhcp without an address is rejected');
like($o4, qr/needs an 'address:'/, 'error names the missing address');

# ---- a config with ONLY dhcp_vips (no keepalived vips) is allowed --------
open($f, '>', $cfg) or die $!;
print $f <<'YAML';
instance: EDGE_PUBLIC
router_id: 66
priority: 150
vrrp_interface: eth4
unicast_src: 10.50.2.144
peers: [10.50.2.145]
dhcp_vips:
  - name: pub66
    parent: eth7
    mac: bc:24:11:73:51:b4
    mode: dhcp
YAML
close $f;
my $o5 = `perl script/homelab-keepalived-apply 2>&1`;
is($? >> 8, 0, 'apply exits 0 with only dhcp_vips (no virtual_ipaddress)') or diag($o5);
my $conf5 = do { local (@ARGV, $/) = $out; <> };
unlike($conf5, qr/virtual_ipaddress/, 'no empty virtual_ipaddress block emitted');
like($conf5, qr/notify_master/, 'notify still wired when only dhcp_vips present');

done_testing;
