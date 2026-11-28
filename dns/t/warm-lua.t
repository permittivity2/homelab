# homelab-dns-warm-lua (post-cutover #107), dry run: reads pdns.conf + pdns.d,
# lists every LUA record of every zone through pdnsutil (the 5.x verbs, the
# 4.x verbs as a fallback) and names the queries it would send.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $script = "$FindBin::Bin/../script/homelab-dns-warm-lua";
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/pdns.d";
sub put { my ($f, $body) = @_; open my $fh, '>', $f or die $!; print $fh $body; close $fh }
put("$dir/pdns.conf", "# stock\nlocal-address=127.0.0.1\nlaunch=\n");
put("$dir/pdns.d/90-homelab-dns.conf", "launch+=gpgsql\nlocal-port=5300\n");
put("$dir/pdns.d/95-health.conf", "lua-health-checks-interval=7\n");

my $zone5 = <<'Z';
api.mailmasker.org	120	IN	LUA	A "ifportup(443, {'23.116.91.66','23.116.91.67'}, {selector='all'})"
api.mailmasker.org	120	IN	LUA	AAAA ";local up=ifportup(443, {'23.116.91.66'}) return up"
mailmasker.org	3600	IN	SOA	ns1.mailmasker.org hostmaster.mailmasker.org 1 10800 3600 604800 3600
www.mailmasker.org	120	IN	LUA	A "ifportup(443, {'23.116.91.66'})"
Z
my $zone_plain = "example.org\t3600\tIN\tSOA\tns1.example.org hostmaster.example.org 1 10800 3600 604800 3600\nwww.example.org\t300\tIN\tA\t192.0.2.1\n";

sub fake_pdnsutil {    # verbs => 'new' | 'old'
    my ($verbs) = @_;
    my ($la, $lz) = $verbs eq 'new' ? ('zone list-all', 'zone list') : ('list-all-zones', 'list-zone');
    my $z5 = $zone5; my $zp = $zone_plain;
    put("$dir/pdnsutil", <<"P");
#!/usr/bin/perl
my \$a = join ' ', \@ARGV;
if (\$a eq '$la') { print "mailmasker.org\\nexample.org\\n"; exit 0 }
if (\$a eq '$lz mailmasker.org') { print <<'X';
$z5
X
exit 0 }
if (\$a eq '$lz example.org') { print <<'X';
$zp
X
exit 0 }
print STDERR "unknown verb: \$a\\n"; exit 1;
P
    chmod 0755, "$dir/pdnsutil";
}

local $ENV{PDNS_CONF_DIR} = $dir;
local $ENV{PDNSUTIL}      = "$dir/pdnsutil";

for my $verbs ('new', 'old') {
    fake_pdnsutil($verbs);
    my $out = `$^X $script --dry-run 2>&1`;
    is($? >> 8, 0, "$verbs verbs: exits 0");
    like($out, qr/^config: 127\.0\.0\.1:5300, lua-health-checks-interval 7$/m, "$verbs verbs: pdns.d overrides read (port, interval)");
    like($out, qr/^zones: 2; Lua records: 3$/m, "$verbs verbs: two zones, three Lua records (the SOA and the plain A are not)");
    like($out, qr/^would query A api\.mailmasker\.org$/m,    "$verbs verbs: A record named");
    like($out, qr/^would query AAAA api\.mailmasker\.org$/m, "$verbs verbs: AAAA record named by its own type");
    like($out, qr/^would query A www\.mailmasker\.org$/m,    "$verbs verbs: the second zone's record too");
    unlike($out, qr/example\.org/, "$verbs verbs: a zone without Lua records is not queried");
}

# no zones at all: says so and still exits 0 (the unit must never fail on it)
put("$dir/pdnsutil", "#!/bin/sh\nexit 1\n"); chmod 0755, "$dir/pdnsutil";
my $out = `$^X $script --dry-run 2>&1`;
is($? >> 8, 0, 'pdnsutil failing: exits 0');
like($out, qr/no zones listed/, 'pdnsutil failing: reported, nothing to warm');
done_testing;
