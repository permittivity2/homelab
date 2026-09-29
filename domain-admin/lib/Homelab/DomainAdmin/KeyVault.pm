package Homelab::DomainAdmin::KeyVault;
use v5.36;

# Envelope encryption for DKIM private keys stored in Postgres.
#
# WHY: DKIM signing is HA across the ct05/06/07 postfix pool -- each host
# signs its own outbound mail locally, so no single host is a signing
# SPOF. The keys are distributed via the shared `homelab` DB (the single
# source of truth every signer materializes from), NOT copied host-to-
# host. To keep a DB dump/backup from leaking signing keys, each private
# key is wrapped with AES-256-GCM under a key-encryption-key (KEK) that
# lives ONLY in each signer host's config (dkim.key_encryption_key) and
# never in the DB. The raw key is decrypted only in memory on a signer
# host and written to that host's local disk -- it never crosses the
# network in the clear.
#
# Format (v1): "v1:" . base64( iv(12) . tag(16) . ciphertext )
# The GCM additional-authenticated-data is "<domain>/<selector>", so a
# ciphertext is cryptographically bound to its row and cannot be moved to
# a different selector/domain without failing authentication.

use Crypt::AuthEnc::GCM qw(gcm_encrypt_authenticate gcm_decrypt_verify);
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);

use Exporter 'import';
our @EXPORT_OK = qw(decode_kek encrypt_private_key decrypt_private_key KEY_ENC_VERSION);

use constant KEY_ENC_VERSION => 1;

# Decode + validate the configured KEK. Accepts the base64 form produced
# by `openssl rand -base64 32` (the documented way to generate it).
# Dies with an actionable message rather than silently using a weak key.
sub decode_kek ($kek_b64) {
    die "dkim.key_encryption_key is not set -- generate one with: openssl rand -base64 32\n"
        unless defined $kek_b64 && length $kek_b64;
    my $kek = decode_base64($kek_b64);
    die "dkim.key_encryption_key must decode to 32 bytes for AES-256 (got " . length($kek)
        . "); generate with: openssl rand -base64 32\n"
        unless length($kek) == 32;
    return $kek;
}

sub encrypt_private_key ($kek, $domain, $selector, $plaintext) {
    my $iv = random_bytes(12);
    my ($ct, $tag) = gcm_encrypt_authenticate('AES', $kek, $iv, "$domain/$selector", $plaintext);
    return 'v1:' . encode_base64($iv . $tag . $ct, '');
}

sub decrypt_private_key ($kek, $domain, $selector, $blob) {
    die "empty DKIM key blob\n" unless defined $blob && length $blob;
    my ($ver, $b64) = split /:/, $blob, 2;
    die "unknown DKIM key blob version '" . ($ver // '') . "'\n" unless defined $ver && $ver eq 'v1';
    my $raw = decode_base64($b64 // '');
    die "DKIM key blob too short\n" if length($raw) < 28;
    my $iv  = substr($raw, 0, 12);
    my $tag = substr($raw, 12, 16);
    my $ct  = substr($raw, 28);
    my $pt  = gcm_decrypt_verify('AES', $kek, $iv, "$domain/$selector", $ct, $tag);
    die "DKIM key decryption/authentication failed for $domain/$selector "
        . "(wrong key_encryption_key, or tampered/mismatched ciphertext)\n"
        unless defined $pt;
    return $pt;
}

1;
