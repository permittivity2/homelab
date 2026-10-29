package Homelab::Common::ProfileSigner;
use Mojo::Base -strict, -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json);
use MIME::Base64 qw(decode_base64);
use Digest::SHA qw(sha256_hex);
# No import list: this is only ever called as a fully-qualified name, and
# system_agent_token() is a file read that must happen per request (the
# local agent rotates the token every heartbeat), never at load time.
use Homelab::Common::Registry ();
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(sign_apple_profile signing_enabled);

# The CLIENT half of Apple configuration-profile signing.
#
# An unsigned .mobileconfig installs perfectly well; iOS just labels it
# "Unverified" in red on the install screen, which is a bad thing to show
# someone three minutes into owning an account. Signing turns that green
# and names the signer.
#
# WHY THIS IS A NETWORK CALL AND NOT A LOCAL openssl.
#
# Signing needs a certificate and a private key for a name the device
# already trusts, and the honest way to get one onto the six hosts that
# serve setup pages (homelab-invite 30/31/32, homelab-accountmanage
# 27/28/29) is homelab-certsync. But certsync decrypts with
# `key_encryption_key`, and that KEK is FLEET-WIDE: it opens every
# lineage in the store, mail.<domain> included. Installing it on six more
# app hosts to win a green label would mean a compromise of any one of
# them yields every certificate the fleet has. That is a bad trade for a
# colour.
#
# So the key does not move. The bytes do. The certificate issuer
# (homelab-cert-server, one host, already holding every plaintext key
# because it is what issues them) grows a narrow signing endpoint, and
# this module asks it. Net new key exposure: zero.
#
# WHAT THE ENDPOINT WILL AND WILL NOT SIGN. It does not sign submitted
# bytes -- that would be an oracle that signs anything at all with a key
# that also terminates TLS. It takes the PARAMETERS of a mail profile,
# builds the plist itself with the same Homelab::Common::AppleProfile
# this module's callers use, and signs that. Everything it emits is a
# mail-configuration plist by construction.
#
# FAILURE IS NOT AN ERROR. Every function here returns undef rather than
# dying, and every caller falls back to serving the profile unsigned. An
# expired signing certificate, a restarting signer, a dropped packet --
# none of those should turn "add my mailbox to my phone" into a 500. The
# worst case is the red label we have shipped with since day one.

my $UA = Mojo::UserAgent->new;

# url + lineage are both required for the feature to do anything, so a
# config block with either missing reads as "not configured" rather than
# as a broken install to warn about on every request.
sub signing_enabled ($cfg) {
    return 0 unless ref $cfg eq 'HASH';
    for my $k (qw(url lineage)) {
        my $v = $cfg->{$k};
        # YAML renders a present-but-blank key as '', not undef -- and
        # blank is exactly how the shipped example config leaves these.
        return 0 unless defined $v && length $v && $v !~ /^YOUR_/;
    }
    return 1;
}

# Keyed by every input that can change the bytes, so a cache hit is
# always a correct hit. Two different TTLs, and the negative one is the
# one that matters: without it an unreachable signer would add the full
# connect timeout to EVERY profile download, which is the one request in
# this flow a person is actively waiting on.
my %CACHE;
my $CACHE_MAX = 256;

sub _cache_get ($key) {
    my $e = $CACHE{$key} or return;
    if ($e->{until} < time) { delete $CACHE{$key}; return }
    # Two-level return so a cached FAILURE is distinguishable from a
    # cache miss: both have no bytes, but only one should skip the call.
    return ($e->{bytes});
}

sub _cache_put ($key, $bytes, $ttl) {
    # Bounded because hypnotoad workers live for weeks and each distinct
    # mailbox is a distinct key. Oldest-expiry-first eviction; an exact
    # LRU would need access bookkeeping this does not earn.
    if (keys(%CACHE) >= $CACHE_MAX) {
        my @by_age = sort { $CACHE{$a}{until} <=> $CACHE{$b}{until} } keys %CACHE;
        delete $CACHE{$_} for @by_age[0 .. int($CACHE_MAX / 4)];
    }
    $CACHE{$key} = { bytes => $bytes, until => time + $ttl };
    return;
}

# Visible for t/profilesigner.t, which has no signer to talk to.
sub _reset_cache { %CACHE = (); return }

