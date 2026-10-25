use strict;
use warnings;
use Test::More;
use Mojo::UserAgent;
use File::Temp qw(tempfile);

use lib 'lib';
use Homelab::Common::AuthClient qw(introspect login refresh revoke issue);

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
    if ($token eq 'valid-token') {
        my $response = { email => 'user@test.mailmasker.org', exp => time + 900 };
        # Mirrors homelab-api 0.1.12's real ?capability= extension --
        # this fake only ever says yes for 'audit.view', to prove
        # AuthClient::introspect() actually appends the param (not that
        # any particular capability logic is right, that's homelab-api's
        # own test's job).
        if (defined(my $capability = $c->param('capability'))) {
            $response->{has_capability} = ($capability eq 'audit.view') ? \1 : \0;
        }
        return $c->render(json => $response);
    }
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
# system_agent-gated in reality; the fake only accepts the agent bearer
# 'agent-token' and mints a DIFFERENT token/refresh pair than login's,
# so the test can prove issue() returns an independent credential.
$app->routes->post('/api/v1/auth/issue' => sub {
    my $c    = shift;
    my ($token) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'system_agent role required' }, status => 403)
        unless ($token // '') eq 'agent-token';
    my $body = $c->req->json // {};
    return $c->render(json => { error => 'email is required' }, status => 400)
        unless length($body->{email} // '');
    return $c->render(json => {
        success => \1, token => 'rp-token', refresh_token => 'rp-rt', expires_in => 86400,
        email => $body->{email},
    });
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

my $with_cap = introspect('valid-token', api_base => $api_base, capability => 'audit.view');
ok($with_cap->{has_capability}, 'optional capability opt is appended as a real query param homelab-api can see');
my $without_cap = introspect('valid-token', api_base => $api_base, capability => 'some.other.thing');
ok(!$without_cap->{has_capability}, 'a different capability name correctly comes back false, not just always-true');
my $no_cap_param = introspect('valid-token', api_base => $api_base);
ok(!exists $no_cap_param->{has_capability}, 'omitting capability entirely means no has_capability key at all -- unchanged for every existing caller');

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

my $issue_ok = issue('user@test.mailmasker.org', api_base => $api_base, agent_token => 'agent-token', client_id => 'roundcube');
ok($issue_ok->{success}, 'issue() reports success with a valid system_agent token');
is($issue_ok->{token}, 'rp-token', 'issue() returns a freshly-minted token');
isnt($issue_ok->{token}, $login_ok->{token}, 'the issued RP token is INDEPENDENT of the login/IdP token -- the whole point of the per-RP mint');

my $issue_unauth = issue('user@test.mailmasker.org', api_base => $api_base, agent_token => 'not-the-agent');
ok(!$issue_unauth->{success}, 'issue() reports failure (not dies) when the caller is not a system_agent');
is($issue_unauth->{_status}, 403, 'issue() surfaces the real 403 so the caller can fall back to the shared IdP token');

ok(!issue('user@test.mailmasker.org', api_base => 'http://127.0.0.1:1', agent_token => 'agent-token')->{success},
    'issue() reports failure (not dies) on a transport failure');

eval { issue('user@test.mailmasker.org', api_base => $api_base) };
like($@, qr/agent_token required/, 'issue() dies if no agent_token is supplied -- it is never an unauthenticated call');

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
