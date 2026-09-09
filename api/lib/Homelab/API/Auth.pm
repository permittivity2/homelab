package Homelab::API::Auth;
use Mojo::Base -strict;
use Crypt::Argon2 qw(argon2id_pass argon2id_verify);
use Crypt::URandom qw(urandom);
use Crypt::JWT qw(encode_jwt decode_jwt);
use Exporter 'import';

our @EXPORT_OK = qw(
    hash_password verify_password
    generate_jwt verify_jwt generate_jti
    generate_refresh_token
);

# Argon2id, matching the proven parameters from the old homelab-api repo
# (3 iterations, 64MB memory, 1 thread, 32-byte output) — a deliberate,
# already-tuned choice, not reinvented here.
sub hash_password {
    my ($plaintext) = @_;
    my $salt = urandom(16);
    return argon2id_pass($plaintext, $salt, 3, '64M', 1, 32);
}

sub verify_password {
    my ($plaintext, $hash) = @_;
    return 0 unless $plaintext && $hash;
    return argon2id_verify($hash, $plaintext) ? 1 : 0;
}

# %opts: secret, algorithm (default HS256), expires_in (seconds, default
# 1800), jti (required -- the caller mints this and INSERTs the matching
# api.sessions row BEFORE calling this, so a session row always exists
# by the time the token could possibly be introspected; this function
# stays a pure JWT-encoding helper with no DB access of its own).
sub generate_jwt {
    my ($email, %opts) = @_;
    # Loud and early, not a silently-issued unrevocable token: every
    # caller must mint a jti (generate_jti) and record the matching
    # api.sessions row itself -- see migrations/005-sessions.sql. A
    # jti-less JWT would still verify fine (signature+exp are unrelated
    # to this claim) but could never be revoked by logout, defeating the
    # entire reason this claim exists.
    die "generate_jwt: jti is required (call generate_jti() and pass it explicitly)\n"
        unless $opts{jti};
    my $expires_in = $opts{expires_in} // 1800;
    my $now = time;
    my $exp = $now + $expires_in;

    my $token = encode_jwt(
        payload => { email => $email, iat => $now, exp => $exp, jti => $opts{jti} },
        key     => $opts{secret},
        alg     => $opts{algorithm} // 'HS256',
    );
    return ($token, $expires_in);
}

# 32 random bytes, hex-encoded -- same /dev/urandom-backed entropy
# convention used throughout this ecosystem's credential generation
# (see e.g. homelab-common's bootstrap scripts), just hex instead of
# base64 since a jti has no reason to carry base64's punctuation.
sub generate_jti {
    open(my $fh, '<', '/dev/urandom') or die "cannot open /dev/urandom: $!";
    read($fh, my $bytes, 32) == 32 or die 'short read from /dev/urandom';
    close($fh);
    return unpack('H*', $bytes);
}

sub verify_jwt {
    my ($token, %opts) = @_;
    return undef unless $token;

    my $payload = eval {
        decode_jwt(token => $token, key => $opts{secret}, alg => $opts{algorithm} // 'HS256');
    };
    return $@ ? undef : $payload;
}

sub generate_refresh_token {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $token = '';
    $token .= $chars[int(rand(@chars))] for 1 .. 64;
    return $token;
}

1;
