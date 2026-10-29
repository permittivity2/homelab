use v5.36;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../common/lib";

use File::Temp ();
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use YAML::XS qw(DumpFile LoadFile);

BEGIN {
    plan skip_all => 'homelab-common not available'
        unless eval { require Homelab::Common::Config; 1 };
}

# The change this guards: until 0.1.9 the agent rotated its credential on
# EVERY heartbeat -- 1440 times a day to renew a token with 23h59m left on it.
# Each rotation is a chance for the server to commit while the response is
# lost, leaving the host holding a revoked token and no way back, because the
# agent has no password. That lottery locked out 14 of 51 fleet nodes on
# 2026-10-28/29 (post-cutover items 36, 37).
#
# So: refresh only inside a margin of real expiry. The two things worth
# asserting are that it does NOT call out when there is no need, and that it
# still does when there is.

my $dir = File::Temp->newdir(TEMPLATE => 'agent-t-XXXXXX', TMPDIR => 1);
my $root = $dir->dirname;
my $cred = "$root/credential.yml";
my $cfg  = "$root/config.yml";
my $seen = path("$root/seen");
my $portf = path("$root/port");

# --- a fake homelab-api in a child process ---------------------------------
# A child, not an in-process daemon: Mojo::UserAgent drives its own event loop
# for the blocking calls under test, so a daemon on the singleton loop would
# never get a chance to answer.
my $pid = fork;
die "cannot fork: $!" unless defined $pid;
unless ($pid) {
    require Mojolicious;
    require Mojo::Server::Daemon;
    my $app = Mojolicious->new;
    $app->log->level('fatal');
    $app->routes->post('/api/v1/auth/refresh' => sub ($c) {
        if (open(my $fh, '>>', $seen->to_string)) { print {$fh} "refresh\n"; close $fh }
        return $c->render(json => {
            success => \1, token => 'fresh-access', refresh_token => 'fresh-refresh',
            expires_in => 86400, recovered => \1,
        });
    });
    $app->routes->post('/api/v1/agent/heartbeat' => sub ($c) { $c->render(json => { ok => \1 }) });
    my $d = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1'], silent => 1);
    $d->start;
    $portf->spew($d->ports->[0] . "\n");
    $d->run;
    exit 0;
}
END { kill 'TERM', $pid if $pid }

my $port;
for (1 .. 100) {
    if (-s $portf->to_string) { chomp($port = $portf->slurp); last }
    select undef, undef, undef, 0.05;
}
plan skip_all => 'the fake API did not start' unless $port;

# --- the app under test -----------------------------------------------------
sub build_app {
    my (%o) = @_;
    DumpFile($cred, {
        token => 'current-access', refresh_token => 'current-refresh',
        expires_at => $o{expires_at},
    });
    DumpFile($cfg, {
        homelab_api => { base_url => "http://127.0.0.1:$port" },
        hostname => 'prod-homelabTEST',
        advertise_host => '10.50.2.1',
        manifest_dir => "$root/manifests",
        credential_file => $cred,
        metrics_textfile_dir => "$root/textfile",
        (exists $o{margin} ? (refresh_margin_seconds => $o{margin}) : ()),
    });
    mkdir "$root/manifests";
    mkdir "$root/textfile";
    $seen->spew('');
    local $ENV{HOMELAB_AGENT_CONFIG} = $cfg;
    require Homelab::Agent::App;
    my $app = Homelab::Agent::App->new;
    return $app;
}

sub refreshes { return -s $seen->to_string ? scalar(() = $seen->slurp =~ /refresh/g) : 0 }

subtest 'a token nowhere near expiry is left alone' => sub {
    my $app = build_app(expires_at => time + 86_400);          # a full day left
    $app->credential(LoadFile($cred));
    $app->_refresh_if_needed_p->wait;
    is refreshes(), 0, 'no refresh call was made';
    is LoadFile($cred)->{refresh_token}, 'current-refresh', 'the credential on disk is untouched';
};

subtest 'a token inside the margin is refreshed' => sub {
    my $app = build_app(expires_at => time + 60);              # a minute left
    $app->credential(LoadFile($cred));
    $app->_refresh_if_needed_p->wait;
    is refreshes(), 1, 'refreshed once';
    my $after = LoadFile($cred);
    is $after->{refresh_token}, 'fresh-refresh', 'the new token was persisted';
    is $after->{token}, 'fresh-access', 'and the new access token with it';
    cmp_ok $after->{expires_at}, '>', time + 86_000, 'with its new expiry';
};

subtest 'the margin is configurable and respected' => sub {
    # 2 hours left, margin 4 hours -> inside the margin, so it must refresh.
    my $app = build_app(expires_at => time + 7_200, margin => 14_400);
    $app->credential(LoadFile($cred));
    $app->_refresh_if_needed_p->wait;
    is refreshes(), 1, 'a wider margin refreshes earlier';
};

subtest 'a credential with no usable expiry fails SAFE' => sub {
    # An older credential format, or a hand-edited file. Refreshing is the
    # pre-0.1.9 behaviour and the safe choice: the alternative is an agent
    # that never refreshes and silently expires.
    for my $bad (undef, '', 'not-a-number') {
        my $app = build_app(expires_at => $bad);
        $app->credential(LoadFile($cred));
        $app->_refresh_if_needed_p->wait;
        is refreshes(), 1, 'refreshes rather than assuming the token is good';
    }
};

subtest 'a wedged agent is visible in metrics' => sub {
    # The silence is what made the 2026-10-28 lockouts last up to 4.4 days:
    # the unit reports active and expires_at stays in the future. These are
    # the numbers homelab-prometheus' fleet-agent.yml alerts on.
    my $app = build_app(expires_at => time + 86_400);
    $app->credential(LoadFile($cred));
    $app->last_heartbeat_ok(1234567890);
    $app->refresh_failures(7);
    $app->_write_metrics;

    my $prom = path("$root/textfile/homelab_agent.prom");
    ok -s $prom->to_string, 'wrote a metrics file';
    my $m = $prom->slurp;
    like $m, qr/homelab_agent_heartbeat_last_success_timestamp_seconds\{host="prod-homelabTEST"\} 1234567890/,
        'exposes when the last heartbeat actually succeeded';
    like $m, qr/homelab_agent_heartbeat_failures\{host="prod-homelabTEST"\} 7/,
        'exposes consecutive failures';
    like $m, qr/homelab_agent_credential_expires_in_seconds\{host="prod-homelabTEST"\} \d+/,
        'exposes how much credential is left';
    like $m, qr/^# HELP /m, 'with HELP lines, so it is readable in Prometheus';
};

subtest 'metrics never cost a heartbeat' => sub {
    # Best-effort by design: no textfile directory must mean no metrics, not a
    # failed heartbeat. Every fleet host runs this agent.
    my $app = build_app(expires_at => time + 86_400);
    $app->config->{metrics_textfile_dir} = '/nonexistent/textfile/dir';
    my $ok = eval { $app->_write_metrics; 1 };
    ok $ok, 'an unwritable directory is silently skipped';
};

done_testing;
