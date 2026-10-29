package Homelab::CertServer::Signer;
use v5.36;

# Apple configuration-profile signing, on the ONE host that already holds
# every private key the fleet has -- because it is the host that issues
# them.
#
# WHY SIGNING HAPPENS HERE AND NOT WHERE THE PROFILE IS SERVED.
#
# homelab-invite and homelab-accountmanage both serve .mobileconfig
# downloads, from six hosts between them. Signing there would need a
# certificate and key on all six, and the ready-made way to get one is
# homelab-certsync -- which decrypts with `key_encryption_key`, a
# FLEET-WIDE key that opens every lineage in the store, mail.<domain>
# included. Six more copies of that, to turn one red word green on an
# install screen, is a trade worth refusing.
#
# So the key stays put and the bytes travel. Homelab::Common::ProfileSigner
# (in homelab-common, used by both app packages) POSTs the PARAMETERS of a
# mail profile here; this module builds the plist and signs it.
#
# IT DOES NOT SIGN WHAT IT IS GIVEN. Accepting arbitrary bytes would make
# this a general signing oracle for a key that also terminates TLS for a
# public hostname. It accepts parameters, builds the document itself with
# the same Homelab::Common::AppleProfile every caller uses, and signs
# that. Everything it can be made to emit is a mail-configuration plist.
#
# WHAT IT READS. Never /etc/letsencrypt directly, and never this host's
# cert-server.yml -- that file holds the KEK and is root-only 0600. It
# reads a MATERIALIZED copy under /var/lib/homelab-cert-sign, placed
# there by homelab-cert-sign-materialize (root, at daemon start and after
# each renewal) and readable only by the unprivileged user the daemon
# runs as. The daemon therefore never holds the KEK and never needs root.

use Exporter 'import';
our @EXPORT_OK = qw(
    load_sign_config lineage_entries lineage_names
    signable_lineages sign_profile_bytes
    MATERIAL_DIR SIGN_CONFIG_FILE
);

use YAML::XS qw(LoadFile);
use File::Temp ();
use File::Spec ();

use constant SIGN_CONFIG_FILE => $ENV{HOMELAB_CERT_SIGN_CONFIG}
    // '/etc/homelab/cert-server/cert-sign.yml';
use constant MATERIAL_DIR => $ENV{HOMELAB_CERT_SIGN_MATERIAL}
    // '/var/lib/homelab-cert-sign';

