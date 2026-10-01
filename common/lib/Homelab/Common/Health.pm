package Homelab::Common::Health;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Time::HiRes ();
use Mojo::IOLoop;

our @EXPORT_OK = qw(mount_health_route mount_metrics_route);

# Mounts a standard GET /health route on a Mojolicious app — the
# one-line-but-copy-pasted-everywhere endpoint every feature used to
# hand-write separately. $check is an optional coderef for a deeper
# check (e.g. "can I reach the database"); returns plain-text 'ok'/200
# or 'unhealthy'/503, matching the existing convention every package
# already used informally. Also sets up per-app HTTP metrics (see
# mount_metrics_route) so every health-instrumented app is also
# metrics-instrumented, with no per-app code change.
sub mount_health_route {
    my ($app, %opts) = @_;
    my $check = $opts{check} // sub { 1 };

    $app->routes->get('/health' => sub {
        my $c  = shift;
        my $ok = eval { $check->() };
        return $c->render(text => 'ok') if $ok;
        return $c->render(text => 'unhealthy', status => 503);
    });

    mount_metrics_route($app, %opts);
}

# Per-app HTTP metrics for a Mojolicious app, exported via node_exporter's
# textfile collector rather than an in-app /metrics route. Each worker
# writes a mojo_<service>.<pid>.prom file into the textfile directory every
# few seconds; node_exporter (already scraped on :9100, already firewalled)
# aggregates all workers' files, so multi-worker counters stay correct
# (each worker is a distinct series via the worker label) with no shared
# memory, no new port, no new scrape job, and no new firewall opening.
#
# No-op (safe) where the textfile directory isn't present/writable -- e.g.
# a host without homelab-node-exporter's textfile collector enabled.
sub mount_metrics_route {
    my ($app, %opts) = @_;

    # Clean service label from the app class (Homelab::API::App -> "api",
    # Homelab::Accountmanage::App -> "accountmanage") rather than Mojo's
    # decamelized moniker (which mangles "API" -> "a_p_i"). Override with
    # service => '...' if needed.
    my $service = $opts{service};
    unless (defined $service) {
        my $class = ref($app) || "$app";
        $service = $class =~ /^Homelab::([^:]+)::/ ? lc($1) : ($app->moniker // 'app');
    }
    $service =~ s/[^A-Za-z0-9_]/_/g;
    my $dir = $opts{textfile_dir}
        // $ENV{HOMELAB_NODE_EXPORTER_TEXTFILE_DIR}
        // '/var/lib/prometheus/node-exporter';
    return unless -d $dir && -w $dir;

    my $pid     = $$;
    my $file    = "$dir/mojo_$service.$pid.prom";
    my $started = time;
    my (%req, %dur_sum, %dur_cnt);
    my $inflight = 0;

    $app->hook(before_dispatch => sub ($c) {
        $inflight++;
        $c->stash(_hl_m_t0 => [Time::HiRes::gettimeofday]);
    });
    $app->hook(after_dispatch => sub ($c) {
        $inflight-- if $inflight > 0;
        my $t0 = $c->stash('_hl_m_t0') or return;
        my $path = $c->req->url->path->to_string // '';
        return if $path eq '/health';    # don't drown real traffic in health pings
        my $dur = Time::HiRes::tv_interval($t0);
        my $m   = $c->req->method // 'UNKNOWN';
        my $s   = $c->res->code // 0;
        $req{"$m|$s"}++;
        $dur_sum{$m} += $dur;
        $dur_cnt{$m}++;
    });

    my $lbl = qq{service="$service",worker="$pid"};
    my $dump = sub {
        my @l = (
            '# HELP homelab_app_up 1 while an app worker is running.',
            '# TYPE homelab_app_up gauge',
            qq{homelab_app_up{$lbl} 1},
            '# TYPE homelab_app_uptime_seconds gauge',
            qq{homelab_app_uptime_seconds{$lbl} } . (time - $started),
            '# HELP homelab_http_requests_total HTTP requests handled, by method+status.',
            '# TYPE homelab_http_requests_total counter',
        );
        for my $k (sort keys %req) {
            my ($m, $s) = split /\|/, $k, 2;
            push @l, qq{homelab_http_requests_total{$lbl,method="$m",status="$s"} $req{$k}};
        }
        push @l,
            '# HELP homelab_http_request_duration_seconds Request handling time (sum+count -> avg via rate).',
            '# TYPE homelab_http_request_duration_seconds_sum counter';
        push @l, qq{homelab_http_request_duration_seconds_sum{$lbl,method="$_"} }
            . sprintf('%.6f', $dur_sum{$_}) for sort keys %dur_sum;
        push @l, '# TYPE homelab_http_request_duration_seconds_count counter';
        push @l, qq{homelab_http_request_duration_seconds_count{$lbl,method="$_"} $dur_cnt{$_}}
            for sort keys %dur_cnt;
        push @l,
            '# TYPE homelab_http_requests_in_flight gauge',
            qq{homelab_http_requests_in_flight{$lbl} $inflight};

        # Atomic write (textfile collector must never read a partial file).
        my $tmp = "$file.tmp";
        if (open my $fh, '>', $tmp) {
            print $fh join("\n", @l), "\n";
            close $fh;
            rename $tmp, $file;
        }

        # Reap dead workers' stale files (hypnotoad restarts -> new PIDs).
        if (opendir my $dh, $dir) {
            my $now = time;
            while (defined(my $f = readdir $dh)) {
                # Reap this service's dead-worker files (mtime > 90s) -- a
                # live worker rewrites its own within 15s, so a stale one is
                # a dead (hypnotoad-recycled) worker.
                next unless $f =~ /^mojo_\Q$service\E\.\d+\.prom$/;
                my $p = "$dir/$f";
                next if $p eq $file;
                my @st = stat $p;
                unlink $p if @st && ($now - $st[9]) > 90;
            }
            closedir $dh;
        }
    };

    $dump->();
    Mojo::IOLoop->recurring(15 => $dump);
}

1;
