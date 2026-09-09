use strict;
use warnings;
use Test::More;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

use lib 'lib';
use Homelab::Common::AuthClient qw(introspect);

# Same subprocess-fake-API pattern as t/registry.t — see that file for
# why (same-process Mojo::Server::Daemon + blocking UA doesn't reliably
# pump the reactor for both sides here).
my ($fh, $server_script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $fh <<'FAKE_API';
use Mojolicious;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
my $app = Mojolicious->new;
$app->routes->get('/api/v1/auth/introspect' => sub {
    my $c = shift;
    my ($token) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'Token required' }, status => 401) unless $token;
    return $c->render(json => { email => 'user@test.mailmasker.org', exp => time + 900 })
        if $token eq 'valid-token';
    return $c->render(json => { error => 'invalid or expired token' }, status => 401);
});
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:18791']);
$daemon->start;
Mojo::IOLoop->start;
FAKE_API
close($fh);

my $pid = fork();
die "fork() failed: $!\n" unless defined $pid;
if ($pid == 0) {
    exec($^X, $server_script) or die "exec() failed: $!\n";
}

my $api_base = 'http://127.0.0.1:18791';
my $ready    = 0;
for (1 .. 30) {
    my $tx  = Mojo::UserAgent->new->get("$api_base/api/v1/auth/introspect");
    my $err = $tx->error;
    if (!$err || $err->{code}) { $ready = 1; last }
    select(undef, undef, undef, 0.1);
}
unless ($ready) {
    kill('TERM', $pid);
    BAIL_OUT('fake introspect API subprocess never became reachable');
}

my $result = introspect('valid-token', api_base => $api_base);
ok($result, 'introspect() returns a true value for a valid token');
is($result->{email}, 'user@test.mailmasker.org', 'returns the right email');

ok(!introspect('bogus-token', api_base => $api_base), 'introspect() returns undef for an invalid token, not dying');
ok(!introspect(undef, api_base => $api_base), 'introspect() returns undef for no token at all, without making a request');
ok(!introspect('valid-token', api_base => 'http://127.0.0.1:1'), 'introspect() returns undef (not dies) on a transport failure — an unreachable homelab-api must not crash the caller');

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
