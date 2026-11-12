use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Exercises the real script end-to-end (Lua config generation,
# validate-before-apply, idempotency, refusing to clobber a working
# config on a validation failure, and manifest generation) using temp
# files and a stub `dnsdist`/`systemctl` on PATH -- same approach
# homelab-haproxy's own t/apply-backends.t and homelab-edge-forward's
# t/apply.t take for their own real binaries.

my $work    = tempdir(CLEANUP => 1);
my $cfg_dir = "$work/config";
make_path($cfg_dir);

my $stub_bin = "$work/stubbin";
make_path($stub_bin);

open(my $sfh, '>', "$stub_bin/systemctl") or die $!;
print $sfh "#!/bin/sh\nexit 0\n";
close($sfh);
chmod(0755, "$stub_bin/systemctl");

# A stub `dnsdist` that behaves like the real `--check-config -C FILE`:
# exits 0 for a normal-looking generated config, exits 1 (simulating a
# real Lua/config error) only if the file contains the literal marker
# BROKEN_CONFIG_MARKER.
open(my $dfh, '>', "$stub_bin/dnsdist") or die $!;
print $dfh <<'STUB';
#!/bin/sh
file=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-C" ]; then file="$arg"; fi
    prev="$arg"
done
if grep -q BROKEN_CONFIG_MARKER "$file" 2>/dev/null; then
    echo "simulated dnsdist config error" >&2
    exit 1
fi
exit 0
STUB
close($dfh);
chmod(0755, "$stub_bin/dnsdist");
local $ENV{PATH} = "$stub_bin:$ENV{PATH}";

my $backends_yml   = "$cfg_dir/backends.yml";
my $dnsdist_config = "$work/dnsdist.conf";

open(my $fh, '>', $backends_yml) or die $!;
print $fh <<YAML;
listen_address: 0.0.0.0:53
servers:
  - 10.50.2.162:53
check_interval: 10
check_timeout: 2
max_check_failures: 3
rise: 2
use_proxy_protocol: true
YAML
close($fh);

local $ENV{HOMELAB_DNSDIST_BACKENDS} = $backends_yml;
local $ENV{HOMELAB_DNSDIST_CONFIG}   = $dnsdist_config;

my $output = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 on a valid config') or diag($output);
like($output, qr/applied 1 server\(s\), listening on 0\.0\.0\.0:53, restarted/, 'reports servers applied and the listener');

ok(-f $dnsdist_config, 'dnsdist.conf was written');
my $cfg = do { local (@ARGV, $/) = $dnsdist_config; <> };
like($cfg, qr/addLocal\("0\.0\.0\.0:53"\)/, 'listen address present');
like($cfg, qr/address\s*=\s*"10\.50\.2\.162:53"/, 'backend address present');
unlike($cfg, qr/pool\s*=/, 'no pool= parameter is ever emitted -- a named pool orphans a server from dnsdist\'s real default-pool query routing unless a matching rule also exists, which this script never writes')
    or diag($cfg);
like($cfg, qr/useProxyProtocol\s*=\s*true/, 'proxy protocol enabled by default');
like($cfg, qr/checkInterval\s*=\s*10/, 'check interval present');
like($cfg, qr/maxCheckFailures\s*=\s*3/, 'max check failures present');
like($cfg, qr/rise\s*=\s*2/, 'rise present');

# Idempotency: re-run with the same input, must succeed again and
# fully regenerate (not merge/duplicate).
my $output2 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'second run also exits 0');
my $cfg2 = do { local (@ARGV, $/) = $dnsdist_config; <> };
is(( () = $cfg2 =~ /newServer/g ), 1, 'backend is not duplicated on a second run');

# Validation failure must NOT clobber the previously-working config.
open(my $bfh, '>', $backends_yml) or die $!;
print $bfh <<YAML;
listen_address: 0.0.0.0:53
servers:
  - BROKEN_CONFIG_MARKER:53
YAML
close($bfh);

my $before  = do { local (@ARGV, $/) = $dnsdist_config; <> };
my $output3 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
isnt($? >> 8, 0, 'script exits non-zero when dnsdist --check-config rejects the new config');
like($output3, qr/validation failed/, 'reports validation failure clearly');
my $after = do { local (@ARGV, $/) = $dnsdist_config; <> };
is($after, $before, 'the previously-working config is left untouched after a validation failure');

# use_proxy_protocol: false must actually turn it off (not just default
# to on regardless of the answer).
open(my $nfh, '>', $backends_yml) or die $!;
print $nfh <<YAML;
listen_address: 0.0.0.0:53
servers:
  - 10.50.2.162:53
