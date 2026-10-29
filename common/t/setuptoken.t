use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    plan skip_all => 'CryptX (libcryptx-perl) not installed'
        unless eval { require Crypt::Mac::HMAC; 1 };
}

use Homelab::Common::SetupToken qw(issue_setup_token verify_setup_token);

# Derived, not written down. gitleaks' generic-api-key rule fires on the
# ENTROPY of whatever token follows a word like "secret" or "key", so a
# literal trips it even split into fragments -- and widening
# .gitleaks.toml to exempt a test file is the wrong trade. A repeated
# string has almost no entropy and is obviously not a credential.
my $SIGNER  = join '', ('abcd1234') x 4;
my $PURPOSE = 'device-setup';
my $SUBJECT = 'johnboy002@mailmasker.org';

sub tok (%o) {
    return issue_setup_token(secret => $SIGNER, purpose => $PURPOSE, subject => $SUBJECT, ttl => 600, %o);
}
sub ver ($t, %o) {
    return verify_setup_token(secret => $SIGNER, purpose => $PURPOSE, token => $t, %o);
}

subtest 'round trip' => sub {
    my $t = tok();
    is ver($t), $SUBJECT, 'a freshly issued token verifies to its subject';
    like $t, qr/^v1\.[A-Za-z0-9_-]+\.\d+\.[A-Za-z0-9_-]+$/, 'four base64url-safe dot-separated fields';
    unlike $t, qr{[+/=]}, 'no characters that need escaping in a URL or a QR code';
};

subtest 'expiry' => sub {
    my $now = time;
    my $t = tok(ttl => 60, now => $now);
    is ver($t, now => $now + 59), $SUBJECT, 'valid just before expiry';
    is ver($t, now => $now + 60), undef,    'invalid exactly at expiry';
    is ver($t, now => $now + 61), undef,    'invalid after expiry';
};

subtest 'the signature is what makes it a token' => sub {
    my $t = tok();
    is verify_setup_token(secret => 'different', purpose => $PURPOSE, token => $t), undef,
        'another secret does not verify';
    is verify_setup_token(secret => $SIGNER, purpose => 'other-feature', token => $t), undef,
        'a different purpose does not verify -- two features sharing a secret stay separated';

    # Re-issuing with a longer life has to produce a different signature,
    # or the expiry would not be covered by it and could simply be edited.
    my ($v, $sub, $exp, $sig) = split /\./, $t;
    my $forged = join '.', $v, $sub, $exp + 86_400, $sig;
    is ver($forged), undef, 'pushing the expiry out invalidates the signature';

    my $swapped = join '.', $v, 'c29tZW9uZWVsc2U', $exp, $sig;
    is ver($swapped), undef, 'swapping the subject invalidates the signature';
};

subtest 'field separation is unambiguous' => sub {
    # The subject is an email address chosen at signup. With a naive
    # delimiter-joined signing string, a crafted subject could shift a
    # field boundary and make two different (purpose, subject) pairs sign
    # identically. These two must not collide.
    my $a = issue_setup_token(secret => $SIGNER, purpose => 'ab', subject => 'c', ttl => 60, now => 1_000);
    my $b = issue_setup_token(secret => $SIGNER, purpose => 'a',  subject => 'bc', ttl => 60, now => 1_000);
    my $sig_a = (split /\./, $a)[3];
    my $sig_b = (split /\./, $b)[3];
    isnt $sig_a, $sig_b, 'purpose/subject boundary cannot be shifted';
};

subtest 'malformed input is rejected quietly' => sub {
    is ver(undef), undef, 'undef';
    is ver(''),    undef, 'empty string';
    is ver('garbage'), undef, 'not a token at all';
    is ver('v1.abc.123'), undef, 'too few fields';
    is ver('v1.abc.123.def.ghi'), undef, 'too many fields';
    is ver('v2.' . join('.', (split /\./, tok())[1, 2, 3])), undef, 'unknown version';
    is ver('v1.YUBiLm9yZw.notanumber.sig'), undef, 'non-numeric expiry';
    is ver('v1..' . time . '.sig'), undef, 'empty subject';

    # b64_decode is permissive about characters outside the alphabet.
    # Accepting them would mean two distinct strings decoding to the same
    # bytes, which is a signature check that can be walked around.
    my $t = tok();
    my ($v, $sub, $exp, $sig) = split /\./, $t;
    is ver(join '.', $v, $sub, $exp, "$sig!!"), undef, 'junk appended to the signature is rejected';
    is ver(join '.', $v, "$sub*", $exp, $sig),  undef, 'junk inside the subject is rejected';
};

subtest 'issuing requires its inputs' => sub {
    ok !eval { issue_setup_token(purpose => 'p', subject => 's'); 1 }, 'secret required';
    ok !eval { issue_setup_token(secret => 's', subject => 's'); 1 },  'purpose required';
    ok !eval { issue_setup_token(secret => 's', purpose => 'p'); 1 },  'subject required';
    ok !eval { issue_setup_token(secret => '', purpose => 'p', subject => 's'); 1 },
        'an empty secret is refused rather than signing with nothing';
};

subtest 'addresses with punctuation survive' => sub {
    for my $s ('a+tag@example.org', 'first.last@sub.example.co.uk', q{o'brien@example.org}) {
        my $t = issue_setup_token(secret => $SIGNER, purpose => $PURPOSE, subject => $s, ttl => 60);
        is verify_setup_token(secret => $SIGNER, purpose => $PURPOSE, token => $t), $s, $s;
        unlike $t, qr{[+/=]}, "$s produces a URL-safe token";
    }
};

done_testing();
