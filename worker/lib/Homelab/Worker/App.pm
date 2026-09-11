package Homelab::Worker::App;
use Mojo::Base 'Mojolicious', -signatures;

use File::Path qw(make_path);
use File::Spec;
use Mojo::IOLoop::Subprocess;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Worker::JobType::Zip;

has 'pg';
has 'api_base';
has 'storage_path';
has 'jobs_config';
has 'max_concurrent_jobs';
has 'job_types' => sub { {} };

sub startup ($self) {
    my $config = load_config('HOMELAB_WORKER_CONFIG', '/etc/homelab/worker/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2512'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/worker-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");

    my $storage_path = $config->{storage_path} // die "config: storage_path is required\n";
    make_path($storage_path) unless -d $storage_path;
    $self->storage_path($storage_path);

    my $jobs_cfg = $config->{jobs} // {};
    $self->jobs_config({
        retention_hours     => $jobs_cfg->{retention_hours}     // 24,
        job_timeout_minutes => $jobs_cfg->{job_timeout_minutes} // 30,
        max_attempts        => $jobs_cfg->{max_attempts}        // 3,
    });
    $self->max_concurrent_jobs(_resolve_concurrency($jobs_cfg->{max_concurrent_jobs} // 'auto'));

    # Job-type dispatch registry -- "add a new capability" means "add one
    # new Homelab::Worker::JobType::* module and one line here." Neither
    # the routes below nor the claim/run timer ever branches on job type
    # itself; run() is handed the opaque `input` JSONB and a private
    # workdir and either returns a finished artifact's local path or
    # dies. See README.md.
    $self->job_types({
        zip => \&Homelab::Worker::JobType::Zip::run,
    });

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-worker',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    # Bare lowercase controller name -- Mojolicious prepends this app's
    # own namespace (Homelab::Worker::App::Controller::*) itself, same
    # '#'-shorthand convention as every other homelab-* service.
    my $r = $self->routes;
    $r->post('/internal/v1/jobs')             ->to('jobs#create');
    $r->get('/internal/v1/jobs')               ->to('jobs#list');
    $r->get('/internal/v1/jobs/:id')           ->to('jobs#show');
    $r->get('/internal/v1/jobs/:id/download')  ->to('jobs#download');

    # Single timer, three responsibilities run in this fixed order every
    # tick: reclaim stale 'running' rows back to 'pending' (or 'failed'
    # once max_attempts is exhausted) BEFORE expiring terminal rows
    # BEFORE claiming the next pending row -- so a job reclaimed this
    # same tick is immediately eligible to be re-claimed rather than
    # waiting a full extra interval, and expiry never runs against a row
    # the claim query might still touch. Mojo::IOLoop::Subprocess (used
    # inside _claim_and_run_job) doesn't block this timer, so ticks keep
    # firing while earlier jobs are still running -- jobs accumulate
    # concurrently across ticks, up to max_concurrent_jobs, with no
    # separate "start N at once" code path needed. Same recurring-timer +
    # `FOR UPDATE SKIP LOCKED` pattern as homelab-domain-admin's
    # PowerDNS-restart/DKIM-retirement timers -- deliberately NOT Minion
    # (see README.md and CLAUDE.md for why).
    Mojo::IOLoop->recurring(5 => sub {
        $self->_reclaim_stale_jobs;
        $self->_expire_old_jobs;
        $self->_claim_and_run_job;
    });

    return;
}

# 'auto' resolves to floor(cpu_cores * 2 * 0.8) via a plain `nproc`
# shellout -- Sys::CPU isn't packaged for this Debian release (confirmed
# while building this package), and this value is only ever read once at
# startup, so a shellout costs nothing worth avoiding it for. This is a
# soft resource guideline, not a security boundary (see README.md's
# accepted-race note about a multi-worker hypnotoad's claim query), so no
# further precision is warranted.
sub _resolve_concurrency ($configured) {
    return $configured if $configured =~ /^\d+$/;
    die "config: jobs.max_concurrent_jobs must be a positive integer or 'auto' (got '$configured')\n"
        unless $configured eq 'auto';
    my $cores = `nproc` // '';
    chomp $cores;
    $cores = ($cores =~ /^\d+$/ && $cores > 0) ? $cores : 1;
    my $cap = int($cores * 2 * 0.8);
    return $cap > 0 ? $cap : 1;
}

# Resets an orphaned 'running' row (worker crash, package upgrade, host
# reboot mid-job -- job state lives entirely in Postgres, never in this
# process's own memory, so recovery is identical regardless of cause)
# back to 'pending' for another attempt, up to jobs_config.max_attempts,
# after which it's marked 'failed' with a clear message instead of
# retrying forever. expires_at is set in the same UPDATE when a row is
# given up on, so it's swept by _expire_old_jobs on a later tick same as
# any other terminal job -- it does not need its own cleanup path.
sub _reclaim_stale_jobs ($self) {
    my $cfg = $self->jobs_config;
    $self->pg->db->query(
        q{UPDATE worker.jobs
          SET state = CASE WHEN attempt_count + 1 >= ? THEN 'failed' ELSE 'pending' END,
              error_message = CASE WHEN attempt_count + 1 >= ?
                  THEN 'job timed out and exceeded max_attempts after being reclaimed' ELSE NULL END,
              completed_at = CASE WHEN attempt_count + 1 >= ? THEN NOW() ELSE NULL END,
              expires_at = CASE WHEN attempt_count + 1 >= ? THEN NOW() + make_interval(hours => ?) ELSE NULL END,
              attempt_count = attempt_count + 1,
              started_at = NULL
          WHERE state = 'running' AND started_at <= NOW() - make_interval(mins => ?)},
        $cfg->{max_attempts}, $cfg->{max_attempts}, $cfg->{max_attempts}, $cfg->{max_attempts},
        $cfg->{retention_hours}, $cfg->{job_timeout_minutes},
    );
    return;
}

# Deletes both the on-disk artifact (if any -- a failed job may never
# have produced one) and the row for every terminal job past its
# expires_at. expires_at is set by _claim_and_run_job's completion
# callback and by the reclaim-exhausted case above -- never by this
# method, which only ever reads it.
sub _expire_old_jobs ($self) {
    my $db   = $self->pg->db;
    my $rows = $db->query(
        q{SELECT id, output_uuid FROM worker.jobs WHERE expires_at IS NOT NULL AND expires_at <= NOW()},
    )->hashes;
    for my $row (@$rows) {
        my $path = File::Spec->catfile($self->storage_path, $row->{output_uuid});
        unlink $path if -e $path;
        $db->query('DELETE FROM worker.jobs WHERE id = ?', $row->{id});
    }
    return;
}

# The scheduling policy in one query: oldest job first, but never more
# than one running job per user (so a prolific user's backlog can never
# block a different, eligible user's job that arrived later), and never
# more than max_concurrent_jobs running at once. FOR UPDATE OF j (not a
# bare FOR UPDATE) is required here -- j is cross-joined against
# running_count, a CTE built from an aggregate (count(*)), and Postgres
# cannot apply a row lock to that synthetic aggregate row, only to real
# worker.jobs rows. SKIP LOCKED makes this safe under a multi-worker
# hypnotoad (server.workers above) the same way it already is for
# homelab-domain-admin's own timers.
sub _claim_and_run_job ($self) {
    my $db  = $self->pg->db;
    my $tx  = $db->begin;
    my $row = $db->query(
        q{WITH running_count AS (SELECT count(*) AS n FROM worker.jobs WHERE state = 'running')
          SELECT j.* FROM worker.jobs j, running_count rc
          WHERE j.state = 'pending'
            AND rc.n < ?
            AND NOT EXISTS (
                SELECT 1 FROM worker.jobs r WHERE r.user_email = j.user_email AND r.state = 'running'
            )
          ORDER BY j.created_at
          FOR UPDATE OF j SKIP LOCKED LIMIT 1},
        $self->max_concurrent_jobs,
    )->expand->hash;
    return unless $row;

    # Flipped to 'running' INSIDE the claiming transaction, before
    # commit -- not after -- so a job that runs for minutes can never be
    # re-claimed by the next tick while it's still legitimately in
    # flight.
    $db->query(q{UPDATE worker.jobs SET state = 'running', started_at = NOW() WHERE id = ?}, $row->{id});
    $tx->commit;

    my $job_id  = $row->{id};
    my $attempt = $row->{attempt_count};
    my $handler = $self->job_types->{ $row->{type} };
    my $cfg     = $self->jobs_config;

    unless ($handler) {
        # Every _guarded_ completion update below matches on
        # `attempt_count = ?` too (optimistic concurrency) -- a reclaim
        # sweep racing a still-alive child's late completion can't
        # corrupt state, since a reclaimed row's attempt_count has
        # already moved on by the time a stale write would land.
        $self->pg->db->query(
            q{UPDATE worker.jobs SET state = 'failed', error_message = ?, completed_at = NOW(),
              expires_at = NOW() + make_interval(hours => ?) WHERE id = ? AND attempt_count = ?},
            "unknown job type '$row->{type}'", $cfg->{retention_hours}, $job_id, $attempt,
        );
        return;
    }

    my $input        = $row->{input};
    my $output_uuid   = $row->{output_uuid};
    my $storage_path  = $self->storage_path;
    my $retention_hrs = $cfg->{retention_hours};

    Mojo::IOLoop::Subprocess->new->run(
        sub {
            require File::Temp;
            my $tmpdir = File::Temp->newdir("worker-job-$job_id-XXXXXX", TMPDIR => 1, CLEANUP => 1);
            my $built_path = eval { $handler->($input, $tmpdir->dirname) };
            return { ok => 0, error => "$@" } if $@;
            return { ok => 0, error => "job type produced no output file" }
                unless defined $built_path && -f $built_path;

            my $size = -s $built_path;
            my $dest = File::Spec->catfile($storage_path, $output_uuid);
            unless (rename($built_path, $dest)) {
                require File::Copy;
                unless (File::Copy::move($built_path, $dest)) {
                    return { ok => 0, error => "could not move output into storage: $!" };
                }
            }
            return { ok => 1, size => $size };
        },
        sub {
            my ($subprocess, $err, $result) = @_;
            my $db2 = $self->pg->db;
            if ($err || !$result || !$result->{ok}) {
                my $message = $err ? "subprocess error: $err" : ($result->{error} // 'unknown job failure');
                $db2->query(
                    q{UPDATE worker.jobs SET state = 'failed', error_message = ?, completed_at = NOW(),
                      expires_at = NOW() + make_interval(hours => ?) WHERE id = ? AND attempt_count = ?},
                    $message, $retention_hrs, $job_id, $attempt,
                );
                return;
            }
            $db2->query(
                q{UPDATE worker.jobs SET state = 'completed', output_size_bytes = ?, completed_at = NOW(),
                  expires_at = NOW() + make_interval(hours => ?) WHERE id = ? AND attempt_count = ?},
                $result->{size}, $retention_hrs, $job_id, $attempt,
            );
        },
    );
    return;
}

1;
