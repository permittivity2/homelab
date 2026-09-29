use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    plan skip_all => 'CryptX (libcryptx-perl) not installed'
        unless eval { require Crypt::AuthEnc::GCM; 1 };
}

use MIME::Base64 qw(encode_base64);
use Homelab::DomainAdmin::KeyVault qw(decode_kek encrypt_private_key decrypt_private_key KEY_ENC_VERSION);

# A realistic-ish private key payload (content is opaque to the vault).
my $priv = "-----BEGIN PRIVATE KEY-----\n" . ("MIIEvExampleKeyMaterial0123456789/+abcDEF\n" x 20) . "-----END PRIVATE KEY-----\n";

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

# --- round trip ---
my $blob = encrypt_private_key($kek, 'test.mailmasker.org', '20260929a', $priv);
like($blob, qr/^v1:/, 'blob carries the v1 version tag');
isnt($blob, $priv, 'ciphertext is not the plaintext');
unlike($blob, qr/BEGIN PRIVATE KEY/, 'plaintext markers are not visible in the blob');
is(decrypt_private_key($kek, 'test.mailmasker.org', '20260929a', $blob), $priv, 'round-trips back to the exact plaintext');

# nonce is random => same input encrypts to different ciphertext each time
isnt(encrypt_private_key($kek, 'test.mailmasker.org', '20260929a', $priv), $blob, 'each encryption uses a fresh nonce');

# --- wrong KEK fails (authenticated, not garbage) ---
ok(!eval { decrypt_private_key($kek2, 'test.mailmasker.org', '20260929a', $blob); 1 }, 'wrong KEK fails authentication');

# --- AAD binding: cannot move a ciphertext to another selector/domain ---
ok(!eval { decrypt_private_key($kek, 'test.mailmasker.org', 'OTHER-selector', $blob); 1 }, 'wrong selector (AAD) fails');
ok(!eval { decrypt_private_key($kek, 'other-domain.org', '20260929a', $blob); 1 },        'wrong domain (AAD) fails');

# --- tamper detection ---
my $tampered = $blob;
substr($tampered, -4, 4) = 'AAAA';
ok(!eval { decrypt_private_key($kek, 'test.mailmasker.org', '20260929a', $tampered); 1 }, 'tampered ciphertext fails');
ok(!eval { decrypt_private_key($kek, 'test.mailmasker.org', '20260929a', 'v2:' . substr($blob, 3)); 1 }, 'unknown version fails');

done_testing;
