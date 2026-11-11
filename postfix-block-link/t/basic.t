use strict;
use warnings;
use Test::More;
use Mojo::JSON qw(decode_json);

use lib 'lib';
use FindBin;
use lib "$FindBin::Bin/../../common/t/lib";
use TestAccounts qw(track_account);
use Homelab::PostfixBlockLink::Milter qw(
    is_signed_mime generate_token build_header_value
    resolve_recipient effective_setting insert_pending_link
    normalise_message_id last_reference_id parse_header_addresses is_safe_address
    choose_reply_address rewrite_address_header
    reply_from_alias_enabled record_received_via lookup_received_via allowed_to_send_as
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

# --- #67 reply-from-alias helpers (pure) ----------------------------------

is(normalise_message_id('<abc@example.com>'), 'abc@example.com', 'normalise_message_id strips the angle brackets');
is(normalise_message_id("  <ABC.def\@Example.COM>  "), 'ABC.def@Example.COM',
    'whitespace trimmed, case KEPT (Message-IDs compare byte for byte)');
is(normalise_message_id('abc@example.com'), 'abc@example.com', 'a bare id without brackets is accepted');
is(normalise_message_id('<a@b> <c@d>'), 'a@b', 'the first id wins (In-Reply-To)');
is(normalise_message_id('garbage with spaces'), undef, 'garbage is undef');
is(normalise_message_id(undef), undef, 'undef in, undef out');
is(last_reference_id('<a@b> <c@d>  <e@f>'), 'e@f', 'last_reference_id takes the last one (the direct parent)');
is(last_reference_id(''), undef, 'empty References is undef');

is_deeply(parse_header_addresses("Jeff <Blah\@Forge.name>,\r\n  \"Two\" <two\@giraffenow.org>"),
    ['blah@forge.name', 'two@giraffenow.org'], 'folded To: parsed, lowercased, order kept');
is_deeply(parse_header_addresses('undisclosed-recipients:;'), [], 'an empty group yields nothing');
is_deeply(parse_header_addresses('Friends: a@x.org, b@y.org;, c@z.org'), ['a@x.org', 'b@y.org', 'c@z.org'],
    'groups are flattened');
is_deeply(parse_header_addresses(undef), [], 'undef header is an empty list');
is(scalar @{ parse_header_addresses(join(', ', map { "u$_\@x.org" } 1 .. 10), 3) }, 3, 'the limit caps the list');

ok(is_safe_address('claude67a@forge.name'), 'a plain address is safe');
ok(!is_safe_address("x\@y.org\r\nBcc: z\@y.org"), 'CRLF is rejected');
ok(!is_safe_address('<x@y.org>'), 'angle brackets are rejected');
ok(!is_safe_address('x y@y.org'), 'a space is rejected');
ok(!is_safe_address('"x"@y.org'), 'a quoted local part is rejected');
ok(!is_safe_address('x@localhost'), 'a single-label domain is rejected');
ok(!is_safe_address(undef), 'undef is rejected');

my %fake = (
    'claude67a@forge.name'     => 'test@mailmasker.org',
    'claude67b@forge.name'     => 'test@mailmasker.org',
    'claude67a@giraffenow.org' => 'test@mailmasker.org',
    'test@mailmasker.org'      => 'test@mailmasker.org',
    'other@forge.name'         => 'someone-else@mailmasker.org',
);
my $resolve = sub { $fake{ lc $_[0] } };
my @env = map { { address => $_, account => $fake{$_} } }
    ('claude67b@forge.name', 'claude67a@giraffenow.org', 'claude67a@forge.name');

my $d = choose_reply_address(account => 'test@mailmasker.org',
    to => ['other@forge.name', 'claude67a@forge.name', 'claude67b@forge.name'], cc => [], envelope => \@env, resolve => $resolve);
is($d->{chosen}, 'claude67a@forge.name', 'first of OUR addresses on the To line wins (another account\'s address skipped)');
is($d->{via}, 'to', '... via to');
is(scalar @{ $d->{candidates} }, 3, 'every one of our addresses listed exactly once');

$d = choose_reply_address(account => 'test@mailmasker.org',
    to => ['list@example.org'], cc => ['claude67a@giraffenow.org'], envelope => \@env, resolve => $resolve);
is($d->{chosen}, 'claude67a@giraffenow.org', 'nothing of ours on To -> first on Cc');
is($d->{via}, 'cc', '... via cc');

$d = choose_reply_address(account => 'test@mailmasker.org',
    to => ['list@example.org'], cc => [], envelope => \@env, resolve => $resolve);
is($d->{chosen}, 'claude67b@forge.name', 'nothing of ours on To/Cc (Bcc, mailing list) -> first envelope recipient');
is($d->{via}, 'envelope', '... via envelope');

$d = choose_reply_address(account => 'test@mailmasker.org',
    to => ['test@mailmasker.org', 'claude67a@forge.name'], cc => [], envelope => \@env, resolve => $resolve);
is($d->{chosen}, 'test@mailmasker.org', 'the real address first on To is chosen (the caller then records nothing)');

$d = choose_reply_address(account => 'test@mailmasker.org',
    to => ['claude67a@forge.name'], cc => [],
    envelope => [ { address => 'claude67b@forge.name', account => 'test@mailmasker.org' } ], resolve => $resolve);
is($d->{chosen}, 'claude67a@forge.name', 'split delivery: a To address missing from THIS envelope still wins through the resolver');

is(choose_reply_address(account => 'test@mailmasker.org', to => ['other@forge.name'], cc => [], envelope => [], resolve => $resolve),
    undef, 'none of ours anywhere -> undef');

my ($old, $new) = ('test@mailmasker.org', 'claude67a@forge.name');
is(rewrite_address_header('Jeff <test@mailmasker.org>', $old, $new), 'Jeff <claude67a@forge.name>', 'Name <old> -> Name <new>');
is(rewrite_address_header('test@mailmasker.org', $old, $new), 'claude67a@forge.name', 'bare old -> new');
is(rewrite_address_header('"test@mailmasker.org" <test@mailmasker.org>', $old, $new), 'claude67a@forge.name',
    'a display name that IS the real address is dropped (no leak)');
is(rewrite_address_header('"Jeff (test@mailmasker.org)" <test@mailmasker.org>', $old, $new), 'claude67a@forge.name',
    'a display name CONTAINING the real address is dropped');
is(rewrite_address_header('=?UTF-8?Q?J=C3=B6rg_G=2E?= <test@mailmasker.org>', $old, $new),
    '=?UTF-8?Q?J=C3=B6rg_G=2E?= <claude67a@forge.name>', 'an encoded-word display name is kept byte for byte');
is(rewrite_address_header("Jeff\r\n <TEST\@mailmasker.org>", $old, $new), 'Jeff <claude67a@forge.name>',
    'folded header unfolded; address match is case-insensitive');
is(rewrite_address_header('Jeff <test@mailmasker.org>, Two <two@x.org>', $old, $new), undef, 'two addresses -> undef (left alone)');
is(rewrite_address_header('Jeff <other@mailmasker.org>', $old, $new), undef, 'a different address -> undef');
is(rewrite_address_header(undef, $old, $new), undef, 'no From at all -> undef');

# --- DB-backed functions -- real Postgres only, same "no mocks" -----------
# convention as every other homelab-* test suite. Point
# HOMELAB_POSTFIX_BLOCK_LINK_CONFIG at a real, already-deployed config.yml
# on a host where homelab-api/domain-admin/block-link are all migrated.
unless ($ENV{HOMELAB_POSTFIX_BLOCK_LINK_CONFIG}) {
    diag('Set HOMELAB_POSTFIX_BLOCK_LINK_CONFIG to a real config.yml to also run the DB-backed tests');
    done_testing;
    exit 0;
}

# require, NOT use: `use` runs at COMPILE time -- before the runtime
# skip-guard above -- so a compile-time `use Homelab::Common::*` fails
# the whole file under CI's `prove -I lib` (which has no homelab-common
# in @INC) even when this section is never meant to run. Loading these
# at runtime, only after the env-var guard, keeps the pure-function
# tests above runnable everywhere while the DB-backed tests still get
# their dependencies in a real deployed environment (where common IS
# installed). Same reason the sibling packages load their App via a
# runtime Test::Mojo->new('...') rather than a compile-time use.
require Homelab::Common::Config; Homelab::Common::Config->import('load_config');
require Homelab::Common::DB;     Homelab::Common::DB->import('runtime_pg');

my $config = load_config('HOMELAB_POSTFIX_BLOCK_LINK_CONFIG', '/etc/homelab/postfix-block-link/config.yml');
my $db = runtime_pg(%{ $config->{database} })->db;

my $domain = 'pbl-test-' . time . '-' . $$ . '.invalid';
my $email  = "user\@$domain";
# Real account, registered below -- tracked for clean-up.
track_account(undef, $email);

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

# Postfix's order: a real mailbox beats the domain catch-all (the pre-0.2.0
# bug resolved the real mailbox to the catch-all's destination).
my $email2 = "catchall-target\@$domain";
track_account(undef, $email2);
$db->query('INSERT INTO api.users (email, password_hash, active) VALUES (?, ?, true)', $email2, 'x')
    unless $db->query('SELECT 1 FROM api.users WHERE email = ?', $email2)->hash;
$db->query(q{INSERT INTO domainadmin.mail_aliases (source_pattern, destination, active, send_enabled)
             VALUES (?, ?, true, true) ON CONFLICT (source_pattern) DO UPDATE SET destination = EXCLUDED.destination},
    '@' . $domain, $email2);
is(resolve_recipient($db, $email), $email, 'a real mailbox at a catch-all domain still resolves to ITSELF');
is(resolve_recipient($db, "nobody\@$domain"), $email2, 'an unknown address at that domain resolves to the catch-all destination');
is(resolve_recipient($db, "NoBody\@\U$domain"), $email2, 'case-insensitive');

# #67 DB-backed helpers.
is(reply_from_alias_enabled($db, $email), 0, 'no mail_reply_identity row means the setting is off');
my $mid = "pbl-test-$$-" . time . '@example.invalid';
is(record_received_via($db, account => $email2, message_id => $mid, chosen => "nobody\@$domain", via => 'to',
    candidates_json => '[{"address":"nobody@' . $domain . '","via":"to"}]'), 1, 'record_received_via inserts one row');
is(record_received_via($db, account => $email2, message_id => $mid, chosen => "other\@$domain", via => 'cc',
    candidates_json => '[]'), 0, 'a second record for the same (account, Message-ID) is a no-op');
is(lookup_received_via($db, $email2, $mid), "nobody\@$domain", 'lookup_received_via returns the first recorded choice');
is(lookup_received_via($db, $email, $mid), undef, 'another account finds nothing under that Message-ID');
is(allowed_to_send_as($db, $email2, $email2), 1, 'a login may always send as itself');
is(allowed_to_send_as($db, $email2, "anything\@$domain"), 1, 'the catch-all destination may send as anything at that domain');
is(allowed_to_send_as($db, $email, "anything\@$domain"), 0, 'another account may not');
$db->query('UPDATE domainadmin.mail_aliases SET send_enabled = false WHERE source_pattern = ?', '@' . $domain);
is(allowed_to_send_as($db, $email2, "anything\@$domain"), 0, 'send_enabled=false revokes it');

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
$db->query('DELETE FROM domainadmin.mail_received_via WHERE message_id = ?', $mid);
$db->query('DELETE FROM domainadmin.mail_aliases WHERE source_pattern = ?', '@' . $domain);
$db->query('DELETE FROM api.users WHERE email IN (?, ?)', $email, $email2);

done_testing;
