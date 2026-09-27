use strict;
use warnings;
use Test::More;
use Mojo::IOLoop;
use Mojo::UserAgent;
use File::Temp qw(tempfile);
use YAML::XS qw(DumpFile);

use lib 'lib';
use Homelab::Common::Registry qw(register register_recurring lookup);

# Minimal fake logger for register_recurring()'s transition-only logging --
# just records call counts, doesn't need to format anything real.
package Test::FakeLog;
sub new  { return bless { warn => [], info => [] }, shift }
sub warn { my $self = shift; push @{ $self->{warn} }, "@_"; }
sub info { my $self = shift; push @{ $self->{info} }, "@_"; }
package main;

# Both registry routes now require a system_agent-role Bearer token (see
# the incident writeup on the commit that added this) -- register()/
# lookup() read it from a local credential file, same one homelab-agent
# itself maintains in production. A throwaway fixture file here, not the
# real /etc/homelab/agent/credential.yml path.
my (undef, $credential_file) = tempfile(SUFFIX => '.yml', UNLINK => 1);
DumpFile($credential_file, { token => 'fake-system-agent-token', refresh_token => 'irrelevant-here' });

# Homelab::Common::Registry makes blocking Mojo::UserAgent calls.
# Testing it against a same-process Mojo::Server::Daemon doesn't reliably
# pump the event loop for both sides of the same reactor at once, so the
# fake API here runs as a genuine separate subprocess instead — which
# also more accurately mirrors production (a real, separate homelab-api
# process on the other end of every registry call).
my ($fh, $server_script) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $fh <<'FAKE_API';
use Mojolicious;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
my %STORE;
my $app = Mojolicious->new;
$app->routes->post('/api/v1/registry/register' => sub {
    my $c = shift;
    return $c->render(json => { error => 'authentication required' }, status => 401)
        unless ($c->req->headers->authorization // '') eq 'Bearer fake-system-agent-token';
    my $body = $c->req->json;
    $STORE{$body->{feature_name}} = $body;
    $c->render(json => { ok => \1 });
});
$app->routes->get('/api/v1/registry/:feature' => sub {
    my $c = shift;
    return $c->render(json => { error => 'authentication required' }, status => 401)
        unless ($c->req->headers->authorization // '') eq 'Bearer fake-system-agent-token';
    my $feature = $c->param('feature');
    return $c->render(json => { error => 'not found' }, status => 404)
        unless $STORE{$feature};
    $c->render(json => $STORE{$feature});
});
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:18790']);
$daemon->start;
Mojo::IOLoop->start;
FAKE_API
close($fh);

my $pid = fork();
die "fork() failed: $!\n" unless defined $pid;
if ($pid == 0) {
    exec($^X, $server_script) or die "exec() failed: $!\n";
}

my $api_base = 'http://127.0.0.1:18790';
my $ready    = 0;
for (1 .. 30) {
    my $tx  = Mojo::UserAgent->new->get("$api_base/api/v1/registry/__readiness_probe__");
    my $err = $tx->error;
    if (!$err || $err->{code}) { $ready = 1; last }    # any real HTTP response means it's up
    select(undef, undef, undef, 0.1);
}
unless ($ready) {
    kill('TERM', $pid);
    BAIL_OUT('fake registry API subprocess never became reachable');
}

ok(
    register(
        api_base => $api_base, feature_name => 'homelab-sso',
        host => '10.10.0.50', port => 2502, health_check_url => '/health',
        credential_file => $credential_file,
    ),
    'register() succeeds against a live registry endpoint',
);

my $found = lookup('homelab-sso', api_base => $api_base, credential_file => $credential_file);
is($found->{host}, '10.10.0.50', 'lookup() returns the registered host');
is($found->{port}, 2502, 'lookup() returns the registered port');

eval { lookup('nonexistent-feature', api_base => $api_base, credential_file => $credential_file) };
like($@, qr/failed/, 'lookup() dies clearly for an unregistered feature');

# Caching: re-register with a different host and confirm lookup() still
# returns the CACHED value within the TTL window — proves the cache is
# actually being consulted, not just a formality.
register(
    api_base => $api_base, feature_name => 'homelab-sso',
    host => '10.10.0.99', port => 2502, health_check_url => '/health',
    credential_file => $credential_file,
);
my $cached = lookup('homelab-sso', api_base => $api_base, credential_file => $credential_file);
is($cached->{host}, '10.10.0.50', 'lookup() serves the cached value within the TTL window, not the just-changed one');

# Both routes now require a system_agent Bearer token -- prove register()
# actually fails closed (not silently succeeding unauthenticated) when
# the local homelab-agent credential file is missing, same failure mode
# a host with homelab-agent purged/not-yet-enrolled would hit for real.
eval {
    register(
        api_base => $api_base, feature_name => 'homelab-sso',
        host => '10.10.0.1', port => 1, health_check_url => '/health',
        credential_file => '/nonexistent/credential.yml',
    );
};
like($@, qr/no homelab-agent credential found/, 'register() dies clearly when no local agent credential exists');

# register_recurring(): absorbs a failing initial attempt without dying
# (unlike bare register()), logs exactly once for it, and self-heals on
# its next periodic attempt once the underlying problem is fixed -- this
# is the exact bug (mailbridge/audit silently unregistered for the
# better part of an hour after starting before their host's
# homelab-agent credential file existed) this sub exists to fix.
{
    my (undef, $healable_credential_file) = tempfile(SUFFIX => '.yml', UNLINK => 1);
    unlink $healable_credential_file;    # starts out MISSING, not just empty

    my $log = Test::FakeLog->new;
    my $ok = eval {
        register_recurring(
            api_base => $api_base, feature_name => 'homelab-recurring-test',
            host => '10.10.0.77', port => 9999, health_check_url => '/health',
            credential_file => $healable_credential_file, interval => 1, log => $log,
        );
        1;
    };
    ok($ok, 'register_recurring() does not die even when the initial register() attempt fails');
    is(scalar @{ $log->{warn} }, 1, 'exactly one warning logged for the initial failure');
    is(scalar @{ $log->{info} }, 0, 'no recovery message logged yet');

    eval { lookup('homelab-recurring-test', api_base => $api_base, credential_file => $credential_file) };
    like($@, qr/failed/, 'feature is genuinely not registered yet after the failed attempt');

    # Fix the credential -- no restart, just wait for the recurring
    # timer's next tick to pick it up.
    DumpFile($healable_credential_file, { token => 'fake-system-agent-token', refresh_token => 'irrelevant-here' });
    Mojo::IOLoop->timer(2.5 => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;

    my $found = lookup('homelab-recurring-test', api_base => $api_base, credential_file => $credential_file);
    is($found->{host}, '10.10.0.77', 'self-healed into the registry on the next periodic attempt, no restart needed');
    is(scalar @{ $log->{info} }, 1, 'exactly one recovery message logged');
    is(scalar @{ $log->{warn} }, 1, 'no additional warnings logged once recovered, even across multiple ticks');
}

kill('TERM', $pid);
waitpid($pid, 0);

done_testing;
