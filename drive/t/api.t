use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

# Full end-to-end integration test — needs a real config.yml (real
# runtime DB credentials, migrations already applied) and a real,
# reachable homelab-api (homelab_api.base_url in that config). Same
# HOMELAB_*_CONFIG convention as every other homelab-* Mojolicious app's
# tests. Covers the Bearer-token-authenticated JSON API
# (/api/v1/files...) specifically -- see t/basic.t for the browser/
# session-cookie/SSO-flow path.
unless ($ENV{HOMELAB_DRIVE_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::Drive::App');

my $email    = 'e2e-drive-api-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'DriveApiTest1Aa!!';

# Register + log in directly against homelab-api, bypassing the SSO
# redirect dance entirely -- this is exactly what homelab-cli itself
# does (a CLI holds its own homelab-api JWT directly; there's no
# browser to redirect).
my $jwt;
{
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->post("$api_base/api/v1/auth/register", json => { email => $email, password => $password });
    die "test account registration failed: " . $tx->result->body unless $tx->result->code == 201;
    $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $email, password => $password });
    die "test account login failed: " . $tx->result->body unless $tx->result->code == 200;
    $jwt = $tx->result->json('/token');
}

# --- No token at all: 401, not a crash ---
$t->get_ok('/api/v1/files')->status_is(401);

# --- A bogus token: also 401 ---
$t->get_ok('/api/v1/files' => { Authorization => 'Bearer garbage' })->status_is(401);

# --- Empty listing for a brand-new account ---
$t->get_ok('/api/v1/files' => { Authorization => "Bearer $jwt" })
  ->status_is(200)->json_is([]);

# --- Upload with no file field: a clean 400, not a redirect (the
# browser form's own upload() silently redirects on this -- the API
# must not, there's no browser to land somewhere) ---
$t->post_ok('/api/v1/files' => { Authorization => "Bearer $jwt" })
  ->status_is(400);

# --- Real upload, byte-for-byte round trip ---
my $content = "api test file content " . time . "\n";
my ($fh, $path) = tempfile(SUFFIX => '.txt');
print $fh $content;
close($fh);

$t->post_ok('/api/v1/files' => { Authorization => "Bearer $jwt" }
    => form => { file => { file => $path, filename => 'api-roundtrip.txt' } })
  ->status_is(201)
  ->json_has('/id')
  ->json_is('/filename', 'api-roundtrip.txt');
my $file_id = $t->tx->res->json('/id');

$t->get_ok('/api/v1/files' => { Authorization => "Bearer $jwt" })
  ->status_is(200);
my $listed = $t->tx->res->json;
is(scalar @$listed, 1, 'exactly one file listed');
is($listed->[0]{id}, $file_id, 'the uploaded file is the one listed');
ok(!exists $listed->[0]{uuid}, 'the internal storage uuid is never exposed over the API');

$t->get_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $jwt" })
  ->status_is(200)
  ->content_is($content);
$t->header_like('Content-Disposition', qr/api-roundtrip\.txt/);

# --- Another user's token must not see or reach this file ---
{
    my $other_email    = 'e2e-drive-api-other-' . time . '-' . $$ . '@test.mailmasker.org';
    my $other_password = 'DriveApiOtherTest1Aa!!';
    my $api_base = $t->app->api_base;
    my $ua = Mojo::UserAgent->new;
    $ua->post("$api_base/api/v1/auth/register", json => { email => $other_email, password => $other_password });
    my $tx = $ua->post("$api_base/api/v1/auth/login", json => { email => $other_email, password => $other_password });
    my $other_jwt = $tx->result->json('/token');

    $t->get_ok('/api/v1/files' => { Authorization => "Bearer $other_jwt" })
      ->status_is(200)->json_is([]);
    $t->get_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $other_jwt" })
      ->status_is(404);
    $t->delete_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $other_jwt" })
      ->status_is(404);
}

# --- Delete: the file is genuinely gone afterward, not just delisted ---
$t->delete_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $jwt" })
  ->status_is(200)->json_is('/ok', 1);

$t->get_ok('/api/v1/files' => { Authorization => "Bearer $jwt" })
  ->status_is(200)->json_is([]);
$t->get_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $jwt" })
  ->status_is(404);

# --- Deleting an already-deleted (or never-existent) file is a clean
# 404, not a crash ---
$t->delete_ok("/api/v1/files/$file_id" => { Authorization => "Bearer $jwt" })
  ->status_is(404);

done_testing;
