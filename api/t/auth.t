use strict;
use warnings;
use Test::More;

use lib 'lib';
use Homelab::API::Auth qw(hash_password verify_password generate_jwt verify_jwt generate_jti generate_refresh_token);

# Password hashing — no live DB needed.
my $hash = hash_password('correct horse battery staple');
like($hash, qr/^\$argon2id\$/, 'hash_password produces an argon2id hash');
ok(verify_password('correct horse battery staple', $hash), 'verify_password accepts the correct password');
ok(!verify_password('wrong password', $hash), 'verify_password rejects an incorrect password');
ok(!verify_password('', $hash), 'verify_password rejects an empty password');

# JWT round-trip.
my $jti = generate_jti();
my ($jwt, $expires_in) = generate_jwt('user@test.mailmasker.org', secret => 'test-secret-at-least-32-characters-long', expires_in => 900, jti => $jti);
is($expires_in, 900, 'generate_jwt returns the requested expiry');

my $payload = verify_jwt($jwt, secret => 'test-secret-at-least-32-characters-long');
ok($payload, 'verify_jwt accepts a token signed with the matching secret');
is($payload->{email}, 'user@test.mailmasker.org', 'payload carries the right email claim');
is($payload->{jti}, $jti, 'payload carries the jti claim introspect() uses for revocation checks');

# generate_jwt refuses to silently mint an unrevocable (jti-less) token.
eval { generate_jwt('user@test.mailmasker.org', secret => 'test-secret-at-least-32-characters-long') };
like($@, qr/jti is required/, 'generate_jwt dies without a jti rather than issuing an unrevocable token');

# jti values are actually unique, not e.g. a constant placeholder.
my %seen_jti;
$seen_jti{generate_jti()}++ for 1 .. 1000;
is(scalar keys %seen_jti, 1000, 'generate_jti produces 1000 distinct values in 1000 calls');

ok(!verify_jwt($jwt, secret => 'a-completely-different-secret-value-here'), 'verify_jwt rejects a token signed with a different secret');
ok(!verify_jwt('not-a-real-jwt', secret => 'test-secret-at-least-32-characters-long'), 'verify_jwt rejects garbage input');
ok(!verify_jwt(undef, secret => 'test-secret-at-least-32-characters-long'), 'verify_jwt rejects undef');

# Refresh tokens: random, not predictable/reused.
my %seen;
$seen{generate_refresh_token()}++ for 1 .. 1000;
is(scalar keys %seen, 1000, 'generate_refresh_token produces 1000 distinct values in 1000 calls');
like((keys %seen)[0], qr/^[a-zA-Z0-9]{64}$/, 'refresh token is 64 alphanumeric characters');

done_testing;
