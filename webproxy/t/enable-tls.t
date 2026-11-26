use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

# _enable_tls_for rewrites an HTTP-only vhost into TLS + a :80 redirect, using
# a certificate that is already on disk (from the fleet cert store) instead of
# calling certbot. A standby edge holds no ACME account, so this is the ONLY
# path that works there -- and a malformed rewrite breaks `nginx -t`, which
# takes down EVERY vhost on the host, so the output shape is worth asserting.
#
# Regression: an earlier version built the redirect block with qq{...} and a
# literal '}' inside it closed the quote early, emitting the rest of the Perl
# expression into the config as text (`unknown directive "."`).

my $script = 'script/homelab-webproxy-apply-sites';
my $src = do { open(my $fh, '<', $script) or die $!; local $/; <$fh> };
# pull the sub out and eval it in isolation
my ($sub) = $src =~ /(sub _enable_tls_for \{.*?\n\}\n)/s;
ok($sub, 'found _enable_tls_for in the script');
eval "$sub; 1" or die "cannot eval sub: $@";

my $dir = tempdir(CLEANUP => 1);
my $live = "$dir/live/example.test";
mkdir "$dir/live"; mkdir $live;
for my $f (qw(fullchain.pem privkey.pem)) { open(my $fh,'>',"$live/$f"); print $fh "x"; close $fh }

my $vhost = "$dir/example.test";
open(my $fh, '>', $vhost) or die $!;
print $fh <<'CONF';
server {
    listen 80;
    listen [::]:80;
    server_name example.test;
    client_max_body_size 100m;
    location / {
        proxy_pass http://10.0.0.1:80;
    }
}
CONF
close $fh;

ok(_enable_tls_for($vhost, 'example.test', $live), 'rewrite reports success');
my $out = do { open(my $o,'<',$vhost) or die $!; local $/; <$o> };

like($out,   qr/ssl_certificate \Q$live\E\/fullchain\.pem;/, 'cert path wired');
like($out,   qr/ssl_certificate_key \Q$live\E\/privkey\.pem;/, 'key path wired');
like($out,   qr/listen 443 ssl;/,                 'TLS listener added');
like($out,   qr/return 301 https:\/\/\$host\$request_uri;/, 'redirect preserved as an nginx variable, not interpolated');
like($out,   qr/proxy_pass http:\/\/10\.0\.0\.1:80;/, 'original proxy_pass survives');

# THE regression: no stray Perl leaked into the config.
unlike($out, qr/qq\{/,            'no literal qq{ leaked into the config');
unlike($out, qr/^\s*\.\s/m,       'no stray concatenation operator leaked (the nginx "unknown directive ." bug)');

# braces must balance or nginx -t fails and takes every vhost with it
my $open  = ($out =~ tr/{//);
my $close = ($out =~ tr/}//);
is($open, $close, 'braces balance in the rewritten vhost');

# exactly two server blocks: the TLS one and the redirect
my $servers = () = $out =~ /^server \{/mg;
is($servers, 2, 'exactly two server blocks (TLS + redirect)');

# the plain :80 listener must have moved OUT of the TLS block
my ($tls_block) = $out =~ /\A(.*?)^\}/ms;
unlike($tls_block, qr/listen\s+(\[::\]:)?80;/, 'plain :80 listener removed from the TLS block');

# idempotent: running again on an already-TLS vhost is a no-op
ok(!_enable_tls_for($vhost, 'example.test', $live), 'second run is a no-op (already has TLS)');

# --- aliases (post-cutover #106): the redirect block answers for every name
#     of the main block, not just the lineage's domain ---
my $vhost2 = "$dir/7redlines.test";
open($fh, '>', $vhost2) or die $!;
print $fh <<'CONF';
server {
    listen 80;
    listen [::]:80;
    server_name 7redlines.test *.7redlines.test;
    location / {
        proxy_pass http://10.0.0.2:80;
    }
}
CONF
close $fh;
ok(_enable_tls_for($vhost2, '7redlines.test', $live), 'rewrite of an aliases vhost reports success');
my $out2 = do { open(my $o,'<',$vhost2) or die $!; local $/; <$o> };
my @names = $out2 =~ /^\s*server_name\s+([^;]+);/mg;
is(scalar(@names), 2, 'two server_name lines (TLS block + redirect)');
is($names[0], '7redlines.test *.7redlines.test', 'the TLS block keeps every name');
is($names[1], '7redlines.test *.7redlines.test', 'the :80 redirect answers for every name too');

done_testing;
