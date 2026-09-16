package Homelab::Agent::App;
use Mojo::Base 'Mojolicious', -signatures;

our $VERSION = '0.1.6';

use Fcntl qw(:flock O_CREAT O_RDWR);
use Mojo::Promise;
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::IOLoop::Client;
use Mojo::UserAgent;
use YAML::XS qw(LoadFile DumpFile);
use Homelab::Common::Config qw(load_config);
use Homelab::Common::AuthClient qw(introspect);

has 'api_base';
has 'hostname';
has 'advertise_host';
has 'manifest_dir';
has 'credential_file';
has 'credential';   # in-memory {token, refresh_token, expires_at}
has 'heartbeat_lock_fh';   # kept open for the process lifetime -- see _claim_heartbeat_duty
has ua => sub { Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10) };
# Mojo::IOLoop::Client weakens its own $self in every closure it
# schedules (reactor timer, next_tick, io watch) -- it relies on the
# CALLER holding the only strong reference for the connection's
# lifetime. A bare `my $client = Mojo::IOLoop::Client->new` local to a
# function that returns before the connection settles has nothing else
# refing it, so it's garbage-collected immediately and every scheduled
# callback later fires against an already-undef $self and silently
# no-ops -- found live via _check_tcp_port_p hanging every tcp_port
# check forever (no error, promise never settles) despite using the
# documented on(connect=>)/on(error=>) API correctly. Keying pending
# clients here by their own stringified ref keeps each one alive until
# its own callback fires and removes it.
has _pending_tcp_clients => sub { {} };

