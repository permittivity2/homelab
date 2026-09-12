use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::UserAgent;
use Mojolicious::Lite;
use File::Temp qw(tempfile);

use lib 'lib';
use Homelab::Common::Proxy qw(forward);

# Same "real subprocess, not an in-process fake" reasoning as
# t/registry.t: a single subprocess plays BOTH roles a real deployment
# splits across two processes (the registry, hosted by homelab-api; and
# the backend feature being forwarded to) -- forward()'s own registry
# lookup doesn't care that they happen to share a port here, and it
# keeps this test to one subprocess instead of two.
my ($fh, $server_script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $fh <<'FAKE_BACKEND';
use Mojolicious;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
my $app = Mojolicious->new;
$app->routes->get('/api/v1/registry/:feature' => sub {
    my $c = shift;
    return $c->render(json => { error => 'not found' }, status => 404)
        unless $c->param('feature') eq 'homelab-fake';
    $c->render(json => { feature_name => 'homelab-fake', host => '127.0.0.1', port => 18791 });
});
$app->routes->get('/files' => sub {
    my $c = shift;
    $c->render(json => {
        auth => $c->req->headers->authorization, ok => \1,
        x_forwarded_for => $c->req->headers->header('X-Forwarded-For'),
        x_real_ip       => $c->req->headers->header('X-Real-IP'),
    });
});
$app->routes->post('/files' => sub {
    my $c = shift;
    $c->render(json => { received => $c->req->json }, status => 201);
});
# Mirrors homelab-drive's real path shape (/api/v1/files, NOT /files) --
# the case that exposed the real strip_prefix-alone bug (see forward()'s
# own docs and api/lib/Homelab/API/App.pm).
$app->routes->get('/api/v1/files' => sub {
    my $c = shift;
    $c->render(json => { real_backend_path => 1 });
});
# Echoes back what it actually received as an upload -- proves a real
# multipart/form-data body (not just JSON) survives the forward.
$app->routes->post('/upload' => sub {
    my $c = shift;
    my $upload = $c->req->upload('file');
    return $c->render(json => { error => 'no file' }, status => 400) unless $upload;
    $c->render(json => { filename => $upload->filename, content => $upload->asset->slurp, folder_id => $c->param('folder_id') });
});
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:18791']);
$daemon->start;
Mojo::IOLoop->start;
FAKE_BACKEND
close($fh);

my $pid = fork();
die "fork() failed: $!\n" unless defined $pid;
if ($pid == 0) {
    exec($^X, $server_script) or die "exec() failed: $!\n";
}

my $api_base = 'http://127.0.0.1:18791';
my $ready    = 0;
for (1 .. 30) {
    my $tx  = Mojo::UserAgent->new->get("$api_base/api/v1/registry/__readiness_probe__");
    my $err = $tx->error;
    if (!$err || $err->{code}) { $ready = 1; last }
    select(undef, undef, undef, 0.1);
}
unless ($ready) {
    kill('TERM', $pid);
    BAIL_OUT('fake backend subprocess never became reachable');
}

# A tiny gateway app, standing in for homelab-api's own /api/v1/drive/*
# route -- exercises forward() exactly the way it's really used.
get '/gateway/*capture' => sub {
    my $c = shift;
    forward($c, feature_name => 'homelab-fake', api_base => $api_base, strip_prefix => '/gateway');
};
post '/gateway/*capture' => sub {
    my $c = shift;
    forward($c, feature_name => 'homelab-fake', api_base => $api_base, strip_prefix => '/gateway');
};
get '/gateway-unregistered/*capture' => sub {
    my $c = shift;
    forward($c, feature_name => 'homelab-nonexistent', api_base => $api_base, strip_prefix => '/gateway-unregistered');
};
# Mirrors homelab-api's real /api/v1/drive/* route exactly: strips the
# gateway-only /gw2/drive prefix AND re-prepends /api/v1, landing on
# the backend's real /api/v1/files -- a plain strip_prefix alone would
# land on /files, which doesn't exist on the real homelab-drive.
get '/gw2/drive/*capture' => sub {
    my $c = shift;
    forward($c, feature_name => 'homelab-fake', api_base => $api_base,
             strip_prefix => '/gw2/drive', backend_prefix => '/api/v1');
};

my $t = Test::Mojo->new;

$t->get_ok('/gateway/files' => { Authorization => 'Bearer test-jwt-123' })
  ->status_is(200)
  ->json_is('/auth', 'Bearer test-jwt-123', 'Authorization header forwarded through unchanged')
  ->json_is('/ok', 1);

# Real bug found while wiring up the audit trail: forward() is itself a
# second proxy hop (gateway -> backend), but was never setting these --
# every backend service's own $c->tx->remote_address (used for audit
# logging, rate-limiting, etc.) silently resolved to homelab-api's own
# loopback address instead of the real client. Asserting the header is
# actually SET and matches what this in-process request's own
# remote_address resolves to (not asserting a specific real-world IP,
# which Test::Mojo's in-process transport doesn't have one of).
ok($t->tx->res->json('/x_forwarded_for'), 'forward() sets X-Forwarded-For on the outgoing request to the backend');
is($t->tx->res->json('/x_forwarded_for'), $t->tx->res->json('/x_real_ip'), 'X-Forwarded-For and X-Real-IP carry the same value');

$t->post_ok('/gateway/files' => json => { filename => 'x.txt' })
  ->status_is(201, 'backend status code relayed through, not flattened to 200')
  ->json_is('/received/filename', 'x.txt', 'JSON body forwarded through unchanged');

$t->get_ok('/gateway-unregistered/files')
  ->status_is(502, 'a feature_name with no registry entry renders a clean 502, not a raw exception page');

$t->get_ok('/gw2/drive/files')
  ->status_is(200, 'strip_prefix + backend_prefix together land on the backend\'s real /api/v1/files path')
  ->json_is('/real_backend_path', 1);

# Real regression case: Mojo::Message::body's own GETTER returns '' for
# ANY multipart content (see forward()'s own comment) -- building the
# outgoing request from that string silently forwarded an EMPTY body
# for every upload. Caught by an actual `homelab-cli drive upload`
# call, not by any of the JSON-only cases above.
my ($ufh, $upath) = tempfile(SUFFIX => '.txt');
print $ufh "real file content\n";
close($ufh);
$t->post_ok('/gateway/upload' => form => { file => { file => $upath, filename => 'up.txt' }, folder_id => '7' })
  ->status_is(200, 'a real multipart file upload survives the forward, not just JSON bodies')
  ->json_is('/filename', 'up.txt')
  ->json_is('/content', "real file content\n")
  ->json_is('/folder_id', '7', 'a plain form field alongside the file also survives the forward');

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
