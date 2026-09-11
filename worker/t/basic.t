use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres AND real,
# reachable homelab-api + zip-fetch targets -- point HOMELAB_WORKER_CONFIG
# at a real, already-deployed config.yml (matches api/t/basic.t's own
# convention; no mocks). The zip job's fetch entries hit homelab-api's
# OWN reachable endpoints (/health, /api/v1/auth/introspect) rather than
# homelab-drive -- this package is deliberately drive-agnostic (see
# README.md), so exercising the real fetch+bundle path needs no other
# feature package installed at all.
unless ($ENV{HOMELAB_WORKER_CONFIG}) {
    plan skip_all => 'Set HOMELAB_WORKER_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
use Archive::Zip;
use File::Temp;
use Mojo::UserAgent;

my $t = Test::Mojo->new('Homelab::Worker::App');
my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;

# --- Two real accounts: $email (the job owner) and $stranger (starts as
# a plain user to prove ownership isolation, then gets site_admin to
# prove the admin-override rules) ---
sub _register_and_login {
    my ($label) = @_;
    my $email    = "e2e-worker-$label-" . time . '-' . $$ . '@test.mailmasker.org';
    my $password = 'WorkerTest1Aa!!';
    $ua->post("$api_base/api/v1/auth/register" => json => { email => $email, password => $password });
    my $login_tx = $ua->post("$api_base/api/v1/auth/login" => json => { email => $email, password => $password });
    my $jwt = $login_tx->res->json('/token');
    ok($jwt, "got a real JWT for $label") or BAIL_OUT('cannot continue without a real login');
    return ($email, { Authorization => "Bearer $jwt" }, $jwt);
}

my ($email,    $auth,          $jwt)          = _register_and_login('owner');
my ($stranger, $stranger_auth, $stranger_jwt) = _register_and_login('stranger');

# --- Auth required on every route ---
$t->get_ok('/internal/v1/jobs')->status_is(401, 'no Authorization header -> 401');
$t->post_ok('/internal/v1/jobs' => json => { type => 'zip', input => {} })->status_is(401);

# --- Validation ---
$t->post_ok('/internal/v1/jobs' => $auth => json => { type => 'not_a_real_type', input => {} })
  ->status_is(400, 'unknown job type is rejected at submission time, not discovered later by the runner');

$t->post_ok('/internal/v1/jobs' => $auth => json => { type => 'zip' })
  ->status_is(400, 'input is required');

# --- A real zip job: one public entry, one entry needing its own
# forwarded auth_header (the actual mechanism this whole design exists
# for -- see README.md's "the auth hand-off" section) ---
$t->post_ok('/internal/v1/jobs' => $auth => json => {
    type => 'zip',
    input => {
        output_name => 'e2e-test.zip',
        entries => [
            { fetch_url => "$api_base/health", zip_path => 'health.txt' },
            { fetch_url => "$api_base/api/v1/auth/introspect", zip_path => 'nested/introspect.json',
              auth_header => "Bearer $jwt" },
        ],
    },
})->status_is(201)->json_is('/state', 'pending')->json_is('/type', 'zip')
  or diag explain $t->tx->res->json;
my $job_id = $t->tx->res->json('/id');
ok($job_id, 'got a real job id') or BAIL_OUT('job creation failed -- cannot continue');

# --- Ownership isolation: a different, non-admin account can't see this
# job at all (indistinguishable 404, not 403 -- matches this codebase's
# existing convention) ---
$t->get_ok("/internal/v1/jobs/$job_id" => $stranger_auth)
  ->status_is(404, 'a non-owner, non-admin account gets a clean 404, not the job');
$t->get_ok("/internal/v1/jobs/$job_id/download" => $stranger_auth)->status_is(404);

# --- Listing: scoped to the caller by default, for every caller ---
my $owned = $t->get_ok('/internal/v1/jobs' => $auth)->status_is(200)->tx->res->json;
ok((grep { $_->{id} == $job_id } @$owned), 'owner\'s own list includes the job');

my $strangers_list = $t->get_ok('/internal/v1/jobs' => $stranger_auth)->status_is(200)->tx->res->json;
ok(!(grep { $_->{id} == $job_id } @$strangers_list), 'a different account\'s own list does NOT include it');

$t->get_ok('/internal/v1/jobs?all=1' => $auth)
  ->status_is(403, 'a non-admin requesting ?all=1 is a clean 403, not a silently-scoped-down 200');

# --- Wait for the real recurring-timer-driven claim/run/complete cycle
# to finish (timer fires every 5s -- see App.pm) -- each blocking
# Test::Mojo call below pumps the same in-process IOLoop the recurring
# timer lives on, so real wall-clock sleep between polls is sufficient
# for it to have fired. ---
sub _wait_for_terminal_state {
    my ($job_id, $timeout) = @_;
    for (1 .. $timeout) {
        my $row = $t->get_ok("/internal/v1/jobs/$job_id" => $auth)->status_is(200)->tx->res->json;
        return $row if $row->{state} eq 'completed' || $row->{state} eq 'failed';
        sleep 1;
    }
    return undef;
}

my $finished = _wait_for_terminal_state($job_id, 30);
ok($finished, 'zip job reached a terminal state within 30s')
    or BAIL_OUT('job never finished -- cannot continue (check homelab-worker logs)');
is($finished->{state}, 'completed', 'the real fetch+bundle job type run completed successfully')
    or diag explain $finished;
ok($finished->{output_size_bytes} > 0, 'completed job reports a real output size');

# --- Download the real artifact and verify its actual contents --
# round-tripping through a real Archive::Zip read, not just checking
# HTTP status codes. ---
my $download_tx = $t->ua->get("/internal/v1/jobs/$job_id/download" => $auth);
is($download_tx->res->code, 200, 'download succeeds once completed');
my $tmp = File::Temp->new(SUFFIX => '.zip');
$download_tx->res->save_to("$tmp");

my $zip = Archive::Zip->new;
is($zip->read("$tmp"), Archive::Zip::AZ_OK(), 'downloaded file is a real, readable zip archive');
is($zip->contents('health.txt'), 'ok', 'public entry (no auth_header) fetched and bundled correctly');
like($zip->contents('nested/introspect.json'), qr/\Q$email\E/,
    'authenticated entry was fetched using the per-entry forwarded auth_header, and nested zip_path preserved');

# --- Admin override: stranger starts unable to see the job (already
# proven above); granted site_admin, the SAME account can now see and
# download ANY user's job, not just their own (matches homelab-api's own
# /api/v1/admin/users precedent). Direct SQL grant -- there is no
# self-service "become an admin" API by design, same fallback tier every
# bootstrap script in this repo already uses (see
# homelab-domain-admin/t/basic.t for the identical pattern). ---
{
    my $sql = "INSERT INTO api.user_roles (user_id, role_id) " .
        "SELECT u.id, r.id FROM api.users u, api.roles r WHERE u.email = '$stranger' AND r.name = 'site_admin'";
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
    die "could not grant site_admin to $stranger for testing (needs passwordless sudo to postgres) -- see t/basic.t\n"
        if $? != 0;
}

$t->get_ok("/internal/v1/jobs/$job_id" => $stranger_auth)
  ->status_is(200, 'site_admin can view a job it does not own, by id');
$t->get_ok("/internal/v1/jobs/$job_id/download" => $stranger_auth)
  ->status_is(200, 'site_admin can download a job it does not own');

my $all = $t->get_ok('/internal/v1/jobs?all=1' => $stranger_auth)
  ->status_is(200, 'site_admin\'s ?all=1 request succeeds')
  ->tx->res->json;
ok((grep { $_->{id} == $job_id } @$all), '?all=1 as site_admin includes a job owned by someone else');

# --- A job that fails for real (unreachable fetch target) lands in
# 'failed' with a clear error_message, and download is a 409, not a
# confusing 200/404. ---
$t->post_ok('/internal/v1/jobs' => $auth => json => {
    type => 'zip',
    input => { output_name => 'will-fail.zip', entries => [
        { fetch_url => 'http://127.0.0.1:1/unreachable', zip_path => 'nope.txt' },
    ] },
})->status_is(201);
my $fail_job_id = $t->tx->res->json('/id');

my $failed = _wait_for_terminal_state($fail_job_id, 30);
ok($failed, 'the doomed job also reaches a terminal state, not left running forever');
is($failed->{state}, 'failed', 'a job whose fetch target is unreachable ends up failed, not stuck');
ok(length($failed->{error_message} // ''), 'a failed job carries a real, human-readable error_message');

$t->get_ok("/internal/v1/jobs/$fail_job_id/download" => $auth)
  ->status_is(409, 'downloading a non-completed job is a clean 409, not a 404 or a broken 200');

# --- Nonexistent job id ---
$t->get_ok('/internal/v1/jobs/999999999' => $auth)->status_is(404);

done_testing;
