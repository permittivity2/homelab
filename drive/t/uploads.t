use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(true false);
use Mojo::UserAgent;

# Integration test for the chunked / resumable upload protocol (see
# lib/Homelab/Drive/App.pm's create_upload_session/patch_upload_chunk/...
# and migrations/006-upload-sessions.sql). Same "needs a real config +
# reachable homelab-api" contract as t/api.t; runs the app in-process
# (so it hits drive's own /api/v1/uploads directly, not through the
# homelab-api gateway -- the gateway hop is exercised separately by the
# CLI in tests/e2e).
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

# Two distinct logged-in users are needed (the second is only for the
# ownership check). Preferred source: two ready-made JWTs in
# HOMELAB_DRIVE_TEST_JWT / HOMELAB_DRIVE_TEST_JWT2 -- pass these when the
# environment gates open registration (as the fleet's does, invite-only).
# Otherwise fall back to self-registering throwaway accounts, and
# skip_all (rather than hard-fail) if that registration is gated.
my ($nth_login) = (0);
sub login_jwt {
    my ($email, $password) = @_;
    $nth_login++;
    my $preset = $nth_login == 1 ? $ENV{HOMELAB_DRIVE_TEST_JWT} : $ENV{HOMELAB_DRIVE_TEST_JWT2};
    return $preset if $preset;

    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $rtx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    if ($rtx->result->code != 201) {
        my $err = $rtx->result->json('/error') // $rtx->result->body;
        plan skip_all => "cannot self-register a test account ($err) -- set HOMELAB_DRIVE_TEST_JWT[/2] to two real bearer tokens, or run where open registration is allowed";
    }
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    die "login failed: " . $tx->result->body unless $tx->result->code == 200;
    return $tx->result->json('/token');
}

my $jwt = login_jwt('e2e-drive-up-' . time . "-$$" . '@test.mailmasker.org', 'DriveUpTest1Aa!!');
my $auth = { Authorization => "Bearer $jwt" };

# --- Auth is required on every endpoint ---
$t->post_ok('/api/v1/uploads' => json => { filename => 'x', total_size => 1 })->status_is(401);
$t->get_ok('/api/v1/uploads/00000000-0000-0000-0000-000000000000')->status_is(401);

# --- A malformed (non-UUID) id is a clean 404, never a 500 from the ::uuid cast ---
$t->get_ok('/api/v1/uploads/not-a-uuid' => $auth)->status_is(404);

# --- Full multi-chunk round trip -----------------------------------
my $part_a = 'A' x 100_000;
my $part_b = 'B' x 100_000;
my $part_c = 'C' x 33_333;         # deliberately not a round size
my $whole  = $part_a . $part_b . $part_c;
my $total  = length $whole;

$t->post_ok('/api/v1/uploads' => $auth => json => { filename => 'chunked.bin', total_size => $total })
  ->status_is(201)->json_has('/upload_id')->json_is('/offset', 0);
my $uid = $t->tx->res->json('/upload_id');

# chunk 1 at offset 0
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => 0, 'Content-Type' => 'application/octet-stream' } => $part_a)
  ->status_is(200)->json_is('/offset', length($part_a))->json_is('/done', false);

# A duplicate/stale chunk at offset 0 now -> 409 carrying the TRUE offset
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => 0, 'Content-Type' => 'application/octet-stream' } => $part_a)
  ->status_is(409)->json_is('/offset', length($part_a));

# GET status reports the same authoritative offset
$t->get_ok("/api/v1/uploads/$uid" => $auth)
  ->status_is(200)->json_is('/offset', length($part_a))->json_is('/state', 'open');

# chunk 2 at the right offset
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => length($part_a), 'Content-Type' => 'application/octet-stream' } => $part_b)
  ->status_is(200)->json_is('/offset', length($part_a) + length($part_b));

# A chunk that would overshoot total_size is refused
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => length($part_a) + length($part_b), 'Content-Type' => 'application/octet-stream' } => ($part_c . 'EXTRA'))
  ->status_is(409);

# final chunk -> done, with the new file id
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => length($part_a) + length($part_b), 'Content-Type' => 'application/octet-stream' } => $part_c)
  ->status_is(200)->json_is('/done', true)->json_has('/file_id');
my $file_id = $t->tx->res->json('/file_id');

# the reassembled file is byte-for-byte correct
$t->get_ok("/api/v1/files/$file_id" => $auth)->status_is(200)->content_is($whole);

# a completed session's PATCH is a clean 409 telling the client it's done
$t->patch_ok("/api/v1/uploads/$uid" => { %$auth, 'Upload-Offset' => 0, 'Content-Type' => 'application/octet-stream' } => 'x')
  ->status_is(409)->json_is('/state', 'completed')->json_is('/file_id', $file_id);

# --- Ownership: another user cannot see/append/abort this session ---
{
    my $other = login_jwt('e2e-drive-up-other-' . time . "-$$" . '@test.mailmasker.org', 'DriveUpOther1Aa!!');
    my $oauth = { Authorization => "Bearer $other" };
    $t->post_ok('/api/v1/uploads' => $oauth => json => { filename => 'z.bin', total_size => 10 })->status_is(201);
    my $ouid = $t->tx->res->json('/upload_id');
    # can't reach mine
    $t->get_ok("/api/v1/uploads/$uid" => $oauth)->status_is(404);
    $t->patch_ok("/api/v1/uploads/$uid" => { %$oauth, 'Upload-Offset' => 0, 'Content-Type' => 'application/octet-stream' } => 'x')->status_is(404);
    # abort their own
    $t->delete_ok("/api/v1/uploads/$ouid" => $oauth)->status_is(200)->json_is('/ok', 1);
    $t->get_ok("/api/v1/uploads/$ouid" => $oauth)->status_is(404);
}

# --- Zero-byte file: finalized on create, no PATCH needed ---
$t->post_ok('/api/v1/uploads' => $auth => json => { filename => 'empty.bin', total_size => 0 })
  ->status_is(201)->json_is('/done', true)->json_has('/file_id');
my $empty_id  = $t->tx->res->json('/file_id');
my $empty_uid = $t->tx->res->json('/upload_id');
$t->get_ok("/api/v1/files/$empty_id" => $auth)->status_is(200)->content_is('');
# The session must end 'completed', not linger 'open' (regression: the
# zero-byte path bypasses patch_upload_chunk's state-flip claim, so
# _finalize_upload_session has to set the state itself).
$t->get_ok("/api/v1/uploads/$empty_uid" => $auth)
  ->status_is(200)->json_is('/state', 'completed')->json_is('/file_id', $empty_id);

# --- total_size validation ---
$t->post_ok('/api/v1/uploads' => $auth => json => { filename => 'bad.bin' })->status_is(400);              # missing total_size
$t->post_ok('/api/v1/uploads' => $auth => json => { total_size => 5 })->status_is(400);                    # missing filename
$t->post_ok('/api/v1/uploads' => $auth => json => { filename => 'huge', total_size => 60 * 1024 ** 3 })    # over the 50GiB cap
  ->status_is(413);

# --- cleanup ---
$t->delete_ok("/api/v1/files/$file_id" => $auth)->status_is(200);
$t->delete_ok("/api/v1/files/$empty_id" => $auth)->status_is(200);

done_testing;