# Deliberately a SEPARATE file from cert-server.yml. That one is 0600
# root because it carries the key-encryption-key; this one is 0640
# root:homelab-certsign and carries nothing secret at all, which is what
# lets the network-facing daemon read its own configuration without
# being able to read the KEK.
sub load_sign_config {
    my $path = SIGN_CONFIG_FILE;
    die "cert-sign: no config at $path\n" unless -f $path;
    my $cfg = eval { LoadFile($path) } or die "cert-sign: cannot parse $path: $@\n";
    die "cert-sign: $path is not a YAML mapping\n" unless ref $cfg eq 'HASH';
    die "cert-sign: api_base is required in $path\n"
        unless $cfg->{api_base} && $cfg->{api_base} =~ m{^https?://};
    $cfg->{lineages} = [] unless ref $cfg->{lineages} eq 'ARRAY';
    return $cfg;
}

# A `lineages:` entry is either a NAME (a certbot lineage issued on this
# host, the normal case) or a hash giving explicit cert/chain/privkey
# paths.
#
# The second form exists because of a genuinely open question about what
# iOS requires of a profile signer. A Let's Encrypt certificate carries
# `extendedKeyUsage: serverAuth` and nothing else; openssl's own S/MIME
# purpose check rejects it ("unsuitable certificate purpose"), and the
# field is split on whether iOS applies that check or simply validates
# the chain. Many people report a plain TLS certificate yielding a green
# "Verified"; at least one signing tool states flatly that
# emailProtection is required.
#
# Rather than bet the feature on the answer, the hard part -- getting
# signed bytes from a host that holds a key to a host that does not --
# is made independent of WHICH identity signs. If the TLS lineage turns
# out not to satisfy iOS, an identity that does (an S/MIME certificate
# from any publicly trusted CA) is dropped on this host and named here.
# No code changes, and the fallback means the worst case throughout is
# the unsigned profile this fleet already shipped.
sub lineage_entries ($cfg) {
    my @out;
    for my $e (@{ $cfg->{lineages} // [] }) {
        if (ref $e eq 'HASH') {
            next unless $e->{name};
            push @out, { %$e, explicit => 1 };
        }
        elsif (defined $e && length $e) {
            push @out, { name => $e, explicit => 0 };
        }
    }
    return \@out;
}

# Just the names, which is all the allow-list check needs.
sub lineage_names ($cfg) {
    return [ map { $_->{name} } @{ lineage_entries($cfg) } ];
}

# A lineage name reaches this module from an HTTP request body, and it is
# about to become a path component. The allow-list in config is the real
# control -- a name not on it is refused before it gets here -- but a
# shape check costs nothing and means a mistake in that ordering is not
# also a path traversal.
sub _safe_lineage ($name) {
    return 0 unless defined $name && length $name && length($name) <= 253;
    return 0 if $name =~ m{[/\\]} || $name =~ /\.\./ || $name =~ /^[.-]/;
    return $name =~ /\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/ ? 1 : 0;
}

sub _material_paths ($lineage) {
    my $dir = File::Spec->catdir(MATERIAL_DIR, $lineage);
    return {
        dir     => $dir,
        cert    => File::Spec->catfile($dir, 'cert.pem'),
        chain   => File::Spec->catfile($dir, 'chain.pem'),
        privkey => File::Spec->catfile($dir, 'privkey.pem'),
    };
}

# Cached by (path, mtime, size) so a renewal invalidates it without any
# explicit signal, and an unchanged certificate costs no fork.
my %META;
sub _cert_meta ($path) {
    my @st = stat $path or return undef;
    my $key = "$path|$st[9]|$st[7]";
    return $META{$key} if $META{$key};

    my ($rc, $out, $err) = _run('openssl', 'x509', '-noout', '-subject', '-enddate',
        '-ext', 'extendedKeyUsage', '-in', $path);
    return undef unless $rc == 0;
    my ($subject) = $out =~ /^subject=\s*(.+)$/m;
    my ($end)     = $out =~ /^notAfter=(.+)$/m;
    for ($subject, $end) { s/\s+$// if defined $_ }

    # The EKU is surfaced, not enforced. See lineage_entries() for why
    # it is an open question rather than a rule: a certificate without
    # emailProtection MAY still produce a green "Verified" on iOS, and
    # refusing to sign with one here would remove the only cheap way to
    # find out. Reporting it means that when a profile still installs as
    # "Unverified", the reason is one HTTP call away instead of a
    # mystery.
    my $eku = ($out =~ /extendedKeyUsage[^\n]*\n((?:\s+\S[^\n]*\n?)+)/) ? $1 : '';
    $eku =~ s/\s+/ /g;
    $eku =~ s/^ | $//g;

    # One entry per (lineage, renewal); a long-lived worker sees a
    # handful over its life, so no eviction is needed.
    return $META{$key} = {
        subject   => $subject,
        not_after => $end,
        eku       => $eku,
        smime_eku => ($eku =~ /E-?mail Protection/i) ? 1 : 0,
    };
}

# Which lineages this host can actually sign with right now: configured,
# materialized, and with all three files present. Used by /health and by
# the lineages endpoint, so an expiring signing certificate is visible
# before it starts handing back failures.
sub signable_lineages ($cfg) {
    my @out;
    for my $e (@{ lineage_entries($cfg) }) {
        my $lineage = $e->{name};
        next unless _safe_lineage($lineage);
        my $p = _material_paths($lineage);
        my $ready = (-r $p->{cert} && -r $p->{chain} && -r $p->{privkey}) ? 1 : 0;
        my $meta = $ready ? _cert_meta($p->{cert}) : undef;
        push @out, {
            lineage   => $lineage,
            ready     => $ready ? \1 : \0,
            subject   => $meta ? $meta->{subject}   : undef,
            not_after => $meta ? $meta->{not_after} : undef,
            eku       => $meta ? $meta->{eku}       : undef,
            smime_eku => ($meta && $meta->{smime_eku}) ? \1 : \0,
        };
    }
    return \@out;
}

# system() with stderr captured, no shell anywhere. Returns
# (exit code, stdout, stderr).
sub _run (@cmd) {
    my $outf = File::Temp->new(TEMPLATE => 'certsign-out-XXXXXX', TMPDIR => 1);
    my $errf = File::Temp->new(TEMPLATE => 'certsign-err-XXXXXX', TMPDIR => 1);

    open(my $saved_out, '>&', \*STDOUT) or die "cert-sign: cannot save STDOUT: $!\n";
    open(my $saved_err, '>&', \*STDERR) or die "cert-sign: cannot save STDERR: $!\n";
    open(STDOUT, '>', $outf->filename)  or die "cert-sign: cannot redirect STDOUT: $!\n";
    open(STDERR, '>', $errf->filename)  or die "cert-sign: cannot redirect STDERR: $!\n";

    my $rc = system(@cmd);

    open(STDOUT, '>&', $saved_out) or die "cert-sign: cannot restore STDOUT: $!\n";
    open(STDERR, '>&', $saved_err) or die "cert-sign: cannot restore STDERR: $!\n";

    return ($rc == -1 ? -1 : $rc >> 8, _slurp($outf->filename), _slurp($errf->filename));
}

sub _slurp ($path) {
    open(my $fh, '<:raw', $path) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# sign_profile_bytes($lineage, $bytes, $cfg) -> (DER, \%meta)
#
# Dies with a short message on any failure; the HTTP layer turns that
# into a 4xx/5xx and the CLIENT falls back to serving unsigned bytes. An
# expired signing certificate must degrade to a red "Unverified" label,
# never to a failed download.
sub sign_profile_bytes ($lineage, $bytes, $cfg) {
    die "cert-sign: refusing unknown lineage\n"
        unless _safe_lineage($lineage) && grep { $_ eq $lineage } @{ lineage_names($cfg) };
    die "cert-sign: empty document\n" unless defined $bytes && length $bytes;

    my $p = _material_paths($lineage);
    for my $f (qw(cert chain privkey)) {
        die "cert-sign: $lineage has no materialized $f (run homelab-cert-sign-materialize)\n"
            unless -r $p->{$f};
    }

    my $dir  = File::Temp->newdir(TEMPLATE => 'certsign-XXXXXX', TMPDIR => 1);
    my $in   = File::Spec->catfile($dir->dirname, 'profile.mobileconfig');
    my $out  = File::Spec->catfile($dir->dirname, 'profile.signed');
    open(my $fh, '>:raw', $in) or die "cert-sign: cannot write $in: $!\n";
    print $fh $bytes;
    close $fh or die "cert-sign: cannot close $in: $!\n";

    # -nodetach is the one flag that is not optional: a detached
    # signature leaves the profile OUT of the PKCS#7 envelope, and what
    # iOS installs is the envelope. Omit it and the download is a
    # signature over a document the device never sees.
    #
    # -outform DER because a configuration profile is served as binary
    # PKCS#7, not as the base64 MIME body `smime` writes by default.
    #
    # -md sha256 pinned rather than left to the local openssl default --
    # the default is correct on openssl 3, and this is not a value to
    # discover has drifted on some future host.
    my ($rc, undef, $err) = _run(
        'openssl', 'smime', '-sign', '-md', 'sha256', '-nodetach', '-outform', 'DER',
        '-in', $in, '-out', $out,
        '-signer', $p->{cert}, '-inkey', $p->{privkey}, '-certfile', $p->{chain},
    );
    if ($rc != 0) {
        $err =~ s/\s+/ /g;
        $err = substr($err, 0, 300);
        die "cert-sign: openssl smime failed for $lineage (rc=$rc): $err\n";
    }

    my $der = _slurp($out);
    die "cert-sign: openssl produced no output for $lineage\n" unless length $der > 100;

    return ($der, _cert_meta($p->{cert}) // {});
}

1;

__END__

=head1 NAME

Homelab::CertServer::Signer - sign Apple configuration profiles where the keys already live

=cut