# sign_apple_profile(signing => \%cfg, profile => \%params, log => $log)
#   -> signed PKCS#7 DER bytes, or undef to mean "serve it unsigned".
sub sign_apple_profile (%opts) {
    my $cfg     = $opts{signing} // {};
    my $profile = $opts{profile} // {};
    my $log     = $opts{log};

    return undef unless signing_enabled($cfg);

    my $lineage = $cfg->{lineage};
    my $key = sha256_hex(join "\0", $lineage,
        map { "$_=" . ($profile->{$_} // '') } sort keys %$profile);

    my ($cached) = _cache_get($key);
    return $cached if defined $cached;
    # A live negative entry is a key that exists with no bytes.
    return undef if exists $CACHE{$key};

    # credential_file is an override for tests and for a host that keeps
    # the agent credential somewhere non-standard; unset means the
    # default path, which is the only thing production uses.
    my $token = eval {
        Homelab::Common::Registry::system_agent_token(
            $cfg->{credential_file} ? (credential_file => $cfg->{credential_file}) : ());
    };
    unless ($token) {
        # No agent credential on this host. Nothing to retry into, so
        # cache the refusal like any other failure and stay quiet after
        # the first complaint.
        $log->warn("profile signing: no system_agent credential: $@") if $log;
        _cache_put($key, undef, $cfg->{retry_seconds} || 60);
        return undef;
    }

    my $url = $cfg->{url};
    $url =~ s{/+$}{};
    my $timeout = $cfg->{timeout_seconds} || 5;
    $UA->connect_timeout($timeout);
    $UA->request_timeout($timeout);

    my $tx = eval {
        $UA->post("$url/internal/v1/sign/apple-mail-profile" =>
            { Authorization => "Bearer $token", 'Content-Type' => 'application/json' } =>
            encode_json({ %$profile, lineage => $lineage }));
    };
    unless ($tx) {
        $log->warn("profile signing: request to $url failed: $@") if $log;
        _cache_put($key, undef, $cfg->{retry_seconds} || 60);
        return undef;
    }

    # ->result THROWS on a transport failure (connection refused, DNS,
    # timeout) rather than returning a transaction with an error set.
    # Missing that is how this module would have turned an unreachable
    # signer into a 500 on a mailbox owner's profile download -- the one
    # outcome its whole design is meant to rule out. Caught by
    # t/profilesigner.t, which is why that test starts a real server and
    # also points at a dead port.
    my $res  = eval { $tx->result };
    unless ($res) {
        my $err = $@ || 'transport failure';
        $err =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
        $log->warn("profile signing: $lineage unreachable at $url: $err") if $log;
        _cache_put($key, undef, $cfg->{retry_seconds} || 60);
        return undef;
    }

    my $json = eval { $res->json };
    unless ($res->is_success && ref $json eq 'HASH' && $json->{profile_b64}) {
        my $why = (ref $json eq 'HASH' && $json->{error}) ? $json->{error}
                : $res->is_error ? $res->code . ' ' . ($res->message // '')
                : 'malformed response';
        $log->warn("profile signing: $lineage refused by $url: $why") if $log;
        _cache_put($key, undef, $cfg->{retry_seconds} || 60);
        return undef;
    }

    my $der = decode_base64($json->{profile_b64});
    unless (length $der > 100) {
        # A PKCS#7 envelope carrying a leaf, a chain and a few KB of
        # plist cannot be this small. Something upstream is confused.
        $log->warn("profile signing: $lineage returned " . length($der) . " bytes") if $log;
        _cache_put($key, undef, $cfg->{retry_seconds} || 60);
        return undef;
    }

    _cache_put($key, $der, $cfg->{cache_seconds} || 900);
    return $der;
}

1;

__END__

=head1 NAME

Homelab::Common::ProfileSigner - ask the certificate issuer to sign an Apple configuration profile

=head1 SYNOPSIS

    use Homelab::Common::ProfileSigner qw(sign_apple_profile);

    my $der = sign_apple_profile(
        signing => $config->{device_setup}{signing},
        profile => { email => $email, imap_host => ..., smtp_host => ... },
        log     => $app->log,
    );
    # undef is normal: serve build_mail_profile()'s XML instead.

=head1 DESCRIPTION

The private key for a publicly-trusted name stays on the one host that
already has it. See the comments in the source for the trade this avoids.

=cut
