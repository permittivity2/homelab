use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

# Full end-to-end integration test — same HOMELAB_DRIVE_CONFIG
# convention as t/basic.t and t/api.t. Covers real folder hierarchy
# (migrations/002-folders.sql) specifically: create/navigate/delete,
# duplicate-name rejection, cross-user isolation, and that deleting a
# folder actually unlinks every file inside it (recursively) from disk,
# not just the DB rows.
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

my $email    = 'e2e-drive-folders-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'DriveFoldersTest1Aa!!';
my $jwt;
{
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    die "test account registration failed: " . $tx->result->body unless $tx->result->code == 201;
    $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    $jwt = $tx->result->json('/token');
}
my $auth = { Authorization => "Bearer $jwt" };

# --- API: create at root, list at root ---
$t->post_ok('/api/v1/folders' => $auth => json => { name => 'Documents' })
  ->status_is(201)->json_has('/id')->json_is('/name', 'Documents')->json_is('/parent_folder_id', undef);
my $docs_id = $t->tx->res->json('/id');

$t->get_ok('/api/v1/folders' => $auth)->status_is(200);
my $root_folders = $t->tx->res->json;
ok((grep { $_->{id} == $docs_id } @$root_folders), 'the new folder appears in the root listing');

# --- Duplicate name in the same parent is rejected, not silently duplicated ---
$t->post_ok('/api/v1/folders' => $auth => json => { name => 'Documents' })
  ->status_is(409)->json_like('/error', qr/already exists/);

# --- A subfolder nested under it ---
$t->post_ok('/api/v1/folders' => $auth => json => { name => '2026', parent_folder_id => $docs_id })
  ->status_is(201)->json_is('/parent_folder_id', $docs_id);
my $year_id = $t->tx->res->json('/id');

# --- Nesting under someone else's / a nonexistent folder is rejected ---
$t->post_ok('/api/v1/folders' => $auth => json => { name => 'x', parent_folder_id => 999999999 })
  ->status_is(409)->json_like('/error', qr/parent folder not found/);

# --- Upload into a specific folder via the API, list scoped to it ---
my $content = "folder test content " . time . "\n";
my ($fh, $path) = tempfile(SUFFIX => '.txt');
print $fh $content;
close($fh);

$t->post_ok('/api/v1/files' => $auth => form => { folder_id => $year_id, file => { file => $path, filename => 'report.txt' } })
  ->status_is(201)->json_is('/folder_id', $year_id);
my $file_id = $t->tx->res->json('/id');

$t->get_ok("/api/v1/files?folder_id=$year_id" => $auth)->status_is(200);
my $year_files = $t->tx->res->json;
is(scalar @$year_files, 1, 'exactly one file in the 2026 folder');
is($year_files->[0]{id}, $file_id, 'it\'s the one just uploaded');

# Root listing (no folder_id) must NOT include a file that's inside a folder.
$t->get_ok('/api/v1/files' => $auth)->status_is(200);
ok(!(grep { $_->{id} == $file_id } @{ $t->tx->res->json }), 'the file inside a folder does not appear in the root listing');

# --- Browser: GET /folders/:id shows the right breadcrumb/contents ---
# (the Bearer header works here too -- _current_email() checks it before
# falling back to a session cookie, so this doesn't need a real browser
# session to exercise the browser-facing route)
$t->get_ok("/folders/$year_id" => $auth)->status_is(200)
  ->content_like(qr/report\.txt/)
  ->content_like(qr/Documents/)   # breadcrumb
  ->content_like(qr/2026/);

# --- Cross-user isolation: another account can't see or reach any of this ---
{
    my $other_email    = 'e2e-drive-folders-other-' . time . '-' . $$ . '@test.mailmasker.org';
    my $other_password = 'DriveFoldersOtherTest1Aa!!';
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    $ua->post("$api_base/api/v1/auth/register", json => { email => $other_email, password => $other_password });
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $other_email, password => $other_password });
    my $other_auth = { Authorization => 'Bearer ' . $tx->result->json('/token') };

    $t->get_ok("/api/v1/folders?parent_id=$docs_id" => $other_auth)->status_is(404);
    $t->post_ok('/api/v1/folders' => $other_auth => json => { name => 'x', parent_folder_id => $docs_id })
      ->status_is(409)->json_like('/error', qr/parent folder not found/);
    $t->delete_ok("/api/v1/folders/$docs_id" => $other_auth)->status_is(404);
}

# --- Deleting the parent folder cascades: subfolder AND file both gone,
# and the file's on-disk blob is actually unlinked, not just the DB row ---
my $storage_path = $t->app->storage_path;
opendir(my $dh, $storage_path) or die $!;
my @before = grep { !/^\./ } readdir($dh);
closedir($dh);

$t->delete_ok("/api/v1/folders/$docs_id" => $auth)->status_is(200)->json_is('/ok', 1);

$t->get_ok("/api/v1/folders?parent_id=$docs_id" => $auth)->status_is(404);   # docs_id itself is gone
$t->get_ok("/api/v1/files?folder_id=$year_id" => $auth)->status_is(404);     # year_id (subfolder) is gone too
$t->get_ok("/api/v1/files/$file_id" => $auth)->status_is(404);               # the file inside is gone

opendir($dh, $storage_path) or die $!;
my @after = grep { !/^\./ } readdir($dh);
closedir($dh);
is(scalar(@after), scalar(@before) - 1, 'exactly one file was unlinked from disk by the recursive folder delete');

# --- Deleting an already-gone / nonexistent folder is a clean 404 ---
$t->delete_ok("/api/v1/folders/$docs_id" => $auth)->status_is(404);

done_testing;
