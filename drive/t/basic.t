use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use Mojo::URL;
use File::Temp qw(tempfile);

# Full end-to-end integration test — needs a real config.yml (real
# runtime DB credentials, migrations already applied, a real sso.*
# section pointing at a real, already-running homelab-sso that has this
# deployment's actual "drive" client registered) AND a real, already-
# registered homelab-api test account, since login here goes all the
# way through a real OAuth round trip to homelab-sso. Same
# HOMELAB_*_CONFIG convention as every other homelab-* Mojolicious
# app's tests.
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

$t->get_ok('/health')->status_is(200)->content_is('ok');

# Not logged in — / must bounce to /login, not show anything.
$t->get_ok('/')->status_is(302)->header_is(Location => '/login');

# /login redirects to homelab-sso's own /oauth/authorize — this app has
# no password form of its own any more (see App.pm). This request also
# stashes a CSRF `state` nonce in Drive's own session (Test::Mojo's
# cookie jar), which /oauth/callback checks further down.
$t->get_ok('/login')->status_is(302);
my $authorize_url = Mojo::URL->new($t->tx->res->headers->location);
is($authorize_url->path, '/oauth/authorize', "redirects to homelab-sso's authorize endpoint");
my $state        = $authorize_url->query->param('state');
my $client_id    = $authorize_url->query->param('client_id');
my $redirect_uri = $authorize_url->query->param('redirect_uri');
my $scope        = $authorize_url->query->param('scope');
ok($state, 'a real CSRF state nonce was generated');

# Simulate the user submitting their credentials on homelab-sso's own
# login form — a real network call to the real, already-running
# homelab-sso this config points at (a plain Mojo::UserAgent, NOT
# dispatched through Drive's own Test::Mojo instance, since it's a
# genuinely different app/process).
my $sso_ua = Mojo::UserAgent->new;
my $bad_tx = $sso_ua->post("$sso_base/oauth/authorize" => form => {
    client_id => $client_id, redirect_uri => $redirect_uri, state => $state, scope => $scope,
    email => $email, password => 'definitely-wrong',
});
like($bad_tx->result->body, qr/failed|log in/i, "homelab-sso rejects the wrong password (redisplays its own form)");

my $good_tx = $sso_ua->post("$sso_base/oauth/authorize" => form => {
    client_id => $client_id, redirect_uri => $redirect_uri, state => $state, scope => $scope,
    email => $email, password => $password,
});
is($good_tx->result->code, 302, 'homelab-sso accepts the real credentials and redirects back');
my $callback_url = Mojo::URL->new($good_tx->result->headers->location);
is($callback_url->query->param('state'), $state, 'state is echoed back unchanged');
my $code = $callback_url->query->param('code');
ok($code, 'a real authorization code was issued');

# Hand the code to Drive's own callback — dispatched in-process
# (Test::Mojo), same session/cookie-jar as the /login request above, so
# the CSRF state check inside oauth_callback() sees the nonce it
# stashed there. Drive itself now makes the real server-to-server
# code-exchange call out to homelab-sso (Homelab::Common::SSOClient) —
# not mocked.
$t->get_ok("/oauth/callback?code=$code&state=$state")
  ->status_is(302)
  ->header_is(Location => '/');

$t->get_ok('/')->status_is(200)->content_like(qr/\Q$email\E/)
  # Bytes/Human-Readable size toggle lives in the page header, so it's
  # present regardless of whether this folder has any files yet.
  ->content_like(qr/id="size-unit-toggle"/, 'size unit toggle control is present');

# Upload a small real file, confirm it shows up in the listing, then
# download it back and confirm the bytes round-trip exactly.
my $content = "test file content " . time . "\n";
my ($fh, $path) = tempfile(SUFFIX => '.txt');
print $fh $content;
close($fh);

$t->post_ok('/upload' => form => { file => { file => $path, filename => 'roundtrip.txt' } })
  ->status_is(302);

$t->get_ok('/')->status_is(200)->content_like(qr/roundtrip\.txt/)
  # The size cell needs this class for the client-side bytes/human-
  # readable toggle to find and reformat it.
  ->content_like(qr/class="file-size"/, 'file size cell has the toggle\'s class hook')
  # uploaded_at_display: to_char(..., 'TZ') pulls a real zone
  # abbreviation (e.g. "CDT") straight from the session's `timezone`
  # GUC (a real IANA zone, "America/Chicago" on this deployment — see
  # README.md) and, as a side effect of the explicit format string,
  # drops fractional seconds. A raw numeric offset like "-05" would NOT
  # match here (digits/dash, not letters) -- catches a regression back
  # to the old plain-offset display just as much as it confirms the
  # fractional-seconds trim.
  ->content_like(qr/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [A-Z]{2,5}\b/,
    'upload time displays with no fractional seconds and a real timezone abbreviation');

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

# Logout redirects to homelab-sso's own /logout rather than clearing
# just this app's cookie — that's what makes it a real, single logout
# instead of only a local one (see ../../sso/README.md).
$t->post_ok('/logout')->status_is(302);
my $logout_url = Mojo::URL->new($t->tx->res->headers->location);
is($logout_url->path, '/logout', "logout redirects to homelab-sso's own /logout");
like($logout_url->to_string, qr/^\Q$sso_base\E/, 'targets the configured homelab-sso instance');
is(Mojo::URL->new($logout_url->query->param('redirect_uri'))->path, '/login',
    'asks homelab-sso to land back on this app\'s own /login afterward');

# Regardless of whether the browser goes on to follow that redirect,
# Drive's own session cookie is already gone — / must bounce again.
$t->get_ok('/')->status_is(302)->header_is(Location => '/login');

done_testing;
