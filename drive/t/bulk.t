use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use File::Temp qw(tempfile);
use Archive::Zip qw(:ERROR_CODES);

# Full end-to-end integration test — same HOMELAB_DRIVE_CONFIG
# convention as t/basic.t/t/folders.t. Covers bulk select: delete
# (mixed files+folders, the folder-containing-a-selected-file not_found
# case) and the zip-job flow (manifest resolution's two real edge
# cases -- folder+nested-file dedup, duplicate-filename renaming --
# plus a REAL end-to-end job through homelab-worker's own claim/run
# cycle, downloaded and unzipped to confirm actual archive contents).
# The zip half additionally needs a real, already-registered, reachable
# homelab-worker (see ../../worker/README.md) -- there's no way to fake
# that dependency away and still prove the real hand-off works.
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

my $email    = 'e2e-drive-bulk-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'DriveBulkTest1Aa!!';
{
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    die "test account registration failed: " . $tx->result->body unless $tx->result->code == 201;
    $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    my $jwt = $tx->result->json('/token');
    # Deliberately auto-attached here (rather than threading an explicit
    # $auth hashref through every call, t/folders.t's own convention) --
    # this file makes many more requests as this one account than
    # t/folders.t does, and every call below that needs a DIFFERENT
    # identity (the cross-user ownership checks) passes its own explicit
    # Authorization header, which the "unless already set" guard here
    # respects rather than overriding.
    $t->ua->on(start => sub {
        my ($ua2, $tx2) = @_;
        $tx2->req->headers->authorization("Bearer $jwt") unless $tx2->req->headers->authorization;
    });
}

sub upload_text {
    my ($content, $filename, $folder_id) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.txt');
    print $fh $content;
    close($fh);
    my %form = (file => { file => $path, filename => $filename });
    $form{folder_id} = $folder_id if $folder_id;
    $t->post_ok('/api/v1/files' => form => \%form)->status_is(201);
    return $t->tx->res->json('/id');
}

sub mkdir_ {
    my ($name, $parent_id) = @_;
    my %body = (name => $name);
    $body{parent_folder_id} = $parent_id if $parent_id;
    $t->post_ok('/api/v1/folders' => json => \%body)->status_is(201);
    return $t->tx->res->json('/id');
}

# --- Fixture: Documents/2026/report.txt, Documents/notes.txt (root of
# Documents), and a standalone root file top.txt, plus an Empty folder
# with nothing in it. ---
my $docs_id = mkdir_('Documents');
my $year_id = mkdir_('2026', $docs_id);
my $empty_id = mkdir_('Empty');
my $report_id = upload_text("report $$\n", 'report.txt', $year_id);
my $notes_id  = upload_text("notes $$\n", 'notes.txt', $docs_id);
my $top_id    = upload_text("top $$\n", 'top.txt');

# =====================================================================
# Bulk delete
# =====================================================================

# Select $empty_id (folder) and $top_id (root file, unrelated to it) --
# both real, independent, no overlap.
$t->post_ok('/bulk/delete' => json => { file_ids => [$top_id], folder_ids => [$empty_id] })
  ->status_is(200)
  ->json_is('/counts/deleted', 2)->json_is('/counts/not_found', 0)
  ->json_is('/files/deleted' => [$top_id])
  ->json_is('/folders/deleted' => [$empty_id]);

$t->get_ok("/api/v1/files/$top_id")->status_is(404);
$t->get_ok("/api/v1/folders?parent_id=$empty_id")->status_is(404);

# Select Documents (folder, cascades to 2026/report.txt and notes.txt)
# AND notes.txt individually, at the same time -- notes.txt is already
# gone by the time its own delete is attempted (folders processed
# first), so it reports not_found even though the user's overall intent
# ("get rid of all of this") was fully satisfied -- see README.md.
$t->post_ok('/bulk/delete' => json => { file_ids => [$notes_id], folder_ids => [$docs_id] })
  ->status_is(200)
  ->json_is('/folders/deleted' => [$docs_id])
  ->json_is('/files/not_found' => [$notes_id])
  ->json_is('/counts/deleted', 1)->json_is('/counts/not_found', 1);

$t->get_ok("/api/v1/folders?parent_id=$docs_id")->status_is(404);
$t->get_ok("/api/v1/files/$report_id")->status_is(404);

# A nonexistent id is just cleanly not_found, not a request-level error.
$t->post_ok('/bulk/delete' => json => { file_ids => [999999999], folder_ids => [999999998] })
  ->status_is(200)
  ->json_is('/counts/deleted', 0)->json_is('/counts/not_found', 2);

# =====================================================================
# Zip: manifest resolution + a real end-to-end job via homelab-worker
# =====================================================================

