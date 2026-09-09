use strict;
use warnings;
use Test::More;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

use lib 'lib';
use Homelab::Common::SSOClient qw(exchange_code);

# Same subprocess-fake-API pattern as t/authclient.t — see that file for
# why (same-process Mojo::Server::Daemon + blocking UA doesn't reliably
# pump the reactor for both sides here).
my ($fh, $server_script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $fh <<'FAKE_SSO';
use Mojolicious;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
my $app = Mojolicious->new;
$app->routes->post('/oauth/token' => sub {
    my $c = shift;
    my $v = $c->req->body_params;
    if (($v->param('grant_type') // '') eq 'authorization_code'
        && ($v->param('code') // '') eq 'good-code'
        && ($v->param('client_id') // '') eq 'drive'
        && ($v->param('client_secret') // '') eq 'correct-secret'
        && ($v->param('redirect_uri') // '') eq 'http://127.0.0.1:9999/oauth/callback')
    {
        return $c->render(json => {
            access_token => 'a-jwt', refresh_token => 'a-refresh', token_type => 'Bearer', expires_in => 900,
        });
    }
    return $c->render(json => { error => 'invalid_grant' }, status => 400);
});
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:18792']);
$daemon->start;
Mojo::IOLoop->start;
FAKE_SSO
close($fh);

my $pid = fork();
die "fork() failed: $!\n" unless defined $pid;
if ($pid == 0) {
    exec($^X, $server_script) or die "exec() failed: $!\n";
}

my $sso_base = 'http://127.0.0.1:18792';
my $ready    = 0;
for (1 .. 30) {
    my $tx  = Mojo::UserAgent->new->post("$sso_base/oauth/token");
    my $err = $tx->error;
    if (!$err || $err->{code}) { $ready = 1; last }
    select(undef, undef, undef, 0.1);
}
unless ($ready) {
    kill('TERM', $pid);
    BAIL_OUT('fake SSO API subprocess never became reachable');
}

my %good_opts = (
    sso_base => $sso_base, client_id => 'drive', client_secret => 'correct-secret',
    redirect_uri => 'http://127.0.0.1:9999/oauth/callback',
);

my $ok = exchange_code('good-code', %good_opts);
ok($ok->{success}, 'exchange_code() reports success for a valid code');
is($ok->{access_token}, 'a-jwt', 'returns the access_token');
is($ok->{refresh_token}, 'a-refresh', 'returns the refresh_token');

my $bad_code = exchange_code('wrong-code', %good_opts);
ok(!$bad_code->{success}, 'exchange_code() reports failure for an unknown code, not dying');
is($bad_code->{_status}, 400, 'exchange_code() surfaces the real HTTP status');

my $bad_secret = exchange_code('good-code', %good_opts, client_secret => 'wrong-secret');
ok(!$bad_secret->{success}, 'exchange_code() reports failure for a wrong client_secret');

my $unreachable = exchange_code('good-code', %good_opts, sso_base => 'http://127.0.0.1:1');
ok(!$unreachable->{success}, 'exchange_code() reports failure (not dies) on a transport failure');

eval { exchange_code('good-code', client_id => 'drive', client_secret => 's', redirect_uri => 'x') };
like($@, qr/sso_base required/, 'exchange_code() dies loudly on a missing required opt rather than silently misbehaving');

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