# One agent per host, reporting a declarative manifest
# (/etc/homelab/services/*.yml, one YAML doc per file -- either a single
# {name,package,kind,check,description} hash or an array of them, for a
# package that declares more than one thing, e.g. HAProxy's own
# per-frontend entries) checked against reality, replacing
# api.infrastructure_registry/`homelab-cli topology` (see
# ../../api/migrations/010-fleet-agent.sql). Deliberately no direct
# Postgres access at all -- every interaction with homelab-api is a
# plain HTTP call, same as every other feature reaching the service
# registry, and this app has nothing of its own worth persisting beyond
# what it reports.
sub startup ($self) {
    my $config = load_config('HOMELAB_AGENT_CONFIG', '/etc/homelab/agent/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    # workers: 2, not more -- see README.md's own note on why. Every
    # per-request check below is non-blocking (Mojo::IOLoop::Subprocess/
    # Mojo::IOLoop::Client, never a bare system()/backticks call that
    # would park this worker's whole event loop for the round trip), so
    # concurrent requests interleave within a worker instead of needing
    # a worker each -- the real fix for the concurrency question, not
    # a large preemptive worker count. Measured cost matters here more
    # than most: this app runs on EVERY host in the fleet, so any
    # per-worker memory footprint multiplies by the fleet size, not just
    # once.
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://0.0.0.0:2520'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/agent-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->hostname($config->{hostname} // die "config: hostname is required\n");
    $self->advertise_host($config->{advertise_host} // die "config: advertise_host is required\n");
    $self->manifest_dir($config->{manifest_dir} // '/etc/homelab/services');
    $self->credential_file($config->{credential_file} // '/etc/homelab/agent/credential.yml');

    # Postinst already ran homelab-agent-enroll before this service is
    # ever started (see debian/postinst) -- a missing credential file
    # here means that step failed or was skipped, not something this
    # app should try to paper over by starting in some half-working
    # mode. Fail loud at startup, matching how every other package in
    # this family refuses to start on a config it can't make sense of.
    die "credential file $self->{credential_file} not found -- run "
        . "'dpkg-reconfigure homelab-agent' after enrolling this host "
        . "(homelab-cli admin agent enroll <hostname>) first\n"
        unless -f $self->credential_file;
    $self->credential(LoadFile($self->credential_file));

    $self->routes->get('/health' => sub ($c) { $c->render(json => { status => 'ok' }) });
    # _handle_status takes ($self, $c) -- call it as a method, not a
    # bare coderef (a bare \&_handle_status only gets handed $c by the
    # router, leaving $self bound to the controller and $c undef).
    $self->routes->get('/status' => sub ($c) { $self->_handle_status($c) });

    # Under hypnotoad (workers: 2 above), the app is built ONCE in the
    # manager process -- startup() runs a single time, pre-fork -- and
    # each worker inherits that already-built state (routes, and any
    # Mojo::IOLoop timer already registered here) via fork(). A flock
    # acquired once in THIS sub, before the fork, gets inherited too: both
    # children share the same underlying open file description, so they
    # effectively both "hold" it -- flock can't tell them apart. A first
    # attempt at this fix (locking once here, gating whether the timer
    # even got registered) looked right on paper but measurably did NOT
    # work: both workers kept firing the inherited timer and racing to
    # refresh+persist the SAME credential_file's single-use rotating
    # refresh_token every interval, exactly as before the "fix" -- caught
    # live, fleet-wide, by checking actual journals after deploying it,
    # not assumed fixed from the code alone.
    #
    # Correct fix: don't gate REGISTRATION (which only ever happens once,
    # pre-fork, so gating it here can't distinguish the eventual workers
    # from each other). Gate EXECUTION instead, freshly, every time the
    # timer actually fires -- see _heartbeat_if_owner below. Each firing
    # opens its OWN new file descriptor (sysopen, not reused/inherited)
    # and holds the lock only for that one attempt's duration, releasing
    # it immediately after. Whichever process's copy of the (inherited,
    # identical) timer happens to fire first each cycle wins that cycle;
    # the loser's flock attempt fails fast (LOCK_NB) and it just skips
    # silently. This works regardless of whether hypnotoad's actual
    # worker model turns out to be "single pre-fork startup + inherited
    # IOLoop state" (what the evidence above points to) or "startup() re-
    # run independently per worker" (the original, now-disproven
    # assumption) -- either way, the mutual exclusion is decided at call
    # time, in whichever OS process is actually executing the callback,
    # never at registration time.
    my $interval = $config->{heartbeat_interval_seconds} // 60;
    Mojo::IOLoop->recurring($interval => sub { $self->_heartbeat_if_owner->catch(sub ($err) {
        $self->log->warn("heartbeat failed: $err");
    }) });
    # Also fire once shortly after startup, not just after the first
    # full interval -- a freshly (re)started agent shouldn't sit
    # invisible to the fleet view for up to $interval seconds.
    Mojo::IOLoop->timer(2 => sub { $self->_heartbeat_if_owner->catch(sub ($err) {
        $self->log->warn("initial heartbeat failed: $err");
    }) });

    return;
}

# Wraps _heartbeat_once so only one process-at-this-exact-moment ever
# actually runs it, no matter how many copies of the (inherited) timer
# exist fleet-side. A losing attempt isn't an error -- it means a sibling
# process's copy of this same timer is already mid-heartbeat, which is
# exactly the intended outcome, so it resolves quietly rather than
# rejecting into the caller's ->catch/log->warn.
sub _heartbeat_if_owner ($self) {
    return Mojo::Promise->resolve unless $self->_try_claim_heartbeat_duty;
    return $self->_heartbeat_once->finally(sub { $self->_release_heartbeat_duty });
}

# Returns true iff this call just acquired the lock. LOCK_EX | LOCK_NB
# never blocks: a call that loses the race gets a false return
# immediately instead of waiting on the winner. Always opens a FRESH
# file descriptor (never reuses one from a previous call, and never one
# inherited via fork from another process) -- see the long comment in
# startup() above for why that distinction is the actual fix.
sub _try_claim_heartbeat_duty ($self) {
    my $lock_file = '/var/lib/homelab/agent-heartbeat.lock';
    sysopen(my $fh, $lock_file, O_CREAT | O_RDWR, 0600)
        or die "can't open $lock_file: $!\n";
    return 0 unless flock($fh, LOCK_EX | LOCK_NB);
    $self->heartbeat_lock_fh($fh);   # held only until _release_heartbeat_duty, below
    return 1;
}

# Releases what _try_claim_heartbeat_duty acquired, immediately after
# one heartbeat attempt finishes (success or failure) -- so the NEXT
# interval's firing, whichever process's copy of the timer gets there
# first, starts from a clean, unheld lock rather than this same process
# holding it forever (which would work too, but only by accident: it
# would just mean whichever process's timer fired FIRST, ever, wins
# every future cycle -- fine in practice, but "released and re-claimed
# every cycle" is simpler to reason about and doesn't depend on that).
sub _release_heartbeat_duty ($self) {
    my $fh = $self->heartbeat_lock_fh or return;
    flock($fh, LOCK_UN);
    close($fh);
    $self->heartbeat_lock_fh(undef);
}

# GET /status -- authenticated the same way homelab-mailbridge/
# homelab-drive already authenticate every request: introspect the
# caller's JWT against homelab-api, never trust the network alone.
# Unlike the heartbeat this pushes, this re-checks everything live
# (no caching) -- the whole point of the pull path is up-to-the-second
# truth, not "as of the last heartbeat".
sub _handle_status ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    unless ($jwt) {
        return $c->render(json => { error => 'authentication required' }, status => 401);
    }
    my $result = introspect($jwt, api_base => $self->api_base);
    unless ($result && grep { $_ eq 'system_agent' } @{ $result->{roles} // [] }) {
        return $c->render(json => { error => 'system_agent role required' }, status => 403);
    }

    $c->render_later;
    $self->_check_services_p->then(sub ($services) {
        $c->render(json => {
            hostname => $self->hostname, address => $self->advertise_host, services => $services,
        });
    })->catch(sub ($err) {
        $c->render(json => { error => "status check failed: $err" }, status => 500);
    });
}

# Refreshes this agent's own access token (rotating the refresh_token
# too -- see api/lib/Homelab/API/App.pm's _refresh, the exact same
# sliding-window mechanism already proven for human logins, reused
# unchanged here) every cycle, persists the new refresh_token
# immediately, then pushes a heartbeat with a live services check.
# Every cycle, not just when the access token looks close to expiry --
# simpler than tracking expiry separately, and the cost (one extra
# HTTP round trip roughly once a minute) is a non-issue.
#
# Re-reads credential_file fresh every call rather than trusting
# $self->credential's in-memory value: under hypnotoad, this app's
# in-memory state gets forked into multiple processes that each keep
# their OWN independent copy from that point on (see startup()'s own
# comment on the heartbeat-ownership lock for the full story) -- if
# process A wins a cycle, refreshes, and writes the new token to disk,
# process B's in-memory copy is now stale even though only ONE of them
# runs _heartbeat_once at a time. Without this reload, whichever process
# happens to win the NEXT cycle's lock could still be B, attempting an
# already-consumed refresh_token and failing despite correctly holding
# the lock. Reading disk fresh here means it doesn't matter which
# process wins any given cycle -- it always uses the one currently-valid
# token, not whatever its own fork-inherited memory last saw.
sub _heartbeat_once ($self) {
    $self->credential(LoadFile($self->credential_file));
    return $self->ua->post_p("@{[$self->api_base]}/api/v1/auth/refresh",
        json => { refresh_token => $self->credential->{refresh_token} })
    ->then(sub ($tx) {
        my $body = $tx->result->json;
        die "refresh failed: " . ($body->{error} // 'unknown error') . "\n" if $tx->result->is_error;
        $self->credential({
            token => $body->{token}, refresh_token => $body->{refresh_token},
            expires_at => time + $body->{expires_in},
        });
        DumpFile($self->credential_file, $self->credential);
        chmod 0600, $self->credential_file;
        return $self->_check_services_p;
    })->then(sub ($services) {
        return $self->ua->post_p("@{[$self->api_base]}/api/v1/agent/heartbeat",
            { Authorization => "Bearer @{[$self->credential->{token}]}" },
            json => {
                hostname => $self->hostname, address => $self->advertise_host,
                agent_port => $self->_listen_port, agent_version => $Homelab::Agent::App::VERSION // '0.1.0',
                services => $services,
            });
    })->then(sub ($tx) {
        die "heartbeat rejected: " . ($tx->result->json->{error} // $tx->result->message) . "\n"
            if $tx->result->is_error;
        return 1;
    });
}

sub _listen_port ($self) {
    my ($port) = $self->config->{hypnotoad}{listen}[0] =~ /:(\d+)$/;
    return $port // 2520;
}

# Reads every *.yml in manifest_dir (each either one entry or an array
# of them -- see the class doc-comment above), checks each declared
# entry against reality, and resolves to the array of results heartbeat/
# status both send. Every check is non-blocking (Mojo::IOLoop::Subprocess
# for `systemctl is-active`, Mojo::IOLoop::Client for a raw TCP connect)
# so a slow or hung check on one service can't stall the others, or
# this worker's ability to serve a concurrent /status request meanwhile
# -- the actual fix for "does this need more workers", not more workers.
sub _check_services_p ($self) {
    my @declared;
    for my $file (glob "@{[$self->manifest_dir]}/*.yml") {
        my $doc = eval { LoadFile($file) };
        if ($@) {
            $self->log->warn("failed to parse manifest $file: $@");
            next;
        }
        push @declared, ref $doc eq 'ARRAY' ? @$doc : ($doc);
    }

    # Mojo::Promise->all() called with zero arguments doesn't behave
    # like an empty successful aggregate -- found live, the hard way,
    # on a host with no manifest files deployed to it yet (a real,
    # common case: this agent starts up before any package has written
    # its own manifest entry). Short-circuit instead of relying on
    # ->all()'s own zero-arg behavior.
    return Mojo::Promise->resolve([]) unless @declared;

    return Mojo::Promise->all(map { $self->_check_one_p($_) } @declared)
        ->then(sub (@results) { return [map { $_->[0] } @results] });
}

sub _check_one_p ($self, $entry) {
    my $check = $entry->{check} // {};
    my @checks;
    push @checks, $self->_check_systemd_unit_p($check->{systemd_unit}) if $check->{systemd_unit};
    push @checks, $self->_check_tcp_port_p($check->{tcp_port})         if $check->{tcp_port};

    my $build_result = sub ($actual) {
        return {
            name => $entry->{name}, package => $entry->{package}, kind => $entry->{kind},
            expected => \1, actual => ($actual ? \1 : \0), description => $entry->{description},
            # Descriptive only (what real backend(s) a proxy-type entry
            # routes to, e.g. HAProxy frontends/webproxy vhosts) -- this
            # agent never acts on it, just carries it through from the
            # manifest to homelab-api's own host_service_status row.
            fronts => $entry->{fronts},
        };
    };

    # No declared check at all -- an entry with just name/kind/description
    # and nothing to verify -- passes through as actual=true unchecked, a
    # real but accepted limitation rather than treating "nothing to check"
    # as a failure.
    return Mojo::Promise->resolve($build_result->(1)) unless @checks;

    # @checks is a list of promises each resolving to a single 0/1;
    # Mojo::Promise->all's own result shape is one arrayref of resolved
    # values PER promise, hence $_->[0] below.
    return Mojo::Promise->all(@checks)->then(sub (@outcomes) {
        return $build_result->(!grep { !$_->[0] } @outcomes);
    });
}

sub _check_systemd_unit_p ($self, $unit) {
    my $promise = Mojo::Promise->new;
    Mojo::IOLoop::Subprocess->new->run(
        sub { system("systemctl is-active --quiet " . quotemeta($unit)) == 0 },
        sub ($subprocess, $err, @results) { $promise->resolve($results[0] // 0) },
    );
    return $promise;
}

sub _check_tcp_port_p ($self, $port) {
    my $promise = Mojo::Promise->new;
    # Mojo::IOLoop::Client reports outcomes via connect/error events
    # (->on(...)), never a trailing callback to connect() itself --
    # passing one silently gets folded into the args hash instead (an
    # odd-length list, so it's a no-op key with the callback never
    # invoked), which left this promise resolving on a hung connection
    # forever. Found live via "Odd number of elements in anonymous hash
    # at Mojo/IOLoop/Client.pm" in journalctl once tcp_port checks were
    # actually declared in a manifest.
    my $client = Mojo::IOLoop::Client->new;
    # See _pending_tcp_clients' own comment -- $client must stay
    # strongly referenced somewhere until one of these fires, or it's
    # garbage-collected before the connection ever settles.
    my $key = "$client";
    $self->_pending_tcp_clients->{$key} = $client;
    # connect's event passes the raw handle (a bare IO::Socket), not a
    # Mojo::IOLoop::Stream -- close it directly, no stream wrapping.
    $client->on(connect => sub ($c, $handle) {
        $promise->resolve(1);
        $handle->close if $handle;
        delete $self->_pending_tcp_clients->{$key};
    });
    $client->on(error => sub ($c, $err) {
        $promise->resolve(0);
        delete $self->_pending_tcp_clients->{$key};
    });
    $client->connect(address => '127.0.0.1', port => $port, timeout => 3);
    return $promise;
}

1;
