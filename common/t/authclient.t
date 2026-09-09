use strict;
use warnings;
use Test::More;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

use lib 'lib';
use Homelab::Common::AuthClient qw(introspect login refresh revoke);

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
$app->routes->post('/api/v1/auth/login' => sub {
    my $c    = shift;
    my $body = $c->req->json // {};
    if (($body->{email} // '') eq 'user@test.mailmasker.org' && ($body->{password} // '') eq 'correct-password') {
        return $c->render(json => { token => 'valid-token', refresh_token => 'rt', expires_in => 900 });
    }
    return $c->render(json => { error => 'invalid email or password' }, status => 401);
});
$app->routes->post('/api/v1/auth/refresh' => sub {
    my $c    = shift;
    my $body = $c->req->json // {};
    if (($body->{refresh_token} // '') eq 'rt') {
        return $c->render(json => { token => 'refreshed-token', refresh_token => 'rt2', expires_in => 900 });
    }
    return $c->render(json => { error => 'invalid or expired refresh_token' }, status => 401);
});
$app->routes->post('/api/v1/auth/logout' => sub {
    my $c    = shift;
    my $body = $c->req->json // {};
    return $c->render(json => { success => \1 }) if ($body->{refresh_token} // '') eq 'rt';
    return $c->render(json => { error => 'unknown token' }, status => 400);
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

my $login_ok = login('user@test.mailmasker.org', 'correct-password', api_base => $api_base);
ok($login_ok->{success}, 'login() reports success for correct credentials');
is($login_ok->{token}, 'valid-token', 'login() returns the token');

my $login_bad = login('user@test.mailmasker.org', 'wrong-password', api_base => $api_base);
ok(!$login_bad->{success}, 'login() reports failure for wrong credentials, not dying');
is($login_bad->{_status}, 401, 'login() surfaces the real HTTP status');

my $login_unreachable = login('user@test.mailmasker.org', 'correct-password', api_base => 'http://127.0.0.1:1');
ok(!$login_unreachable->{success}, 'login() reports failure (not dies) on a transport failure');

my $refresh_ok = refresh('rt', api_base => $api_base);
ok($refresh_ok->{success}, 'refresh() reports success for a valid refresh_token');
is($refresh_ok->{token}, 'refreshed-token', 'refresh() returns the new token');

my $refresh_bad = refresh('not-a-real-refresh-token', api_base => $api_base);
ok(!$refresh_bad->{success}, 'refresh() reports failure for an invalid refresh_token, not dying');
is($refresh_bad->{_status}, 401, 'refresh() surfaces the real HTTP status');

ok(!refresh('rt', api_base => 'http://127.0.0.1:1')->{success}, 'refresh() reports failure (not dies) on a transport failure');

ok(revoke('rt', api_base => $api_base), 'revoke() returns true for a token the fake API accepts');
ok(!revoke('not-a-real-refresh-token', api_base => $api_base), 'revoke() returns false for a rejected token, not dying');
ok(!revoke('rt', api_base => 'http://127.0.0.1:1'), 'revoke() returns false (not dies) on a transport failure');

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
