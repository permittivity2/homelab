package Homelab::Common::KeyVault;
use v5.36;

# Envelope encryption for secret material stored in Postgres.
#
# Generalized from Homelab::DomainAdmin::KeyVault (DKIM private keys), which
# proved the pattern in production: the shared `homelab` DB is the single
# source of truth every consumer materializes from, so secrets are distributed
# via the DB rather than copied host-to-host -- but a DB dump must not leak
# them. Each secret is wrapped with AES-256-GCM under a key-encryption-key
# (KEK) that lives ONLY in each consuming host's local config and NEVER in the
# DB. Plaintext exists only in memory on a host that already has the KEK.
#
# Format (v1): "v1:" . base64( iv(12) . tag(16) . ciphertext )
#
# The one deliberate difference from the DomainAdmin original: the GCM
# additional-authenticated-data is passed in by the CALLER as an opaque
# string, instead of being hardcoded to "<domain>/<selector>". The AAD still
# does the same job -- it cryptographically binds a ciphertext to its own row,
# so a blob cannot be lifted into a different row and still decrypt -- but
# each caller chooses its own binding (DKIM: "<domain>/<selector>";
# certificates: "<lineage>/<serial>").
#
# The payload itself is opaque to the vault: it encrypts bytes, not a
# particular kind of key.

use Crypt::AuthEnc::GCM qw(gcm_encrypt_authenticate gcm_decrypt_verify);
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);

use Exporter 'import';
our @EXPORT_OK = qw(decode_kek encrypt_secret decrypt_secret KEY_ENC_VERSION);

use constant KEY_ENC_VERSION => 1;

# Decode + validate a configured KEK. Accepts the base64 form produced by
# `openssl rand -base64 32` (the documented way to generate one). Dies with an
# actionable message rather than silently proceeding with a weak/absent key.
# $label names the config key in the error text, e.g. 'certs.key_encryption_key'.
sub decode_kek ($kek_b64, $label = 'key_encryption_key') {
    die "$label is not set -- generate one with: openssl rand -base64 32\n"
        unless defined $kek_b64 && length $kek_b64;
    my $kek = decode_base64($kek_b64);
    die "$label must decode to 32 bytes for AES-256 (got " . length($kek)
        . "); generate with: openssl rand -base64 32\n"
        unless length($kek) == 32;
    return $kek;
}

# $aad binds the ciphertext to its row. Pass something stable and unique to
# that row (and reproducible at decrypt time).
sub encrypt_secret ($kek, $aad, $plaintext) {
    die "encrypt_secret: aad is required (it binds the blob to its row)\n"
        unless defined $aad && length $aad;
    my $iv = random_bytes(12);
    my ($ct, $tag) = gcm_encrypt_authenticate('AES', $kek, $iv, $aad, $plaintext);
    return 'v1:' . encode_base64($iv . $tag . $ct, '');
}

sub decrypt_secret ($kek, $aad, $blob) {
    die "decrypt_secret: aad is required\n" unless defined $aad && length $aad;
    die "empty secret blob\n" unless defined $blob && length $blob;
    my ($ver, $b64) = split /:/, $blob, 2;
    die "unknown secret blob version '" . ($ver // '') . "'\n"
        unless defined $ver && $ver eq 'v1';
    my $raw = decode_base64($b64 // '');
    die "secret blob too short\n" if length($raw) < 28;
    my $iv  = substr($raw, 0, 12);
    my $tag = substr($raw, 12, 16);
    my $ct  = substr($raw, 28);
    my $pt  = gcm_decrypt_verify('AES', $kek, $iv, $aad, $ct, $tag);
    die "secret decryption/authentication failed for '$aad' "
        . "(wrong key_encryption_key, or tampered/mismatched ciphertext)\n"
        unless defined $pt;
    return $pt;
}

1;
