use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Certificate store: auth posture + the two behaviours that are easy to get
# wrong and expensive to get wrong -- publish idempotency, and MONOTONIC
# promotion (a late-arriving OLDER serial must never demote a newer live
# certificate). Same HOMELAB_API_CONFIG convention as t/admin.t.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

# --- unauthenticated: 401 on every route, never a crash or a leak ---
$t->post_ok('/api/v1/certstore/publish', json => {})->status_is(401);
$t->get_ok('/api/v1/certstore/example.test')->status_is(401);
$t->get_ok('/api/v1/admin/certstore')->status_is(401);

# --- a valid NON-agent token is 403, not 401 (authenticated but not
#     authorised -- the same distinction t/admin.t asserts) ---
my $suffix = time . '-' . $$;
my ($email, $password) = ("certstore-$suffix\@test.mailmasker.org", 'CertTest1Aa!!');
$t->post_ok('/api/v1/auth/register', json => { email => $email, password => $password })->status_is(201);
$t->post_ok('/api/v1/auth/login',    json => { email => $email, password => $password })->status_is(200);
my $jwt = $t->tx->res->json('/token');
ok($jwt, 'got a token for a plain user');

$t->post_ok('/api/v1/certstore/publish',
    { Authorization => "Bearer $jwt" }, json => { lineage => 'x', serial => 'y' })->status_is(403);
$t->get_ok('/api/v1/certstore/example.test',
    { Authorization => "Bearer $jwt" })->status_is(403);

# Everything below needs a system_agent credential. Rather than mint one here
# (which would mean creating a synthetic agent identity as a side effect of a
# test run), those paths are covered by the live verification in the cert-sync
# rollout. What IS asserted above is the gate itself: no token => 401,
# wrong role => 403, on every route.

SKIP: {
    my $agent_jwt = $ENV{HOMELAB_TEST_AGENT_JWT};
    skip 'set HOMELAB_TEST_AGENT_JWT to a system_agent token to exercise publish/fetch', 12
        unless $agent_jwt;

    my $auth    = { Authorization => "Bearer $agent_jwt" };
    my $lineage = "test-$suffix.example";
    my $blob    = 'v1:' . 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=';

    my %base = (
        lineage => $lineage,
        cert_enc => $blob, chain_enc => $blob, fullchain_enc => $blob, privkey_enc => $blob,
        sha256_fullchain => 'a' x 64, sha256_privkey => 'b' x 64,
        domains => [$lineage],
    );

    # --- required-field validation ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => { lineage => $lineage })->status_is(400);

    # --- plaintext key material is REFUSED. This is the single most
    #     important guard: the store must never hold a decryptable key. ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => {
        %base, serial => 'PLAINTEXT01',
        not_before => '2026-01-01T00:00:00Z', not_after => '2026-04-01T00:00:00Z',
        # assembled at runtime so this source file carries no literal PEM
        # private-key header for gitleaks to flag (see common/t/keyvault.t)
        privkey_enc => join('', '-----BEGIN ', 'PRIVATE KEY', "-----\nnope\n"),
    })->status_is(400)->json_like('/error', qr/envelope-encrypted/);

    # --- first publish: inserted + promoted ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => {
        %base, serial => 'AAAA1111',
        not_before => '2026-01-01T00:00:00Z', not_after => '2026-04-01T00:00:00Z',
    })->status_is(200)->json_is('/inserted', 1)->json_is('/promoted', 1);

    # --- republishing the SAME serial is a silent no-op, not an error.
    #     (The deploy-hook and the reconcile timer both publish by design.) ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => {
        %base, serial => 'AAAA1111',
        not_before => '2026-01-01T00:00:00Z', not_after => '2026-04-01T00:00:00Z',
    })->status_is(200)->json_is('/inserted', 0);

    # --- a NEWER cert promotes ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => {
        %base, serial => 'BBBB2222',
        not_before => '2026-03-01T00:00:00Z', not_after => '2026-06-01T00:00:00Z',
    })->status_is(200)->json_is('/inserted', 1)->json_is('/promoted', 1);
    $t->get_ok("/api/v1/certstore/$lineage", $auth)->status_is(200)->json_is('/serial', 'BBBB2222');

    # --- an OLDER serial arriving late (a drained spool entry) is stored but
    #     must NOT become current. This is the regression that would silently
    #     roll every consumer back onto an expiring certificate. ---
    $t->post_ok('/api/v1/certstore/publish', $auth, json => {
        %base, serial => 'CCCC0000',
        not_before => '2025-11-01T00:00:00Z', not_after => '2026-02-01T00:00:00Z',
    })->status_is(200)->json_is('/inserted', 1)->json_is('/promoted', 0);
    $t->get_ok("/api/v1/certstore/$lineage", $auth)->status_is(200)
      ->json_is('/serial', 'BBBB2222', 'an older serial did not demote the newer live cert');

    # --- unknown lineage is a clean 404 ---
    $t->get_ok('/api/v1/certstore/nope-' . $suffix . '.example', $auth)->status_is(404);
}

done_testing;
