use strict;
use warnings;
use Test::More;
use Test::Mojo;
use File::Temp qw(tempfile);

# Full end-to-end integration test — needs a real config.yml (real
# runtime DB credentials, migrations already applied) AND a real,
# reachable homelab-api (homelab_api.base_url in that config) with a
# real test account already registered, since login here proxies
# through to it. Same HOMELAB_*_CONFIG convention as every other
# homelab-* Mojolicious app's tests.
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

$t->get_ok('/health')->status_is(200)->content_is('ok');

# Not logged in — / must bounce to /login, not show anything.
$t->get_ok('/')->status_is(302)->header_is(Location => '/login');

$t->post_ok('/login', form => { email => $email, password => 'definitely-wrong' })
  ->status_is(200)
  ->content_like(qr/Login failed|invalid/i);

$t->post_ok('/login', form => { email => $email, password => $password })
  ->status_is(302)
  ->header_is(Location => '/');

$t->get_ok('/')->status_is(200)->content_like(qr/\Q$email\E/);

# Upload a small real file, confirm it shows up in the listing, then
# download it back and confirm the bytes round-trip exactly.
my $content = "test file content " . time . "\n";
my ($fh, $path) = tempfile(SUFFIX => '.txt');
print $fh $content;
close($fh);

$t->post_ok('/upload' => form => { file => { file => $path, filename => 'roundtrip.txt' } })
  ->status_is(302);

$t->get_ok('/')->status_is(200)->content_like(qr/roundtrip\.txt/);

# Find the uploaded file's id by scraping the download link out of the
# page — no separate "list files as JSON" endpoint exists yet, so this
# is the most direct way to get a real id for the next two requests.
my ($file_id) = $t->tx->res->body =~ m{/files/(\d+)/download};
ok($file_id, 'found the uploaded file\'s id in the listing page');

$t->get_ok("/files/$file_id/download")
  ->status_is(200)
  ->content_is($content);
$t->header_like('Content-Disposition', qr/roundtrip\.txt/);

$t->post_ok("/files/$file_id/delete")->status_is(302);
$t->get_ok('/')->status_is(200)->content_unlike(qr/roundtrip\.txt/);

# A deleted file's download link must be genuinely gone, not just
# hidden from the listing.
$t->get_ok("/files/$file_id/download")->status_is(404);

$t->post_ok('/logout')->status_is(302)->header_is(Location => '/login');

# After logout, the session cookie is gone — / must bounce again.
$t->get_ok('/')->status_is(302)->header_is(Location => '/login');

done_testing;
