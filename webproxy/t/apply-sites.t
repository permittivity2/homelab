use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Exercises the real script end-to-end (templating, symlinking,
# idempotency, and retrying a previously-failed cert) using temp dirs
# for everything nginx-related and stub `nginx`/`certbot`/`systemctl`
# commands on PATH — this tests our own file-management logic
# thoroughly without needing a real nginx or a real domain to get a
# real cert for.

my $work       = tempdir(CLEANUP => 1);
my $available  = "$work/sites-available";
my $enabled    = "$work/sites-enabled";
my $config_dir = "$work/config";
make_path($available, $enabled, $config_dir);

my $stub_bin = "$work/stubbin";
make_path($stub_bin);
for my $cmd (qw(nginx systemctl)) {
    open(my $fh, '>', "$stub_bin/$cmd") or die $!;
    print $fh "#!/bin/sh\nexit 0\n";
    close($fh);
    chmod(0755, "$stub_bin/$cmd");
}
# A stub certbot that behaves like the real --nginx plugin for our
# purposes: on success it appends a `listen 443 ssl;` line to the vhost
# file named by -d (which is what our _vhost_has_https() check looks
# for); mail.test.mailmasker.org is hardcoded to fail, simulating the
# real ACME-challenge-timeout scenario hit on test-static-internet-ip.
open(my $cbfh, '>', "$stub_bin/certbot") or die $!;
print $cbfh <<'STUB';
#!/bin/sh
domain=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-d" ]; then domain="$2"; fi
    shift
done
if [ "$domain" = "mail.test.mailmasker.org" ]; then
    echo "simulated ACME challenge timeout" >&2
    exit 1
fi
echo "    listen 443 ssl;" >> "$AVAILABLE_DIR/$domain"
exit 0
STUB
close($cbfh);
chmod(0755, "$stub_bin/certbot");
local $ENV{PATH} = "$stub_bin:$ENV{PATH}";
local $ENV{AVAILABLE_DIR} = $available;    # read by the stub certbot above

my $sites_yml = "$config_dir/sites.yml";
open(my $fh, '>', $sites_yml) or die $!;
print $fh <<YAML;
letsencrypt_email: admin\@test.mailmasker.org
sites:
  - domain: drive.test.mailmasker.org
    upstream: 127.0.0.1:2501
  - domain: mail.test.mailmasker.org
    upstream: 127.0.0.1:8080
YAML
close($fh);

local $ENV{HOMELAB_WEBPROXY_SITES}     = $sites_yml;
local $ENV{HOMELAB_WEBPROXY_TEMPLATE}  = 'config/vhost.conf.template';
local $ENV{HOMELAB_WEBPROXY_AVAILABLE} = $available;
local $ENV{HOMELAB_WEBPROXY_ENABLED}   = $enabled;

my $output = `perl script/homelab-webproxy-apply-sites 2>&1`;
is($? >> 8, 0, 'script exits 0 even when one of two sites fails its cert') or diag($output);
like($output, qr/drive\.test\.mailmasker\.org is live over HTTPS/, 'drive succeeds');
like($output, qr/WARNING: certbot failed for mail\.test\.mailmasker\.org/, 'mail fails, and is reported as a warning, not silently');

for my $domain (qw(drive.test.mailmasker.org mail.test.mailmasker.org)) {
    ok(-f "$available/$domain", "$domain vhost file was created");
    ok(-l "$enabled/$domain", "$domain is symlinked into sites-enabled");
}

my $drive_vhost = do { local (@ARGV, $/) = "$available/drive.test.mailmasker.org"; <> };
like($drive_vhost, qr/server_name drive\.test\.mailmasker\.org;/, 'vhost has the correct server_name');
like($drive_vhost, qr{proxy_pass http://127\.0\.0\.1:2501;}, 'vhost proxies to the correct upstream');
unlike($drive_vhost, qr/__DOMAIN__|__UPSTREAM__/, 'no template placeholders left unsubstituted');
like($drive_vhost, qr/listen 443 ssl/, 'drive vhost has the HTTPS line the stub certbot added');

my $mail_vhost_before_retry = do { local (@ARGV, $/) = "$available/mail.test.mailmasker.org"; <> };
unlike($mail_vhost_before_retry, qr/listen 443 ssl/, 'mail vhost is still HTTP-only after its cert failed');

# Second run: drive (genuinely done) must be left alone; mail (HTTP-only
# after a failed cert) must be RETRIED, not silently skipped forever —
# this is the exact real-world scenario from test-static-internet-ip
# (a firewall blocked the ACME challenge; fixing the firewall and
# re-running must actually pick mail.test.mailmasker.org back up).
my $before_drive = $drive_vhost;
my $output2 = `perl script/homelab-webproxy-apply-sites 2>&1`;
is($? >> 8, 0, 'second run exits 0');
like($output2, qr/drive\.test\.mailmasker\.org already has a vhost with HTTPS configured — skipping/, 'drive (done) is skipped on the second run');
like($output2, qr/mail\.test\.mailmasker\.org has an HTTP-only vhost .* retrying/, 'mail (failed) is retried, not skipped, on the second run');

my $after_drive = do { local (@ARGV, $/) = "$available/drive.test.mailmasker.org"; <> };
is($after_drive, $before_drive, "drive's vhost is untouched by the second run");

done_testing;
