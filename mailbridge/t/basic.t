use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;

# Full end-to-end integration test -- needs a real config.yml (a real,
# reachable homelab_api.base_url, and real mail.* pointing at a real
# dovecot/postfix) and a real, already-provisioned mailbox account
# (unlike drive/sso's throwaway-account tests: a brand-new homelab-api
# account has no real IMAP mailbox behind it, so this needs one that
# already does -- same HOMELAB_*_TEST_EMAIL/_PASSWORD convention as
# drive/t/basic.t and homelab-cli's own mail tests).
unless ($ENV{HOMELAB_MAILBRIDGE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_MAILBRIDGE_CONFIG to a real config.yml to run integration tests';
}
unless ($ENV{HOMELAB_MAILBRIDGE_TEST_EMAIL} && $ENV{HOMELAB_MAILBRIDGE_TEST_PASSWORD}) {
    plan skip_all => 'Set HOMELAB_MAILBRIDGE_TEST_EMAIL/_PASSWORD to an already-provisioned mailbox account to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::MailBridge::App');

my $email    = $ENV{HOMELAB_MAILBRIDGE_TEST_EMAIL};
my $password = $ENV{HOMELAB_MAILBRIDGE_TEST_PASSWORD};

# Real login against homelab-api -- exactly what homelab-cli itself
# does; no OAuth/browser dance involved for a Bearer-token API client.
my $jwt;
{
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    die "test account login failed: " . $tx->result->body unless $tx->result->code == 200;
    $jwt = $tx->result->json('/token');
}
ok($jwt, 'got a real JWT from homelab-api');
my $auth = { Authorization => "Bearer $jwt" };

$t->get_ok('/health')->status_is(200)->content_is('ok');

# No Authorization header at all -- every route requires one.
$t->get_ok('/api/v1/mail/messages')->status_is(401);

# Send a real message to ourselves, then find it via list, then read it
# back -- a genuine round trip through real IMAP/SMTP, not a mock.
my $subject = 'homelab-mailbridge test ' . time;
my $body    = "test body $$\n";
$t->post_ok('/api/v1/mail/send' => $auth => json => {
    to => $email, subject => $subject, body => $body,
})->status_is(200)->json_is('/ok', 1);

# IMAP delivery isn't instant -- poll briefly rather than assuming a
# fixed sleep is either long enough or not wastefully long.
my ($uid, $found);
for (1 .. 15) {
    $t->get_ok('/api/v1/mail/messages?limit=25' => $auth)->status_is(200);
    my $messages = $t->tx->res->json;
    ($found) = grep { $_->{subject} eq $subject } @$messages;
    last if $found;
    sleep 1;
}
ok($found, 'sent message shows up in the list within 15s') or diag('never appeared');
$uid = $found->{uid} if $found;

SKIP: {
    skip 'message never arrived, cannot test read', 2 unless $uid;
    $t->get_ok("/api/v1/mail/messages/$uid" => $auth)->status_is(200);
    is($t->tx->res->json('/subject'), $subject, 'read-back subject matches what was sent');
    # Real mail servers normalize line endings to canonical CRLF (RFC
    # 5322) on the way through -- confirmed live (a round-tripped body
    # comes back "...\r\n" even though $body above only ever had a bare
    # "\n"), so comparing against the exact bytes we sent would be
    # fighting correct, expected MTA behavior, not testing our own
    # code. Normalize both sides the same way before comparing.
    (my $got_body = $t->tx->res->json('/body')) =~ s/\r\n/\n/g;
    (my $want_body = $body) =~ s/\r\n/\n/g;
    is($got_body, $want_body, 'read-back body matches what was sent (line-ending-normalized)');
}

# --- Optional `from` field (multi-domain send-as, see
# ../../domain-admin/README.md's "Multi-domain send-as" section) ---

# Passing from= as your own address must behave identically to
# omitting it entirely (tested above) -- fully backward compatible.
$t->post_ok('/api/v1/mail/send' => $auth => json => {
    to => $email, subject => "$subject (explicit from)", body => $body, from => $email,
})->status_is(200)->json_is('/ok', 1, 'passing from= as your own address works exactly like omitting it');

# An unauthorized from= is rejected BEFORE any SMTP connection is even
# attempted -- fail-closed defense in depth (Postfix's own
# reject_authenticated_sender_login_mismatch, wired up in
# homelab-postfix, is the real enforcement boundary; this just proves
# mailbridge doesn't even try in the first place).
$t->post_ok('/api/v1/mail/send' => $auth => json => {
    to => $email, subject => 'should never send', body => $body,
    from => 'definitely-not-authorized-' . time . '@unrelated-domain.invalid',
})->status_is(403, 'an unauthorized from= address is rejected, not silently sent as the real user');

# Another user's JWT must not be treated any differently by these
# routes -- there's no per-user data here to leak (mailbridge doesn't
# store anything), but the auth check itself must still hold for an
# obviously-bogus token.
$t->get_ok('/api/v1/mail/messages' => { Authorization => 'Bearer not-a-real-token' })
  ->status_is(401);

done_testing;