# Waits (bounded, so a genuinely broken worker fails the test instead of
# hanging CI forever) for a job to leave pending/running, downloads its
# artifact once completed, and returns a real, already-`read()`
# Archive::Zip object -- shared by both zip scenarios below.
sub run_zip_job_and_fetch_archive {
    my ($body) = @_;
    $t->post_ok('/zip-jobs' => json => $body)->status_is(201)->json_has('/id')->json_is('/state', 'pending');
    my $job_id = $t->tx->res->json('/id');
    ok($job_id, 'homelab-worker returned a real job id');

    my $job;
    for (1 .. 30) {
        $t->get_ok("/zip-jobs/$job_id")->status_is(200);
        $job = $t->tx->res->json;
        last if $job->{state} eq 'completed' || $job->{state} eq 'failed';
        sleep 1;
    }
    is($job->{state}, 'completed', 'the zip job reached a real completed state via homelab-worker\'s own timer')
        or diag("job ended in state '$job->{state}': " . ($job->{error_message} // ''));

    $t->get_ok("/zip-jobs/$job_id/download")->status_is(200);
    my $zip_bytes = $t->tx->res->body;
    ok(length($zip_bytes) > 0, 'downloaded a non-empty archive');

    my ($fh, $zip_path) = tempfile(SUFFIX => '.zip');
    binmode $fh;
    print $fh $zip_bytes;
    close $fh;

    my $zip = Archive::Zip->new;
    is($zip->read($zip_path), AZ_OK, 'the downloaded bytes are a real, readable zip archive');
    return ($zip, $job_id);
}

# --- Nothing selected -> a clean 400, not a pointless empty job ---
$t->post_ok('/zip-jobs' => json => { file_ids => [], folder_ids => [] })->status_is(400);

# --- Scenario 1: a folder AND a file already inside it both selected --
# collapses to ONE archive entry at the NESTED path, not a duplicate. ---
my $photos_id      = mkdir_('Photos');
my $photos2024_id  = mkdir_('2024', $photos_id);
my $img_id         = upload_text("jpgbytes $$\n", 'img.jpg', $photos2024_id);

{
    my $other_email    = 'e2e-drive-bulk-other-' . time . '-' . $$ . '@test.mailmasker.org';
    my $other_password = 'DriveBulkOtherTest1Aa!!';
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    $ua->post("$api_base/api/v1/auth/register", json => { email => $other_email, password => $other_password });
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $other_email, password => $other_password });
    my $other_jwt = $tx->result->json('/token');

    my ($zip, $job_id) = run_zip_job_and_fetch_archive({ file_ids => [$img_id], folder_ids => [$photos_id] });
    $t->get_ok("/zip-jobs/$job_id" => { Authorization => "Bearer $other_jwt" })->status_is(404);

    my @names = sort map { $_->fileName } $zip->members;
    is_deeply(\@names, ['Photos/2024/img.jpg'],
        'the folder+its-own-nested-file selection collapsed to exactly one entry, at the nested path');
}

# --- Scenario 2: two files with the SAME filename, in different
# folders, selected INDIVIDUALLY (not via their folders, so both
# resolve to a bare root-level zip_path) -- a real collision, resolved
# by _dedupe_zip_path's numbered-suffix rename. Distinct content per
# file proves these are genuinely two different files archived twice,
# not one file duplicated. ---
my $folder_a_id = mkdir_('FolderA');
my $folder_b_id = mkdir_('FolderB');
my $content_a = "content-from-folder-a-$$\n";
my $content_b = "content-from-folder-b-$$\n";
my $dup_a_id = upload_text($content_a, 'dup.txt', $folder_a_id);
my $dup_b_id = upload_text($content_b, 'dup.txt', $folder_b_id);

{
    my ($zip) = run_zip_job_and_fetch_archive({ file_ids => [$dup_a_id, $dup_b_id], folder_ids => [] });

    my @names = sort map { $_->fileName } $zip->members;
    is_deeply(\@names, ['dup (01).txt', 'dup.txt'],
        'a real filename collision between two individually-selected files got a numbered-suffix rename, not silently dropped/overwritten');

    # scalar() on ->contents is required, not stylistic -- in list
    # context (a map block's own block is always list context)
    # Archive::Zip::Member::contents returns (data, status), which
    # silently flattened this map into more than 2 pairs per member and
    # corrupted the resulting hash entirely (caught by hand-inspecting
    # the actual archive members while debugging a spurious-looking
    # failure here -- the archive itself was always correct).
    my %contents = map { $_->fileName => scalar $_->contents } $zip->members;
    my %by_content = map { $contents{$_} => $_ } keys %contents;
    ok((exists $by_content{$content_a} && exists $by_content{$content_b}),
        'both real, distinct files are present under their (possibly renamed) paths -- not the same file archived twice');
}

done_testing;
