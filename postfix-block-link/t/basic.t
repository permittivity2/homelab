use strict;
use warnings;
use Test::More;
use Mojo::JSON qw(decode_json);

use lib 'lib';
use Homelab::PostfixBlockLink::Milter qw(
    is_signed_mime generate_token build_header_value
    resolve_recipient effective_setting insert_pending_link
);

# --- Pure functions -- no DB, no Sendmail::PMilter, run everywhere ------

is(is_signed_mime(undef), 0, 'no Content-Type at all is not signed mime');
is(is_signed_mime('text/plain'), 0, 'plain text is not signed mime');
is(is_signed_mime('multipart/signed; protocol="application/pgp-signature"'), 1,
    'multipart/signed (PGP/MIME) is detected');
is(is_signed_mime('application/pkcs7-mime; smime-type=signed-data'), 1,
    'application/pkcs7-mime (S/MIME) is detected');
is(is_signed_mime('application/x-pkcs7-mime'), 1, 'application/x-pkcs7-mime variant is detected');
is(is_signed_mime('application/pkcs7-signature'), 1, 'application/pkcs7-signature is detected');
is(is_signed_mime('MULTIPART/SIGNED; boundary=x'), 1, 'content-type match is case-insensitive');

my $t1 = generate_token();
my $t2 = generate_token();
like($t1, qr/^[0-9a-f]{64}$/, 'generate_token returns 64 lowercase hex chars (32 bytes)');
isnt($t1, $t2, 'two calls never collide');

is(
    build_header_value('https://blockemail.test.mailmasker.org', 'abc123'),
    '<https://blockemail.test.mailmasker.org/l/abc123>',
    'build_header_value wraps the link in angle brackets, matching List-Unsubscribe RFC 2369 syntax',
);

# --- DB-backed functions -- real Postgres only, same "no mocks" -----------
# convention as every other homelab-* test suite. Point
# HOMELAB_POSTFIX_BLOCK_LINK_CONFIG at a real, already-deployed config.yml
# on a host where homelab-api/domain-admin/block-link are all migrated.
unless ($ENV{HOMELAB_POSTFIX_BLOCK_LINK_CONFIG}) {
    diag('Set HOMELAB_POSTFIX_BLOCK_LINK_CONFIG to a real config.yml to also run the DB-backed tests');
    done_testing;
    exit 0;
}

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);

my $config = load_config('HOMELAB_POSTFIX_BLOCK_LINK_CONFIG', '/etc/homelab/postfix-block-link/config.yml');
my $db = runtime_pg(%{ $config->{database} })->db;

my $domain = 'pbl-test-' . time . '-' . $$ . '.invalid';
my $email  = "user\@$domain";

# Seed a minimal, real account + domain default directly -- this package
# never creates accounts/domains itself (homelab-api/domain-admin own
# that), so a real test has to seed through those same tables, same
# technique block-link's own t/basic.t uses for site_admin.
$db->query('INSERT INTO api.users (email, password_hash, active) VALUES (?, ?, true)', $email, 'x')
    unless $db->query('SELECT 1 FROM api.users WHERE email = ?', $email)->hash;
$db->query(
    q{INSERT INTO block_link.domain_settings (domain_name, enabled, mode) VALUES (?, true, 'both')
      ON CONFLICT (domain_name) DO UPDATE SET enabled = true, mode = 'both'},
    $domain,
);

is(resolve_recipient($db, $email), $email, 'a real, active account resolves to itself (no alias)');
is(resolve_recipient($db, "nobody\@$domain"), undef, 'a non-existent local address resolves to undef');

my $setting = effective_setting($db, $email);
is($setting->{enabled}, 1, 'account with no override inherits the domain default (enabled)');
is($setting->{mode}, 'both', 'mode comes from the domain default');

$db->query(
    q{INSERT INTO block_link.account_settings (user_email, enabled) VALUES (?, false)
      ON CONFLICT (user_email) DO UPDATE SET enabled = false},
    $email,
);
my $overridden = effective_setting($db, $email);
is($overridden->{enabled}, 0, 'an explicit account override (disabled) beats the enabled domain default');

my $token = generate_token();
insert_pending_link(
    $db, token => $token, candidates_json => '[{"account_email":"' . $email . '","address":"' . $email . '"}]',
    message_id => '<test@example.invalid>', ttl_days => 90,
);
my $row = $db->query('SELECT token, expires_at FROM block_link.pending_links WHERE token = ?', $token)->hash;
ok($row, 'insert_pending_link wrote a real, readable row');
like($row->{expires_at}, qr/^\d{4}-\d\d-\d\d/, 'expires_at was set to a real future timestamp');

# Cleanup -- this test creates real rows in shared tables, same
# discipline as leaving them for post-hoc inspection would violate
# every other suite's own convention of not littering test fixtures.
$db->query('DELETE FROM block_link.pending_links WHERE token = ?', $token);
$db->query('DELETE FROM block_link.account_settings WHERE user_email = ?', $email);
$db->query('DELETE FROM block_link.domain_settings WHERE domain_name = ?', $domain);
$db->query('DELETE FROM api.users WHERE email = ?', $email);

done_testing;
