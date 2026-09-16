use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Exercises the real script end-to-end (templating, validate-before-
# apply, idempotency, and refusing to clobber a working config on a
# validation failure) using temp files and a stub `haproxy`/`systemctl`
# on PATH — tests our own generation/safety logic without needing a
# real haproxy install.

my $work    = tempdir(CLEANUP => 1);
my $cfg_dir = "$work/config";
make_path($cfg_dir);

my $stub_bin = "$work/stubbin";
make_path($stub_bin);

open(my $sfh, '>', "$stub_bin/systemctl") or die $!;
print $sfh "#!/bin/sh\nexit 0\n";
close($sfh);
chmod(0755, "$stub_bin/systemctl");

# A stub haproxy that behaves like the real `-c -f FILE` check: exits 0
# for a normal-looking generated config, exits 1 (simulating a real
# syntax error) only if the file contains the literal marker
# BROKEN_CONFIG_MARKER — lets the "validation failure must not touch
# the live config" path be tested without a real haproxy binary or a
# genuinely-broken config our own generator would never produce.
open(my $hfh, '>', "$stub_bin/haproxy") or die $!;
print $hfh <<'STUB';
#!/bin/sh
file=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-f" ]; then file="$arg"; fi
    prev="$arg"
done
if grep -q BROKEN_CONFIG_MARKER "$file" 2>/dev/null; then
    echo "simulated haproxy config error" >&2
    exit 1
fi
exit 0
STUB
close($hfh);
chmod(0755, "$stub_bin/haproxy");
local $ENV{PATH} = "$stub_bin:$ENV{PATH}";

my $backends_yml = "$cfg_dir/backends.yml";
my $haproxy_cfg  = "$work/haproxy.cfg";

open(my $fh, '>', $backends_yml) or die $!;
print $fh <<YAML;
backends:
  - name: smtp
    frontend_port: 25
    backend: 10.50.1.201:25
    maxconn: 250
  - name: imaps
    frontend_port: 993
    backend: 10.50.1.202:993
YAML
close($fh);

local $ENV{HOMELAB_HAPROXY_BACKENDS} = $backends_yml;
local $ENV{HOMELAB_HAPROXY_CONFIG}   = $haproxy_cfg;

my $output = `perl script/homelab-haproxy-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 on a valid config') or diag($output);
like($output, qr/applied 2 backend\(s\), reloaded/, 'reports how many backends were applied');

ok(-f $haproxy_cfg, 'haproxy.cfg was written');
my $cfg = do { local (@ARGV, $/) = $haproxy_cfg; <> };
like($cfg, qr/frontend smtp_in/, 'smtp frontend block present');
like($cfg, qr/bind \*:25/, 'smtp frontend binds the right port');
like($cfg, qr/server smtp 10\.50\.1\.201:25 check send-proxy/, 'smtp backend targets the right host:port, with send-proxy');
like($cfg, qr/frontend smtp_in\s+bind \*:25\s+maxconn 250/, 'smtp frontend uses its own explicit maxconn');
like($cfg, qr/frontend imaps_in/, 'imaps frontend block present');
like($cfg, qr/bind \*:993/, 'imaps frontend binds the right port');
like($cfg, qr/server imaps 10\.50\.1\.202:993 check send-proxy/, 'imaps backend targets the right host:port, with send-proxy');
like($cfg, qr/frontend imaps_in\s+bind \*:993\s+maxconn 500/, 'imaps frontend defaults maxconn to 500 when unset');
unlike($cfg, qr/__[A-Z_]+__/, 'no template placeholders left unsubstituted');

# Idempotency: re-run with the same input, must succeed again and
# fully regenerate (not merge/duplicate) the file.
my $output2 = `perl script/homelab-haproxy-apply-backends 2>&1`;
is($? >> 8, 0, 'second run also exits 0');
my $cfg2 = do { local (@ARGV, $/) = $haproxy_cfg; <> };
is(( () = $cfg2 =~ /frontend smtp_in/g ), 1, 'smtp frontend is not duplicated on a second run');

# Validation failure must NOT clobber the previously-working config.
open(my $bfh, '>', $backends_yml) or die $!;
print $bfh <<YAML;
backends:
  - name: BROKEN_CONFIG_MARKER
    frontend_port: 26
    backend: 10.50.1.201:26
YAML
close($bfh);

my $before  = do { local (@ARGV, $/) = $haproxy_cfg; <> };
my $output3 = `perl script/homelab-haproxy-apply-backends 2>&1`;
isnt($? >> 8, 0, 'script exits non-zero when haproxy -c rejects the new config');
like($output3, qr/validation failed/, 'reports validation failure clearly');
my $after = do { local (@ARGV, $/) = $haproxy_cfg; <> };
is($after, $before, 'the previously-working config is left untouched after a validation failure');

# 'backends' (a list) -- HA/load-balanced group, added for 3x dovecot/
# postfix instances behind one HAProxy. Must coexist with 'backend'
# (single) entries in the same file, and must NOT emit `balance` for a
# single-server entry (nothing to balance).
open(my $mfh, '>', $backends_yml) or die $!;
print $mfh <<YAML;
backends:
  - name: imap
    frontend_port: 143
    backends:
      - 10.50.2.45:143
      - 10.50.2.50:143
      - 10.50.2.56:143
  - name: smtp
    frontend_port: 25
    backend: 10.50.2.46:25
YAML
close($mfh);

my $output4 = `perl script/homelab-haproxy-apply-backends 2>&1`;
is($? >> 8, 0, 'script exits 0 with a mix of backend/backends entries') or diag($output4);
my $cfg4 = do { local (@ARGV, $/) = $haproxy_cfg; <> };
like($cfg4, qr/frontend imap_in/, 'multi-backend frontend block present');
like($cfg4, qr/backend imap_out\s+balance roundrobin/, 'multi-backend group gets balance roundrobin');
like($cfg4, qr/server imap1 10\.50\.2\.45:143 check send-proxy/, 'first HA server line present, numbered');
like($cfg4, qr/server imap2 10\.50\.2\.50:143 check send-proxy/, 'second HA server line present, numbered');
like($cfg4, qr/server imap3 10\.50\.2\.56:143 check send-proxy/, 'third HA server line present, numbered');
unlike($cfg4, qr/backend smtp_out\s+balance/, 'single-backend entry gets no balance line -- nothing to balance');
like($cfg4, qr/server smtp 10\.50\.2\.46:25 check send-proxy/, 'single-backend entry keeps its unnumbered server name (backward compat)');

done_testing;
