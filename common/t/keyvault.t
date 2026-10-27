use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    plan skip_all => 'CryptX (libcryptx-perl) not installed'
        unless eval { require Crypt::AuthEnc::GCM; 1 };
}

use MIME::Base64 qw(encode_base64);
use Homelab::Common::KeyVault qw(decode_kek encrypt_secret decrypt_secret KEY_ENC_VERSION);

# Ported from domain-admin/t/keyvault.t. Same guarantees, but the AAD is now
# caller-supplied rather than "<domain>/<selector>", so the binding cases are
# expressed with a cert-style AAD ("<lineage>/<serial>").

# A realistic-ish private key payload (content is opaque to the vault).
my $priv = "-----BEGIN PRIVATE KEY-----\n" . ("MIIEvExampleKeyMaterial0123456789/+abcDEF\n" x 20) . "-----END PRIVATE KEY-----\n";

my $AAD  = 'mail.mailmasker.org/05CBDAC453A94D59F4E3A04427CB772E3B09';
my $AAD2 = 'drive.mailmasker.org/05CBDAC453A94D59F4E3A04427CB772E3B09';

# Two distinct valid 32-byte KEKs.
my $kek_b64  = encode_base64(pack('C*', map { $_ % 256 } 1 .. 32), '');
my $kek2_b64 = encode_base64(pack('C*', map { (200 - $_) % 256 } 1 .. 32), '');
my $kek  = decode_kek($kek_b64);
my $kek2 = decode_kek($kek2_b64);

# --- KEK validation ---
is(KEY_ENC_VERSION, 1, 'key-encryption version constant is 1');
ok(!eval { decode_kek(undef); 1 }, 'undef KEK is rejected');
ok(!eval { decode_kek(''); 1 },    'empty KEK is rejected');
ok(!eval { decode_kek(encode_base64('too short', '')); 1 }, 'wrong-length KEK is rejected');
like("$@", qr/openssl rand -base64 32/, 'rejection message tells you how to generate one');
# the label is caller-supplied so the error names the right config key
ok(!eval { decode_kek(undef, 'certs.key_encryption_key'); 1 }, 'undef KEK rejected with a custom label');
like("$@", qr/\Qcerts.key_encryption_key\E/, 'error names the caller-supplied config key');

# --- round trip ---
my $blob = encrypt_secret($kek, $AAD, $priv);
like($blob, qr/^v1:/, 'blob carries the v1 version tag');
isnt($blob, $priv, 'ciphertext is not the plaintext');
unlike($blob, qr/BEGIN PRIVATE KEY/, 'plaintext markers are not visible in the blob');
is(decrypt_secret($kek, $AAD, $blob), $priv, 'round-trips back to the exact plaintext');

# nonce is random => same input encrypts to different ciphertext each time.
# (This is also WHY the store keys on (lineage, serial) rather than on a hash
# of the ciphertext -- the bytes differ on every encryption.)
isnt(encrypt_secret($kek, $AAD, $priv), $blob, 'each encryption uses a fresh nonce');

# --- aad is mandatory (it is the row binding; silently allowing an empty one
#     would quietly remove the protection) ---
ok(!eval { encrypt_secret($kek, '', $priv); 1 },   'empty AAD is rejected on encrypt');
ok(!eval { encrypt_secret($kek, undef, $priv); 1 },'undef AAD is rejected on encrypt');
ok(!eval { decrypt_secret($kek, '', $blob); 1 },   'empty AAD is rejected on decrypt');

# --- wrong KEK fails (authenticated, not garbage) ---
ok(!eval { decrypt_secret($kek2, $AAD, $blob); 1 }, 'wrong KEK fails authentication');

# --- AAD binding: a blob cannot be moved to another row ---
ok(!eval { decrypt_secret($kek, $AAD2, $blob); 1 }, 'a different lineage (AAD) fails');
ok(!eval { decrypt_secret($kek, 'mail.mailmasker.org/DIFFERENTSERIAL', $blob); 1 },
    'same lineage but a different serial (AAD) fails');

# --- tamper detection ---
my $tampered = $blob;
substr($tampered, -4, 4) = 'AAAA';
ok(!eval { decrypt_secret($kek, $AAD, $tampered); 1 }, 'tampered ciphertext fails');
ok(!eval { decrypt_secret($kek, $AAD, 'v2:' . substr($blob, 3)); 1 }, 'unknown version fails');
ok(!eval { decrypt_secret($kek, $AAD, 'v1:' . encode_base64('short', '')); 1 }, 'too-short blob fails');
ok(!eval { decrypt_secret($kek, $AAD, ''); 1 }, 'empty blob fails');

# --- payload is opaque: binary round-trips byte-for-byte ---
my $binary = join('', map { chr($_ % 256) } 0 .. 1023);
my $bblob  = encrypt_secret($kek, $AAD, $binary);
is(decrypt_secret($kek, $AAD, $bblob), $binary, 'arbitrary binary payload round-trips exactly');

done_testing;
