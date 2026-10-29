use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp ();
use File::Path qw(make_path);
use File::Spec ();

# Homelab::CertServer::Signer resolves both of these with `use constant`
# at load time, so they have to be set before it is loaded -- which is
# why this is a runtime require() rather than a compile-time use().
my $TMP      = File::Temp->newdir(TEMPLATE => 'signer-t-XXXXXX', TMPDIR => 1);
my $root     = $TMP->dirname;
my $material = File::Spec->catdir($root, 'material');
my $config   = File::Spec->catfile($root, 'cert-sign.yml');
$ENV{HOMELAB_CERT_SIGN_CONFIG}   = $config;
$ENV{HOMELAB_CERT_SIGN_MATERIAL} = $material;

require Homelab::CertServer::Signer;
Homelab::CertServer::Signer->import(
    qw(load_sign_config lineage_entries lineage_names
       signable_lineages sign_profile_bytes));

my $LINEAGE = 'sign-test.example';

open(my $cfh, '>', $config) or die "cannot write $config: $!";
print {$cfh} "api_base: http://127.0.0.1:3000\nlineages:\n  - $LINEAGE\n";
close $cfh;

my $cfg = load_sign_config();
is_deeply lineage_names($cfg), [$LINEAGE], 'config parses and exposes the allow-list';

# Both entry shapes: a bare name (a certbot lineage on this host) and a
# hash of explicit paths (an identity from anywhere else). The second
# exists so the answer to "does iOS need an emailProtection EKU" is a
# config change rather than a code change -- see lineage_entries().
{
    my $mixed = { lineages => [
        'plain.example',
        { name => 'explicit.example', cert => '/c', chain => '/h', privkey => '/k' },
        { cert => '/c' },            # no name: ignored
        '',                          # empty: ignored
    ] };
    is_deeply lineage_names($mixed), ['plain.example', 'explicit.example'],
        'both entry shapes are accepted, nameless and empty ones dropped';
    my $e = lineage_entries($mixed);
    ok !$e->[0]{explicit}, 'a bare name is sourced from certbot';
    ok $e->[1]{explicit},  'a hash entry is sourced from its own paths';
    is $e->[1]{privkey}, '/k', '  ... and carries them through';
}

# --- The allow-list is the real control over what this host will put its
# signature on, so it is the first thing tested. A lineage name also
# becomes a path component, so traversal shapes are checked explicitly
# even though the allow-list already excludes them.
for my $bad ('other.example', '../../etc/passwd', 'sign-test.example/../x', '') {
    my $ok = eval { sign_profile_bytes($bad, 'x', $cfg); 1 };
    ok !$ok, "refuses lineage '$bad'";
}

# --- Configured but not materialized: usable answer, not a crash -------
my $before = signable_lineages($cfg);
is scalar @$before, 1, 'one configured lineage';
ok !${ $before->[0]{ready} }, 'not ready before the material is in place';
my $unready = eval { sign_profile_bytes($LINEAGE, 'x', $cfg); 1 };
ok !$unready, 'signing a non-materialized lineage fails loudly';
like $@, qr/materialized/, '  ... and says what is missing';

# A throwaway self-signed identity. Self-signed is the right choice here:
# this test is about the PKCS#7 structure and the content round-trip, not
# about whether a device would trust the signer -- that is a property of
# the certificate, not of this code.
sub make_identity {
    my $dir = File::Spec->catdir($material, $LINEAGE);
    make_path($dir);
    my $cert = File::Spec->catfile($dir, 'cert.pem');
    my $key  = File::Spec->catfile($dir, 'privkey.pem');
    return 0 unless _quietly('openssl', 'req', '-x509', '-newkey', 'rsa:2048',
        '-nodes', '-keyout', $key, '-out', $cert, '-days', '2',
        '-subj', "/CN=$LINEAGE", '-batch') == 0;
    return 0 unless -s $cert && -s $key;
    # A self-signed certificate has no intermediates to ship, but the
    # signing command always passes -certfile, so it needs something valid.
    open(my $in,  '<', $cert) or return 0;
    open(my $out, '>', File::Spec->catfile($dir, 'chain.pem')) or return 0;
    print {$out} do { local $/; <$in> };
    close $in;
    close $out;
    return 1;
}

# openssl writes progress and "Verification successful" to stderr even
# when it succeeds; that is noise in a TAP stream, not information.
sub _quietly {
    my @cmd = @_;
    open(my $saved, '>&', \*STDERR) or die "cannot save STDERR: $!";
    open(STDERR, '>', File::Spec->devnull) or die "cannot silence STDERR: $!";
    my $rc = system(@cmd);
    open(STDERR, '>&', $saved) or die "cannot restore STDERR: $!";
    return $rc;
}

SKIP: {
    skip 'openssl could not create a test identity', 7 unless make_identity();

    my $after = signable_lineages($cfg);
    ok ${ $after->[0]{ready} }, 'ready once cert, chain and key are present';
    like $after->[0]{subject}, qr/\Q$LINEAGE\E/, 'reports the signer subject';
    ok length($after->[0]{not_after} // ''), 'reports an expiry';

    # A real-shaped document on purpose: a signer only ever exercised
    # with "x" would not catch a canonicalization problem that mangles
    # XML, and mangled XML is a profile iOS silently will not install.
    my $doc = <<'PLIST';
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>Note</key>
  <string>quotes " ampersand &amp; angle &lt;</string>
</dict>
</plist>
PLIST

    my ($der) = sign_profile_bytes($LINEAGE, $doc, $cfg);
    ok length($der) > 500, 'produced a plausibly sized PKCS#7 envelope';
    # A DER SEQUENCE tag. Not a deep parse -- just enough to catch the
    # single most likely regression here, which is emitting openssl's
    # default base64 MIME form instead of the binary DER iOS expects.
    is substr($der, 0, 1), chr(0x30), 'output is DER, not base64 MIME';

    # -nodetach is the flag that embeds the document in the envelope.
    # Without it the signature would be over a document the device never
    # receives, and the download would install nothing at all. Recovering
    # the content from the envelope is what proves it is in there.
    my $sig = File::Spec->catfile($root, 'signed.p7');
    open(my $sfh, '>:raw', $sig) or die $!;
    print {$sfh} $der;
    close $sfh;

    my $recovered = File::Spec->catfile($root, 'recovered.txt');
    is _quietly('openssl', 'smime', '-verify', '-inform', 'DER',
        '-in', $sig, '-noverify', '-out', $recovered), 0,
        'the envelope verifies and the content comes back out';

    open(my $rfh, '<:raw', $recovered) or die $!;
    my $got = do { local $/; <$rfh> };
    close $rfh;

    # Line endings are normalized before comparing because openssl's
    # S/MIME layer canonicalizes text content to CRLF. That is expected
    # and harmless -- a plist parses either way -- but a raw byte
    # comparison would fail for that reason rather than a real one.
    my $want = $doc;
    s/\r\n/\n/g for $got, $want;
    is $got, $want, 'the signed document is byte-identical to the input';
}

done_testing;