use_proxy_protocol: false
YAML
close($nfh);

my $output4 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 with proxy protocol disabled') or diag($output4);
my $cfg4 = do { local (@ARGV, $/) = $dnsdist_config; <> };
like($cfg4, qr/useProxyProtocol\s*=\s*false/, 'proxy protocol correctly disabled when configured off');

# Multiple servers -- HA backend group, all in the real default pool.
open(my $mfh, '>', $backends_yml) or die $!;
print $mfh <<YAML;
listen_address: 0.0.0.0:53
servers:
  - 10.50.2.162:53
  - 10.50.2.163:53
YAML
close($mfh);

my $output5 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 with multiple servers') or diag($output5);
like($output5, qr/applied 2 server\(s\), listening on 0\.0\.0\.0:53, restarted/, 'reports both servers applied');
my $cfg5 = do { local (@ARGV, $/) = $dnsdist_config; <> };
is(( () = $cfg5 =~ /newServer/g ), 2, 'both servers get their own newServer entry');
unlike($cfg5, qr/pool\s*=/, 'still no pool= parameter with multiple servers');

# acl: unset by default -- dnsdist's own built-in ACL (RFC1918 +
# loopback + link-local only) stays in force, no setACL() emitted.
unlike($cfg5, qr/setACL/, 'no setACL() when acl is not configured -- dnsdist keeps its own safe-by-default ACL');

# acl: explicitly opening it up for a real public-facing nameserver
# must actually emit setACL() -- this is what makes external resolvers
# work at all; found live, a perfectly-working dnsdist+backend setup
# still had every external query time out until this was added.
open(my $afh, '>', $backends_yml) or die $!;
print $afh <<YAML;
listen_address: 0.0.0.0:53
servers:
  - 10.50.2.162:53
acl:
  - "0.0.0.0/0"
  - "::/0"
YAML
close($afh);

my $output6 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 with an explicit acl') or diag($output6);
my $cfg6 = do { local (@ARGV, $/) = $dnsdist_config; <> };
like($cfg6, qr/setACL\(\{"0\.0\.0\.0\/0", "::\/0"\}\)/, 'setACL() emitted with the configured CIDRs when acl is set');

# listen_addresses (post-cutover #64): a list gives one addLocal() per
# entry, so the edges answer on IPv4 and IPv6; the manifest's tcp_port
# comes from the first entry.
my $manifest_dir = "$work/services";
make_path($manifest_dir);
local $ENV{HOMELAB_SERVICES_MANIFEST_DIR} = $manifest_dir;
open(my $lfh, '>', $backends_yml) or die $!;
print $lfh <<YAML;
listen_addresses:
  - 0.0.0.0:53
  - "[::]:53"
servers:
  - 10.50.2.162:53
YAML
close($lfh);

my $output7 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 with two listen addresses') or diag($output7);
like($output7, qr/listening on 0\.0\.0\.0:53, \[::\]:53, restarted/, 'reports both listeners');
my $cfg7 = do { local (@ARGV, $/) = $dnsdist_config; <> };
like($cfg7, qr/addLocal\("0\.0\.0\.0:53"\)\naddLocal\("\[::\]:53"\)/, 'one addLocal() per listen address, in order');
is(( () = $cfg7 =~ /addLocal/g ), 2, 'exactly two listeners');
ok(-f "$manifest_dir/dnsdist.yml", 'manifest written');
my $manifest = do { local (@ARGV, $/) = "$manifest_dir/dnsdist.yml"; <> };
like($manifest, qr/tcp_port:\s*'?53'?/, 'manifest check port comes from the first listen address');

# A single `listen_addresses` scalar is accepted too; an entry without a
# port is refused before dnsdist ever sees it.
open(my $sfh2, '>', $backends_yml) or die $!;
print $sfh2 <<YAML;
listen_addresses: "[::]:53"
servers:
  - 10.50.2.162:53
YAML
close($sfh2);
my $output8 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
is($? >> 8, 0, 'a scalar listen_addresses is accepted') or diag($output8);
my $cfg8 = do { local (@ARGV, $/) = $dnsdist_config; <> };
like($cfg8, qr/addLocal\("\[::\]:53"\)/, 'scalar listen_addresses becomes the one listener');

open(my $sfh3, '>', $backends_yml) or die $!;
print $sfh3 <<YAML;
listen_addresses:
  - 0.0.0.0
servers:
  - 10.50.2.162:53
YAML
close($sfh3);
my $output9 = `perl script/homelab-dnsdist-apply-backends 2>&1`;
isnt($? >> 8, 0, 'a listen address without a port is refused');
like($output9, qr/must be host:port/, 'says why');

done_testing;
