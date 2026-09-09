use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use Mojo::URL;
use File::Temp qw(tempfile);
use Image::Magick;

# Same real end-to-end integration requirements as t/basic.t -- see that
# file's own comment for the full reasoning (real config, a real
# already-running homelab-sso with this deployment's "drive" client
# registered, and a real already-registered homelab-api account).
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml (and HOMELAB_DRIVE_TEST_EMAIL/_PASSWORD for an already-registered account) to run integration tests';
}
unless ($ENV{HOMELAB_DRIVE_TEST_EMAIL} && $ENV{HOMELAB_DRIVE_TEST_PASSWORD}) {
    plan skip_all => 'Set HOMELAB_DRIVE_TEST_EMAIL/_PASSWORD to an already-registered homelab-api account to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

my $email    = $ENV{HOMELAB_DRIVE_TEST_EMAIL};
my $password = $ENV{HOMELAB_DRIVE_TEST_PASSWORD};
my $sso_base = $t->app->sso_base;

# --- log in (same OAuth round trip as t/basic.t) ---
$t->get_ok('/login')->status_is(302);
my $authorize_url = Mojo::URL->new($t->tx->res->headers->location);
my $state        = $authorize_url->query->param('state');
my $client_id    = $authorize_url->query->param('client_id');
my $redirect_uri = $authorize_url->query->param('redirect_uri');
my $scope        = $authorize_url->query->param('scope');

my $sso_ua  = Mojo::UserAgent->new;
my $good_tx = $sso_ua->post("$sso_base/oauth/authorize" => form => {
    client_id => $client_id, redirect_uri => $redirect_uri, state => $state, scope => $scope,
    email => $email, password => $password,
});
my $callback_url = Mojo::URL->new($good_tx->result->headers->location);
my $code = $callback_url->query->param('code');
$t->get_ok("/oauth/callback?code=$code&state=$state")->status_is(302);

sub _count_files {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or die $!;
    my @files = grep { !/^\./ } readdir($dh);
    closedir($dh);
    return scalar @files;
}

my $storage_path  = $t->app->storage_path;
my $thumb_dir      = "$storage_path/.thumbnails";
my $slideshow_dir  = "$storage_path/.slideshow";
my $thumbs_before    = _count_files($thumb_dir);
my $slideshow_before = _count_files($slideshow_dir);

# --- a real image upload gets both derivatives generated synchronously ---
my ($img_fh, $img_path) = tempfile(SUFFIX => '.jpg');
my $img = Image::Magick->new(size => '400x300');
$img->ReadImage('gradient:blue-red');
my $err = $img->Write("jpeg:$img_path");
die "test fixture image write failed: $err\n" if $err;
close($img_fh);
my $original_size = -s $img_path;

$t->post_ok('/upload' => form => { file => { file => $img_path, filename => 'photo.jpg' } })
  ->status_is(302);

$t->get_ok('/')->status_is(200)
  ->content_like(qr/photo\.jpg/)
  ->content_like(qr/class="file-thumb"/, 'file listing shows a thumbnail <img> for the uploaded image');

my ($file_id) = $t->tx->res->body =~ m{data-id="(\d+)"[^>]*data-filename="photo\.jpg"};
ok($file_id, 'found the uploaded image\'s id in the listing page');

is(_count_files($thumb_dir),     $thumbs_before + 1,    'a new thumbnail landed on disk');
is(_count_files($slideshow_dir), $slideshow_before + 1, 'a new slideshow-image landed on disk');

$t->get_ok("/files/$file_id/thumbnail")
  ->status_is(200)
  ->content_type_is('image/jpeg');
my $thumb_bytes = length($t->tx->res->body);
ok($thumb_bytes > 0 && $thumb_bytes < $original_size, 'thumbnail is real, non-empty, and smaller than the original (200x200 max)');

$t->get_ok("/files/$file_id/slideshow-image")
  ->status_is(200)
  ->content_type_is('image/jpeg');
ok(length($t->tx->res->body) > 0, 'slideshow-image response has real image bytes');

# --- a non-image upload must NOT get derivatives, and must not fail the upload itself ---
my ($txt_fh, $txt_path) = tempfile(SUFFIX => '.txt');
print $txt_fh "just some text, not an image\n";
close($txt_fh);

$t->post_ok('/upload' => form => { file => { file => $txt_path, filename => 'notes.txt' } })
  ->status_is(302);
$t->get_ok('/')->status_is(200)->content_like(qr/notes\.txt/);
my ($txt_id) = $t->tx->res->body =~ m{data-id="(\d+)"[^>]*data-filename="notes\.txt"};
ok($txt_id, 'found the uploaded text file\'s id in the listing page');

is(_count_files($thumb_dir),     $thumbs_before + 1, 'no thumbnail was generated for the non-image upload');
is(_count_files($slideshow_dir), $slideshow_before + 1, 'no slideshow-image was generated for the non-image upload');

$t->get_ok("/files/$txt_id/thumbnail")->status_is(404);
$t->get_ok("/files/$txt_id/slideshow-image")->status_is(404);

# --- another user's session must not reach this file's derivatives
# (same "id belongs to someone else -> 404" contract as download()) ---
{
    my $other_email    = 'e2e-drive-thumbs-other-' . time . '-' . $$ . '@test.mailmasker.org';
    my $other_password = 'DriveThumbsOtherTest1Aa!!';
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    $ua->post("$api_base/api/v1/auth/register", json => { email => $other_email, password => $other_password });
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $other_email, password => $other_password });
    my $other_jwt = $tx->result->json('/token');

    $t->get_ok("/files/$file_id/thumbnail" => { Authorization => "Bearer $other_jwt" })
      ->status_is(404);
    $t->get_ok("/files/$file_id/slideshow-image" => { Authorization => "Bearer $other_jwt" })
      ->status_is(404);
}

# --- deleting the file also unlinks its derivatives from disk, not just the original ---
$t->post_ok("/files/$file_id/delete")->status_is(302);
is(_count_files($thumb_dir),     $thumbs_before,    'thumbnail was unlinked from disk when the file was deleted');
is(_count_files($slideshow_dir), $slideshow_before, 'slideshow-image was unlinked from disk when the file was deleted');

$t->post_ok("/files/$txt_id/delete")->status_is(302);

done_testing;
