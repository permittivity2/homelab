use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(true false);
use Mojo::UserAgent;

# Integration test for soft delete + Trash (migration 009). Same "needs a
# real config + reachable homelab-api" contract as t/api.t / t/uploads.t;
# runs the app in-process. Covers the synchronous parts (soft delete,
# restore, permanent purge, listing exclusion, ownership) -- the
# time-based retention auto-purge is a recurring timer and isn't
# exercised here.
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

my $nth = 0;
sub login_jwt {
    my ($email, $password) = @_;
    $nth++;
    my $preset = $nth == 1 ? $ENV{HOMELAB_DRIVE_TEST_JWT} : $ENV{HOMELAB_DRIVE_TEST_JWT2};
    return $preset if $preset;
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $rtx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    if ($rtx->result->code != 201) {
        my $err = $rtx->result->json('/error') // $rtx->result->body;
        plan skip_all => "cannot self-register a test account ($err) -- set HOMELAB_DRIVE_TEST_JWT[/2] to two real bearer tokens";
    }
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    die "login failed: " . $tx->result->body unless $tx->result->code == 200;
    return $tx->result->json('/token');
}

my $jwt  = login_jwt('e2e-drive-trash-' . time . "-$$" . '@test.mailmasker.org', 'DriveTrash1Aa!!');
my $auth = { Authorization => "Bearer $jwt" };

# Helpers: is file/folder id present in the live listing / in trash?
sub in_files   { my $id = shift; $t->get_ok('/api/v1/files' => $auth); grep { $_->{id} == $id } @{ $t->tx->res->json } }
sub in_trash_f { my $id = shift; $t->get_ok('/api/v1/trash' => $auth); grep { $_->{id} == $id } @{ $t->tx->res->json->{files} } }
sub in_trash_d { my $id = shift; $t->get_ok('/api/v1/trash' => $auth); grep { $_->{id} == $id } @{ $t->tx->res->json->{folders} } }

sub upload_file {
    my $name = shift;
    $t->post_ok('/api/v1/files' => $auth => form => { file => { content => "trash test $name\n", filename => $name } })
      ->status_is(201);
    return $t->tx->res->json('/id');
}

# --- soft delete (?soft=1) moves to Trash; restore brings it back ------
my $fa = upload_file('a.txt');
ok(in_files($fa), 'a.txt is in the live listing after upload');

$t->delete_ok("/api/v1/files/$fa?soft=1" => $auth)->status_is(200)->json_is('/trashed', true);
ok(!in_files($fa), 'soft-deleted file is gone from the live listing');
ok(in_trash_f($fa), 'soft-deleted file is in Trash');

$t->post_ok("/api/v1/files/$fa/restore" => $auth)->status_is(200)->json_is('/ok', true);
ok(in_files($fa), 'restored file is back in the live listing');
ok(!in_trash_f($fa), 'restored file is gone from Trash');

# --- hard delete (no soft) is permanent, never enters Trash -----------
my $fb = upload_file('b.txt');
$t->delete_ok("/api/v1/files/$fb" => $auth)->status_is(200)->json_is('/trashed', false);
ok(!in_files($fb), 'hard-deleted file is gone from the listing');
ok(!in_trash_f($fb), 'hard-deleted file never entered Trash');

# --- a trashed file cannot be used as a concat source -----------------
my $fc = upload_file('c.txt');
$t->delete_ok("/api/v1/files/$fa?soft=1" => $auth)->status_is(200);   # trash a again
$t->post_ok('/api/v1/append-jobs' => $auth => json => { file_ids => [$fa, $fc], output_name => 'x.bin' })
  ->status_is(400);   # $fa is trashed -> "every piece must exist"
$t->post_ok("/api/v1/files/$fa/restore" => $auth)->status_is(200);

# --- permanent purge from Trash --------------------------------------
$t->delete_ok("/api/v1/files/$fc?soft=1" => $auth)->status_is(200);
ok(in_trash_f($fc), 'c.txt is in Trash before purge');
$t->post_ok("/api/v1/files/$fc/purge" => $auth)->status_is(200)->json_is('/ok', true);
ok(!in_trash_f($fc), 'purged file is gone from Trash');
$t->get_ok("/api/v1/files/$fc" => $auth)->status_is(404);   # blob+row really gone

# --- restoring/purging a non-trashed or others' id is a clean 404 -----
$t->post_ok("/api/v1/files/$fa/restore" => $auth)->status_is(404);   # $fa is live, not trashed
$t->post_ok('/api/v1/files/not-a-number/restore' => $auth)->status_is(404);   # malformed id, no 500

# --- folder soft delete is recursive; restore brings the subtree back -
$t->post_ok('/api/v1/folders' => $auth => json => { name => 'tf-' . time })->status_is(201);
my $fold = $t->tx->res->json('/id');
$t->post_ok('/api/v1/files' => $auth => form => { file => { content => "inside\n", filename => 'inside.txt' }, folder_id => $fold })
  ->status_is(201);
my $inside = $t->tx->res->json('/id');

$t->delete_ok("/api/v1/folders/$fold?soft=1" => $auth)->status_is(200);
ok(in_trash_d($fold),  'soft-deleted folder is in Trash');
ok(in_trash_f($inside),'file inside the soft-deleted folder is in Trash too');
ok(!in_files($inside), 'file inside a trashed folder is not in any live listing');

$t->post_ok("/api/v1/folders/$fold/restore" => $auth)->status_is(200);
ok(!in_trash_d($fold),  'restored folder is gone from Trash');
ok(!in_trash_f($inside),'file inside the restored folder is gone from Trash');

# --- ownership: another user can't see/restore/purge my trashed item --
{
    my $other = login_jwt('e2e-drive-trash-other-' . time . "-$$" . '@test.mailmasker.org', 'DriveTrashOther1Aa!!');
    my $oauth = { Authorization => "Bearer $other" };
    $t->delete_ok("/api/v1/files/$fa?soft=1" => $auth)->status_is(200);   # trash mine
    $t->post_ok("/api/v1/files/$fa/restore" => $oauth)->status_is(404);   # not theirs
    $t->post_ok("/api/v1/files/$fa/purge" => $oauth)->status_is(404);
    $t->get_ok('/api/v1/trash' => $oauth)->status_is(200);
    ok(!(grep { $_->{id} == $fa } @{ $t->tx->res->json->{files} }), "another user's Trash does not show my item");
    $t->post_ok("/api/v1/files/$fa/restore" => $auth)->status_is(200);   # restore mine
}

# --- cleanup (hard delete what we created) ----------------------------
$t->delete_ok("/api/v1/files/$fa" => $auth);
$t->delete_ok("/api/v1/folders/$fold" => $auth);

done_testing;
