package Homelab::API::Auth;
use Mojo::Base -strict;
use Crypt::Argon2 qw(argon2id_pass argon2id_verify);
use Crypt::URandom qw(urandom);
use Crypt::JWT qw(encode_jwt decode_jwt);
use Exporter 'import';

our @EXPORT_OK = qw(
    hash_password verify_password
    generate_jwt verify_jwt
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

# %opts: secret, algorithm (default HS256), expires_in (seconds, default 1800)
sub generate_jwt {
    my ($email, %opts) = @_;
    my $expires_in = $opts{expires_in} // 1800;
    my $now = time;
    my $exp = $now + $expires_in;

    my $token = encode_jwt(
        payload => { email => $email, iat => $now, exp => $exp },
        key     => $opts{secret},
        alg     => $opts{algorithm} // 'HS256',
    );
    return ($token, $expires_in);
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
