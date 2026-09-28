package Homelab::Drive::App;
use Mojo::Base 'Mojolicious', -signatures;

use File::Path qw(make_path);
use File::Basename qw(basename);
use File::LibMagic;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json);
use Mojo::UserAgent;

# For sniffing a worker-delivered artifact's real MIME when the
# placement row didn't pin one (concat outputs -- see
# _claim_and_deliver_placement). Cheap to construct; the controller
# package keeps its own instance for the upload path.
my $PLACEMENT_MAGIC = File::LibMagic->new;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring lookup);
use Homelab::Common::AuthClient qw(introspect);

has 'pg';
has 'api_base';
has 'storage_path';
has 'sso_base';
has 'sso_internal_base';
has 'sso_client_id';
has 'sso_client_secret';
has 'sso_redirect_uri';
has 'image_config';
has 'public_base_url';
has 'trash_retention_days';
has 'account_manage_url';

sub startup ($self) {
    # Installed via EXE_FILES to /usr/bin/homelab-drive, with no
    # adjacent templates/ dir there — templates/ actually lands at
    # /usr/share/homelab-drive/templates. Same HOMELAB_*_HOME env-var
    # pattern the old sso-ui package used for the same reason.
    my $home = $ENV{HOMELAB_DRIVE_HOME} // '/usr/share/homelab-drive';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_DRIVE_CONFIG', '/etc/homelab/drive/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2501'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/drive-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
        # A multi-GB upload streams to disk over one long-lived request;
        # hypnotoad's default 15s inactivity timeout would drop it on any
        # brief network stall. Generous defaults (config-overridable) so
        # large uploads survive slow/variable links. heartbeat_timeout is
        # raised in step so the manager doesn't reap a worker mid-transfer.
        inactivity_timeout => $srv->{inactivity_timeout} // 1200,
        heartbeat_timeout  => $srv->{heartbeat_timeout}  // 120,
    });

    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);
    # Distinct name, not Mojolicious's generic default ('mojolicious',
    # shared by every homelab-* app that doesn't set this) -- same
    # convention homelab-sso already uses for its own session cookie.
    # Also load-bearing the moment this app is ever load-balanced across
    # more than one instance: this session holds real OAuth login state
    # (oauth_state, token, refresh_token -- see the /sso/callback
    # handler below), stored server-side per-instance same as
    # Roundcube's own PHP session was, which broke Roundcube's login
    # under a naive round-robin pool (confirmed live 2026-09-25, fixed
    # via homelab-webproxy's own per-site sticky_cookie support -- see
    # that package's README). Naming this cookie now, while drive is
    # still single-instance, means a future pool needs only one new line
    # in sites.yml (sticky_cookie: homelab-drive) with no app change.
    $self->sessions->cookie_name('homelab-drive');

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->storage_path($config->{storage}{path} // '/var/lib/homelab/drive-storage');
    make_path($self->storage_path);
    # In-progress chunked uploads accumulate here, one .partial per
    # session, on the storage filesystem (real disk, NOT tmpfs) so a big
    # upload spills to disk instead of OOMing and finalizing is a
    # same-fs rename. postinst creates this too; belt-and-suspenders so a
    # hand-set storage.path still works on first boot. See
    # migrations/006-upload-sessions.sql.
    make_path($self->storage_path . '/.partials');
    $self->image_config($config->{image} // {});
    # Soft-deleted (trashed) items are auto-purged after this many days
    # (see _purge_expired_trash). 0 disables auto-purge (manual Empty
    # Trash only).
    $self->trash_retention_days($config->{trash}{retention_days} // 30);
    $self->public_base_url($config->{public_base_url} // die "config: public_base_url is required\n");
    # Where the top-right profile button's "Account Management" link points
    # (homelab-accountmanage). Configurable; sensible fleet default.
    $self->account_manage_url($config->{account_manage_url} // 'https://myaccount.test.mailmasker.org');

    my $sso = $config->{sso} // die "config: sso.* is required (see config/drive.example.yml)\n";
    $self->sso_base($sso->{base_url} // die "config: sso.base_url is required\n");
    # sso.base_url is a BROWSER redirect target (login/logout) and must
    # be public; internal_base_url is for THIS app's own server-to-server
    # exchange_code() call and should point at an internal address once
    # this app and homelab-sso are on separate hosts. Defaults to
    # sso_base itself (correct for the single-host case). Split out
    # 2026-09-26 after the exact same bug already found and fixed for
    # homelab-roundcube's oauth_token_uri/oauth_identity_uri hit this
    # app too: sso.base_url here had been set to homelab-sso's internal
    # address (fine for exchange_code(), wrong for the browser redirect)
    # -- fixing THAT regressed exchange_code() in the other direction
    # the moment sso.base_url was corrected to the public URL, since
    # nothing else was using an internal address for the server-to-
    # server call. See roundcube/config/config.inc.php.template's own
    # comment on this exact split for the fuller story.
    $self->sso_internal_base($sso->{internal_base_url} // $sso->{base_url});
    $self->sso_client_id($sso->{client_id} // die "config: sso.client_id is required\n");
    $self->sso_client_secret($sso->{client_secret} // die "config: sso.client_secret is required\n");
    $self->sso_redirect_uri($sso->{redirect_uri} // die "config: sso.redirect_uri is required\n");

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); return 1 });

    # Announce ourselves in the registry so other features (and
    # eventually homelab-webproxy) can find us without a hardcoded
    # address — see Homelab::Common::Registry.
    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-drive',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'File storage web app + JSON API, serves /api/v1/drive/*',
            log => $self->log,
        );
    }

    # Delivers a completed homelab-worker zip job into this user's own
    # Archives folder -- see create_zip_job/_deliver_zip_placement below
    # and migrations/003-zip-placements.sql. Same recurring-timer +
    # FOR UPDATE SKIP LOCKED claim pattern as homelab-domain-admin's and
    # homelab-worker's own timers; this is drive's first one.
    Mojo::IOLoop->recurring(5 => sub { $self->_claim_and_deliver_zip_placement });
    # Drive-local file-concatenation jobs (see create_append_job +
    # migrations/005-append-jobs.sql). Same claim/deliver cadence; the
    # actual byte-copy runs in a forked subprocess so it never blocks a
    # hypnotoad worker.
    Mojo::IOLoop->recurring(5 => sub { $self->_run_append_jobs });
    # Reap abandoned chunked-upload sessions (client vanished mid-upload)
    # so orphaned .partial files don't accumulate on disk forever. Much
    # slower cadence than the job timers above -- this is housekeeping,
    # not latency-sensitive. See _sweep_stale_uploads +
    # migrations/006-upload-sessions.sql.
    Mojo::IOLoop->recurring(600 => sub { $self->_sweep_stale_uploads });
    # Auto-purge trashed items past the retention window (soft delete ->
    # real delete). Hourly is plenty for a day-scale retention. See
    # _purge_expired_trash + migrations/009-soft-delete-trash.sql.
    Mojo::IOLoop->recurring(3600 => sub { $self->_purge_expired_trash });

    my $r = $self->routes;
    $r->get('/')               ->to('drive#index');
    $r->get('/folders/:id')    ->to('drive#index');
    $r->get('/login')          ->to('drive#login_form');
    $r->get('/oauth/callback') ->to('drive#oauth_callback');
    $r->post('/logout')        ->to('drive#logout');
    $r->post('/upload')        ->to('drive#upload');
    $r->post('/folders')            ->to('drive#create_folder');
    $r->post('/folders/:id/delete') ->to('drive#delete_folder');
    $r->get('/files/:id/download')->to('drive#download');
    $r->post('/files/:id/delete') ->to('drive#delete_file');
    $r->get('/files/:id/thumbnail')      ->to('drive#thumbnail');
    $r->get('/files/:id/slideshow-image')->to('drive#slideshow_image');

    # --- Bulk select: delete (synchronous, see _delete_file/_delete_folder
    # below -- both are already fast enough for a loop, no job needed) and
    # zip-and-download (async, via homelab-worker -- see
    # README.md's "Bulk delete + zip download" section and
    # ../../CLAUDE.md/the approved plan for why zip-building does NOT run
    # in-process here). Dual-mounted under /api/v1/... too, same
    # Bearer-or-cookie handling as every other route in this file
    # (_current_auth checks the Authorization header first). ---
    # soft_delete route default splits browser (soft -> Trash) from api
    # (hard -> immediate), same split as the single-file delete_file vs
    # api_delete handlers. See bulk_delete + the Trash routes below.
    $r->post('/bulk/delete')        ->to('drive#bulk_delete', soft_delete => 1);
    $r->post('/api/v1/bulk/delete') ->to('drive#bulk_delete', soft_delete => 0);

    # --- Trash (soft delete). Browser delete is soft (recoverable);
    # these expose the Trash view + restore/purge/empty. Restore/purge/
    # empty are JSON (the browser Trash view calls them via fetch, same
    # as bulk delete) and dual-mounted for homelab-cli. See migration 009
    # + the trash/_restore_*/_purge_* handlers. ---
    $r->get('/trash')                    ->to('drive#trash');            # browser HTML view
    $r->get('/api/v1/trash')             ->to('drive#api_trash_list');   # JSON, for the CLI
    $r->post('/files/:id/restore')       ->to('drive#restore_file');
    $r->post('/api/v1/files/:id/restore')->to('drive#restore_file');
    $r->post('/folders/:id/restore')       ->to('drive#restore_folder');
    $r->post('/api/v1/folders/:id/restore')->to('drive#restore_folder');
    $r->post('/files/:id/purge')         ->to('drive#purge_file');
    $r->post('/api/v1/files/:id/purge')  ->to('drive#purge_file');
    $r->post('/folders/:id/purge')        ->to('drive#purge_folder');
    $r->post('/api/v1/folders/:id/purge') ->to('drive#purge_folder');
    $r->post('/trash/empty')             ->to('drive#empty_trash');
    $r->post('/api/v1/trash/empty')      ->to('drive#empty_trash');

    # Only job *creation* is a route -- there's no browser-facing status/
    # download route any more (see create_zip_job below and README.md's
    # "Bulk select: zip download" section): the finished archive is
    # delivered into this user's own Archives folder by a background
    # timer, not fetched via a per-job polling/download proxy. A site
    # admin or scripted caller who wants to inspect one specific
    # homelab-worker job directly already has `homelab-cli jobs
    # show/download <job_id>`, which works for every job type, not just
    # drive's zip jobs -- no need to duplicate that here.
    $r->post('/zip-jobs')             ->to('drive#create_zip_job');
    $r->post('/api/v1/zip-jobs')      ->to('drive#create_zip_job');
    # Zip status: combined worker-build + drive-deliver phase, entry
    # progress, and the finished file id -- so the browser can poll
    # instead of "check back in Archives", and a failed build/delivery is
    # actually surfaced. :id is the homelab-worker job id create_zip_job
    # returned. See get_zip_job.
    $r->get('/zip-jobs/:id')          ->to('drive#get_zip_job');
    $r->get('/api/v1/zip-jobs/:id')   ->to('drive#get_zip_job');

    # Reassemble/append: concatenate several files (in the given order)
    # into one new file. Runs DRIVE-LOCAL (not on homelab-worker -- see
    # create_append_job + _run_append_jobs + migrations/005): a forked
    # subprocess cats the already-local source blobs. Browser form posts
    # /append-jobs; homelab-cli posts /api/v1/append-jobs.
    $r->post('/append-jobs')          ->to('drive#create_append_job');
    $r->post('/api/v1/append-jobs')   ->to('drive#create_append_job');
    # Concat status: state + live byte progress + finished file id, so
    # both the browser and homelab-cli can show progress and surface a
    # failure instead of a file that silently never appears. See
    # get_append_job.
    $r->get('/append-jobs/:id')        ->to('drive#get_append_job');
    $r->get('/api/v1/append-jobs/:id') ->to('drive#get_append_job');

    # Chunked / resumable uploads (see migrations/006-upload-sessions.sql
    # for the protocol). Dual-mounted under /api/v1/... for homelab-cli
    # exactly like every other route here; the browser UI uses the
    # bare-path variants. :id is the session UUID (no dots, so the
    # default :placeholder match is correct). The finished file lands in
    # drive.files just like a whole-file upload -- this is only a
    # different way to get the bytes there.
    $r->post('/uploads')              ->to('drive#create_upload_session');
    $r->post('/api/v1/uploads')       ->to('drive#create_upload_session');
    $r->get('/uploads/:id')           ->to('drive#get_upload_session');
    $r->get('/api/v1/uploads/:id')    ->to('drive#get_upload_session');
    $r->patch('/uploads/:id')         ->to('drive#patch_upload_chunk');
    $r->patch('/api/v1/uploads/:id')  ->to('drive#patch_upload_chunk');
    $r->delete('/uploads/:id')        ->to('drive#delete_upload_session');
    $r->delete('/api/v1/uploads/:id') ->to('drive#delete_upload_session');

    # --- JSON API (Bearer-token authenticated, e.g. homelab-cli or any
    # third-party script -- see README.md and ../../CLAUDE.md). Not
    # session-cookie-based like the browser routes above: a CLI holds
    # its own homelab-api JWT directly, no SSO redirect dance needed. ---
    $r->get('/api/v1/files')        ->to('drive#api_list');
    $r->post('/api/v1/files')       ->to('drive#api_upload');
    $r->get('/api/v1/files/:id')    ->to('drive#download');
    $r->delete('/api/v1/files/:id') ->to('drive#api_delete');
    $r->get('/api/v1/folders')          ->to('drive#api_list_folders');
    $r->post('/api/v1/folders')         ->to('drive#api_create_folder');
    $r->delete('/api/v1/folders/:id')   ->to('drive#api_delete_folder');

    # This user's live storage usage (bytes). Reached by
    # homelab-accountmanage via the api gateway (/api/v1/drive/usage) for
    # its storage panel. Counts live files only (trashed-but-not-purged
    # blobs still occupy disk but aren't the user's "usage").
    $r->get('/api/v1/usage')            ->to('drive#api_usage');

    return;
}

# Looks up homelab-worker's own address via the service registry --
# undef if it's not currently registered/reachable. App-package-local
# copy of the same-named helper in the Controller package below (that
# one takes a controller `$c` for `$c->app->api_base`; this one already
# IS the app, called from the recurring timer below with no request/
# controller context to borrow one from) -- see the note on this file's
# own per-`package` import/unqualified-call scoping further down for
# why these aren't just shared as one sub.
sub _worker_entry ($self) {
    my $entry = eval { lookup('homelab-worker', api_base => $self->api_base) };
    return ($entry && $entry->{host} && $entry->{port}) ? $entry : undef;
}

# Gives up on a placement's delivery after too many failed attempts
# (worker unreachable, or the stored JWT having outlived its own
# ~30min lifetime before the zip job finished building -- see
# migrations/003-zip-placements.sql), rather than retrying forever.
# Flips back to 'pending' (not 'failed') below the cap so the claim
# query in _claim_and_deliver_zip_placement picks it up again next
# tick -- 'processing' must never be a resting state.
sub _bump_or_fail_zip_placement ($self, $row, $message) {
    my $attempts = $row->{delivery_attempts} + 1;
    if ($attempts >= 5) {
        $self->pg->db->query(
            q{UPDATE drive.zip_placements
              SET state = 'failed', delivery_attempts = ?, error_message = ?, completed_at = NOW()
              WHERE id = ?},
            $attempts,
            "$message (gave up after $attempts attempts -- see \`homelab-cli jobs show $row->{job_id}\`)",
            $row->{id},
        );
    } else {
        $self->pg->db->query(
            q{UPDATE drive.zip_placements SET state = 'pending', delivery_attempts = ? WHERE id = ?},
            $attempts, $row->{id},
        );
    }
    return;
}

# Claims one pending drive.zip_placements row (single atomic UPDATE ...
# WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1), safe under
# hypnotoad's multiple prefork workers each running this same timer --
# see migrations/003-zip-placements.sql's note on the 'processing'
# state) and checks the underlying homelab-worker job:
#  - job completed: downloads the artifact and inserts it as a normal
#    drive.files row inside the placement's dest_folder_id (mirrors
#    _save_upload's INSERT shape in the Controller package below, just
#    fed from an HTTP response body instead of a Mojo::Upload), marks
#    the placement completed.
#  - job failed: marks the placement failed immediately, copying the
#    job's own error_message -- no point retrying a job that already
#    gave up building.
#  - job still pending/running: flips back to 'pending' for another
#    tick, no attempt cost -- homelab-worker's own job_timeout_minutes/
#    max_attempts already bound how long a job can stay non-terminal.
#  - the delivery step itself errors (worker unreachable, stale JWT,
#    etc.): _bump_or_fail_zip_placement above.
sub _claim_and_deliver_zip_placement ($self) {
    my $row = $self->pg->db->query(
        q{UPDATE drive.zip_placements SET state = 'processing'
          WHERE id = (
              SELECT id FROM drive.zip_placements
              WHERE state = 'pending' ORDER BY created_at
              FOR UPDATE SKIP LOCKED LIMIT 1
          )
          RETURNING *},
    )->hash;
    return unless $row;

    my $entry = $self->_worker_entry;
    unless ($entry) {
        $self->_bump_or_fail_zip_placement($row, 'homelab-worker is not currently available');
        return;
    }

    # request_timeout is generous and max_response_size unlimited (0):
    # this UA both polls the job status (fast) AND downloads the finished
    # artifact, which for a big zip/concat is multi-GB -- Mojo's default
    # 2GB response cap would reject a 4GB artifact outright, and the old
    # 60s timeout would abort the transfer.
    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 1800, max_response_size => 0);
    my $status_tx = $ua->get(
        "http://$entry->{host}:$entry->{port}/internal/v1/jobs/$row->{job_id}"
            => { Authorization => "Bearer $row->{jwt}" },
    );
    unless ($status_tx->res->code && $status_tx->res->code == 200) {
        $self->_bump_or_fail_zip_placement($row, 'could not check the homelab-worker job status');
        return;
    }
    my $job = $status_tx->res->json;

    if ($job->{state} eq 'failed') {
        $self->pg->db->query(
            q{UPDATE drive.zip_placements SET state = 'failed', error_message = ?, completed_at = NOW() WHERE id = ?},
            'zip build failed: ' . ($job->{error_message} // 'unknown error'), $row->{id},
        );
        return;
    }
    unless ($job->{state} eq 'completed') {
        $self->pg->db->query(q{UPDATE drive.zip_placements SET state = 'pending' WHERE id = ?}, $row->{id});
        return;
    }

    my $dl_tx = $ua->get(
        "http://$entry->{host}:$entry->{port}/internal/v1/jobs/$row->{job_id}/download"
            => { Authorization => "Bearer $row->{jwt}" },
    );
    unless ($dl_tx->res->code && $dl_tx->res->code == 200) {
        $self->_bump_or_fail_zip_placement($row, 'could not download the finished zip from homelab-worker');
        return;
    }

    # Size straight from the on-disk asset -- NEVER length($dl_tx->res->body),
    # which slurps the whole (potentially multi-GB) artifact into a Perl
    # string just to measure it. move_to below already streams the asset
    # from its spool file, so the bytes never need to be in memory here.
    my $asset      = $dl_tx->res->content->asset;
    my $size_bytes = $asset->size;

    # Move the artifact into storage FIRST, then (only when the placement
    # didn't pin a type -- i.e. concat) sniff the real MIME off the moved
    # file, exactly like the upload path does. Zip rows carry
    # 'application/zip'; concat rows carry NULL -> sniff -> octet-stream
    # fallback.
    my $file_row = $self->pg->db->query(
        q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type, folder_id)
          VALUES (?, ?, ?, ?, ?) RETURNING uuid, id},
        $row->{user_email}, $row->{output_name}, $size_bytes,
        ($row->{mime_type} // 'application/octet-stream'), $row->{dest_folder_id},
    )->hash;
    my $dest = $self->storage_path . '/' . $file_row->{uuid};
    $asset->move_to($dest);

    unless (defined $row->{mime_type}) {
        my $sniffed = eval { $PLACEMENT_MAGIC->checktype_filename($dest) };
        $self->pg->db->query('UPDATE drive.files SET mime_type = ? WHERE id = ?', $sniffed, $file_row->{id})
            if $sniffed;
    }

    $self->pg->db->query(
        q{UPDATE drive.zip_placements SET state = 'completed', result_file_id = ?, completed_at = NOW() WHERE id = ?},
        $file_row->{id}, $row->{id},
    );
    return;
}

# Drive-LOCAL file concatenation (see create_append_job + migrations/
# 005-append-jobs.sql). The source blobs already live here under
# storage_path, so there's no fetch and no worker hop -- just cat them
# in order into a new blob. The byte-copy runs in a FORKED subprocess
# (Mojo::IOLoop::Subprocess) so a multi-GB combine never blocks a
# hypnotoad worker's event loop; the child does only file I/O and never
# touches $self->pg (same discipline as homelab-worker's own child), the
# parent does all the DB writes on completion.
# The per-run temp path a concat streams its output into. Includes the
# ATTEMPT epoch, not just the job id: a reclaim that re-pends a stalled
# (but still-alive) run and a fresh run of the same job must NOT share a
# path, or the two subprocesses would clobber each other's bytes and the
# late one would rename the other's in-progress inode into storage. The
# heartbeat/reclaim build the same path from the row's (id, attempt), so
# they always stat/unlink the RIGHT run's temp.
sub _append_tmp_path ($storage_path, $id, $attempt) { return "$storage_path/.uploads-tmp/append-job-$id-$attempt"; }

# How many concat subprocesses may run at once across the whole fleet
# (checked via the 'processing'/'finalizing' count below, so it holds
# across every hypnotoad worker). Without this a backlog would fork a new
# multi-GB byte-copy every 5s tick per worker, unbounded, and exhaust the
# 512MB box's memory/IO. Small: concat is disk-bound, parallelism buys
# little and costs contention.
my $MAX_CONCURRENT_APPEND = 3;

sub _run_append_jobs ($self) {
    my $db = $self->pg->db;
    my $storage_path = $self->storage_path;

    # (1) HEARTBEAT: mirror each in-flight concat's growing output size
    # into received_bytes, and -- crucially -- bump started_at whenever it
    # grew. started_at thus tracks "last observed progress", so the
    # reclaim below can tell a genuinely-stuck job from a merely-long one.
    my $processing = $db->query(
        q{SELECT id, attempt, received_bytes FROM drive.append_jobs WHERE state = 'processing'})->hashes;
    for my $p (@$processing) {
        my $tmp  = _append_tmp_path($storage_path, $p->{id}, $p->{attempt});
        my $size = -e $tmp ? (stat $tmp)[7] : undef;
        next unless defined $size && $size != ($p->{received_bytes} // 0);
        $db->query(q{UPDATE drive.append_jobs SET received_bytes = ?, started_at = NOW() WHERE id = ?},
                   $size, $p->{id});
    }

    # (2) RECLAIM: re-pend a concat that has made NO progress for 15
    # minutes (subprocess died on a restart, or truly wedged). Because
    # the heartbeat bumps started_at on every byte of progress, a
    # legitimately long multi-GB concat is never reclaimed mid-flight.
    # Also catches a row stuck 'finalizing' (a crash in the brief
    # INSERT+rename window). Drop the reclaimed attempt's temp; the
    # re-run gets a fresh attempt (hence a fresh path), and its
    # completion is attempt-guarded, so even if a stalled original later
    # wakes up it can neither clobber the re-run's file nor overwrite the
    # job's state.
    my $stale = $db->query(
        q{UPDATE drive.append_jobs SET state = 'pending', received_bytes = 0
          WHERE state IN ('processing', 'finalizing') AND started_at < NOW() - INTERVAL '15 minutes'
          RETURNING id, attempt})->hashes;
    for my $s (@$stale) {
        my $tmp = _append_tmp_path($storage_path, $s->{id}, $s->{attempt});
        unlink($tmp) if -e $tmp;
    }

    # (3) CLAIM + RUN one pending job -- unless we're already at the
    # fleet-wide concurrency cap.
    my $inflight = $db->query(
        q{SELECT count(*) AS n FROM drive.append_jobs WHERE state IN ('processing', 'finalizing')})->hash->{n};
    return if $inflight >= $MAX_CONCURRENT_APPEND;

    # `attempt = attempt + 1` bumps the epoch this run owns; the parent
    # callback guards every write on (id, attempt) so a stale run can't
    # touch a re-claimed job.
    my $job = $db->query(
        q{UPDATE drive.append_jobs SET state = 'processing', started_at = NOW(), received_bytes = 0,
                 attempt = attempt + 1
          WHERE id = (SELECT id FROM drive.append_jobs WHERE state = 'pending'
                      ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
          RETURNING *},
    )->hash;
    return unless $job;
    my $attempt = $job->{attempt};

    # Mojo::Pg does NOT auto-decode a JSONB column on a plain
    # SELECT/RETURNING -- it comes back as the raw JSON *string* -- so
    # decode it by hand. This bit us for real: the claim query returned
    # source_uuids as a string, the old `ref eq 'ARRAY'` guard then
    # treated it as empty, and the concat produced a 0-byte file. (Same
    # Mojo::Pg JSONB-not-auto-inflated gotcha seen in the block-link work.)
    my $uuids = $job->{source_uuids};
    $uuids = decode_json($uuids) if defined $uuids && !ref $uuids;
    $uuids = [] unless ref $uuids eq 'ARRAY';
    my @src_paths = map { "$storage_path/$_" } @$uuids;

    # Fail LOUD on an empty source list rather than delivering a 0-byte
    # file: create_append_job already refuses <2 files, so an empty list
    # here can only mean the row was mangled (e.g. a JSONB decode
    # regression) -- surface it as a failed job, never a silent empty
    # result.
    if (!@src_paths) {
        $self->log->error("append job $job->{id} has no source blobs -- refusing to deliver an empty file");
        $db->query(
            q{UPDATE drive.append_jobs SET state = 'failed', error_message = 'no source files resolved', completed_at = NOW() WHERE id = ? AND attempt = ?},
            $job->{id}, $attempt);
        return;
    }

    # Record total_bytes (denominator for the progress bar) = sum of the
    # source blob sizes. A missing source here fails the job cleanly
    # rather than mid-stream.
    my $total = 0;
    for my $src (@src_paths) {
        my $sz = -e $src ? (stat $src)[7] : undef;
        unless (defined $sz) {
            $self->log->error("append job $job->{id}: source blob missing: $src");
            $db->query(
                q{UPDATE drive.append_jobs SET state = 'failed', error_message = 'a source file is missing', completed_at = NOW() WHERE id = ? AND attempt = ?},
                $job->{id}, $attempt);
            return;
        }
        $total += $sz;
    }
    $db->query(q{UPDATE drive.append_jobs SET total_bytes = ? WHERE id = ? AND attempt = ?}, $total, $job->{id}, $attempt);

    my $tmp = _append_tmp_path($storage_path, $job->{id}, $attempt);

    Mojo::IOLoop->subprocess(
        sub {
            # CHILD: concatenate the source blobs, in order, into the
            # deterministic temp file -- streaming in 1MB chunks, so a 4GB
            # combine never holds a whole file in RAM. Truncate-open so a
            # re-pended job starts clean. Dies (into $err) on any problem;
            # on failure the parent unlinks the temp.
            open(my $fh, '>', $tmp) or die "could not open output: $!\n";
            binmode $fh;
            for my $src (@src_paths) {
                open(my $in, '<', $src) or die "source blob missing: $src\n";
                binmode $in;
                my $buf;
                while (1) {
                    my $n = sysread($in, $buf, 1048576);
                    # undef == read error: MUST die, not fall out of the
                    # loop, or a mid-read I/O error would silently truncate
                    # the concat instead of failing it.
                    die "read failed on a source blob: $!\n" unless defined $n;
                    last if $n == 0;   # clean EOF
                    # syswrite may write fewer bytes than asked; loop on
                    # the offset so a short write can't drop bytes.
                    my $off = 0;
                    while ($off < $n) {
                        my $w = syswrite($fh, $buf, $n - $off, $off);
                        die "write failed: $!\n" unless defined $w;
                        $off += $w;
                    }
                }
                close($in);
            }
            close($fh) or die "could not finalize output: $!\n";
            return { size => -s $tmp };
        },
        sub {
            my ($subproc, $err, $res) = @_;
            my $pdb = $self->pg->db;
            if ($err) {
                $self->log->warn("append job $job->{id} (attempt $attempt) failed: $err");
                unlink($tmp) if -e $tmp;
                $pdb->query(
                    q{UPDATE drive.append_jobs SET state = 'failed', error_message = ?, completed_at = NOW()
                      WHERE id = ? AND attempt = ? AND state = 'processing'},
                    $err, $job->{id}, $attempt);
                return;
            }

            # Claim the right to finalize THIS attempt BEFORE any side
            # effect. If the guarded flip matches no row, this run was
            # reclaimed and re-run under a newer attempt (or aborted) --
            # our bytes are stale, so create nothing and just drop our own
            # temp. This is what stops a woken-up stalled original from
            # inserting a junk drive.files row or clobbering result_file_id.
            my $claim = $pdb->query(
                q{UPDATE drive.append_jobs SET state = 'finalizing'
                  WHERE id = ? AND attempt = ? AND state = 'processing' RETURNING id},
                $job->{id}, $attempt)->hash;
            unless ($claim) {
                unlink($tmp) if -e $tmp;
                return;
            }

            # We own it: create the drive.files row, move the blob into
            # storage. A move failure must NOT leave a 'completed' job
            # pointing at a missing blob -- fail cleanly + drop the orphan
            # row instead.
            my $file = $pdb->query(
                q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type, folder_id)
                  VALUES (?, ?, ?, ?, ?) RETURNING id, uuid},
                $job->{user_email}, $job->{output_name}, $res->{size},
                'application/octet-stream', $job->{dest_folder_id})->hash;
            my $dest = "$storage_path/$file->{uuid}";
            my $moved = rename($tmp, $dest);
            unless ($moved) {
                require File::Copy;
                $moved = File::Copy::move($tmp, $dest);
            }
            unless ($moved) {
                my $e = "$!";
                $self->log->error("append job $job->{id}: could not store combined file: $e");
                $pdb->query('DELETE FROM drive.files WHERE id = ?', $file->{id});
                unlink($tmp) if -e $tmp;
                $pdb->query(
                    q{UPDATE drive.append_jobs SET state = 'failed', error_message = 'could not store the combined file', completed_at = NOW() WHERE id = ? AND attempt = ?},
                    $job->{id}, $attempt);
                return;
            }
            my $sniffed = eval { $PLACEMENT_MAGIC->checktype_filename($dest) };
            $pdb->query('UPDATE drive.files SET mime_type = ? WHERE id = ?', $sniffed, $file->{id})
                if $sniffed;
            $pdb->query(
                q{UPDATE drive.append_jobs SET state = 'completed', result_file_id = ?, received_bytes = ?, completed_at = NOW()
                  WHERE id = ? AND attempt = ?},
                $file->{id}, $res->{size}, $job->{id}, $attempt);
        },
    );
    return;
}

# Housekeeping for the chunked-upload protocol (migrations/006): drop
# sessions that have been 'open' but idle past the retention window --
# a client that started an upload and vanished. Both the DB row and its
# orphaned .partial blob go. Deliberately conservative (24h) so a client
# that's genuinely just slow/paused between chunks is never reaped out
# from under a legitimately resumable upload. Completed/aborted sessions
# aren't touched here (they hold no partial; aborted ones already
# unlinked theirs) -- they're tiny rows kept as a short audit trail.
sub _sweep_stale_uploads ($self) {
    my $storage_path = $self->storage_path;
    my $rows = $self->pg->db->query(
        q{DELETE FROM drive.upload_sessions
          WHERE state = 'open' AND updated_at < NOW() - INTERVAL '24 hours'
          RETURNING id},
    )->hashes;
    for my $r (@$rows) {
        my $partial = "$storage_path/.partials/$r->{id}";
        unlink($partial) if -e $partial;
    }
    $self->log->info("swept " . scalar(@$rows) . " stale upload session(s)") if @$rows;

    # Directory reconciliation backstop: unlink any .partials file with NO
    # owning session row that's older than an hour. With O_CREAT dropped
    # in patch_upload_chunk the known orphan-recreation races can't happen
    # anymore, but this catches anything a crash mid-finalize or a future
    # bug could still strand -- the "there is no directory-scan
    # reconciliation" gap called out in review. The >1h age guard means a
    # freshly-created session's partial (whose row we might read a moment
    # before it commits) is never mistaken for an orphan.
    my $dir = "$storage_path/.partials";
    opendir(my $dh, $dir) or return;
    my $orphans = 0;
    while (defined(my $name = readdir $dh)) {
        next unless $name =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
        my $path = "$dir/$name";
        next unless -f $path;
        my $age = time - (stat _)[9];
        next if $age < 3600;
        my $exists = $self->pg->db->query(
            'SELECT 1 FROM drive.upload_sessions WHERE id = ?', $name)->rows;
        next if $exists;
        $orphans++ if unlink($path);
    }
    closedir($dh);
    $self->log->info("swept $orphans orphaned upload partial(s)") if $orphans;
    return;
}

# Unlinks a file's blob + its image derivatives from storage. Plain sub
# (no controller $c) so the retention sweep in the App package can use
# it; the Controller's own _unlink_derivatives mirrors this for the
# request-path deletes.
sub _purge_blob ($storage_path, $uuid) {
    unlink("$storage_path/$uuid") if -f "$storage_path/$uuid";
    for my $sub (qw(thumbnails slideshow)) {
        my $p = "$storage_path/.$sub/$uuid.jpg";
        unlink($p) if -f $p;
    }
    return;
}

# Auto-purge (soft delete -> real delete) every trashed item older than
# trash_retention_days. Files first (unlink each blob + derivatives, then
# drop the row), then the now-safe folder rows. A file trashed as part of
# a folder shares/precedes the folder's deleted_at, so it's already
# handled by the files pass before its folder row is deleted here --
# no CASCADE ever orphans a blob. retention_days <= 0 disables auto-purge
# (Empty Trash / permanent-delete still work by hand).
sub _purge_expired_trash ($self) {
    my $days = $self->trash_retention_days;
    return unless $days && $days > 0;
    my $db = $self->pg->db;
    my $storage_path = $self->storage_path;

    my $files = $db->query(
        q{SELECT id, uuid FROM drive.files
          WHERE deleted_at IS NOT NULL AND deleted_at < NOW() - make_interval(days => ?)},
        $days)->hashes;
    for my $f (@$files) {
        _purge_blob($storage_path, $f->{uuid});
        $db->query('DELETE FROM drive.files WHERE id = ?', $f->{id});
    }

    my $folders = $db->query(
        q{DELETE FROM drive.folders
          WHERE deleted_at IS NOT NULL AND deleted_at < NOW() - make_interval(days => ?)
          RETURNING id}, $days)->hashes;

    my $n = scalar(@$files) + scalar(@$folders);
    $self->log->info("purged $n expired trash item(s)") if $n;
    return;
}

package Homelab::Drive::App::Controller::Drive;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# `use`/imports in the Homelab::Drive::App package block above do NOT
# carry over here — each `package` statement in a file starts a fresh
# namespace for unqualified sub calls, so anything called unqualified
# from this controller needs its own import. Missing this caused a real
# "Undefined subroutine" 500 at runtime (login() and basename() are
# both called below) — only caught by the actual integration test
# exercising the login path, not by anything that runs without a live
# homelab-api to log in against.
use Fcntl qw(:flock :seek O_RDWR O_CREAT);
use File::Basename qw(basename);
use File::LibMagic;
use File::Path qw(make_path);
use Image::Magick;
use Mojo::URL;
use Mojo::UserAgent;
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient qw(exchange_code);
use Homelab::Common::Registry qw(lookup);
use Homelab::Common::AuditClient qw(enqueue);

# Separate from any UA Homelab::Common::* modules keep internally --
# used only for the two homelab-worker hand-offs below (submitting/
# polling/downloading a zip job). request_timeout is generous: job
# creation itself is fast (worker just inserts a row), but this UA is
# also reused for a browser-initiated ->download_zip() pass-through,
# which streams a potentially large finished archive back through this
# process.
my $WORKER_UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 1800, max_response_size => 0);

# Short-timeout UA for the browser-polled zip-STATUS query only (a quick
# job-status GET). Kept separate from $WORKER_UA's long request_timeout
# so a hung/slow worker can freeze this drive process's event loop for at
# most a few seconds per poll, not up to 1800s. (A fully non-blocking
# render_later + get_p would remove even that; this is the cheap, big
# improvement.)
my $WORKER_STATUS_UA = Mojo::UserAgent->new(connect_timeout => 3, request_timeout => 5);

my $MAGIC = File::LibMagic->new;

# Chunked-upload tunables (see migrations/006-upload-sessions.sql).
# $UPLOAD_CHUNK_SIZE is only a SUGGESTION returned to the client -- the
# server accepts whatever chunk sizes the client actually sends, so long
# as each starts at the current offset. $MAX_UPLOAD_BYTES caps the
# declared total_size so a client can't reserve an absurd upload; it's
# far above the 4GB "out of the gate" target but bounds abuse. Each
# individual PATCH is still separately bounded by MOJO_MAX_MESSAGE_SIZE.
my $UPLOAD_CHUNK_SIZE = 8 * 1024 * 1024;         # 8 MiB
my $MAX_UPLOAD_BYTES  = 50 * 1024 * 1024 * 1024;  # 50 GiB
# Cap on how many upload sessions one user may hold 'open' at once. Each
# open session is a DB row + a real (initially 0-byte) .partials file, so
# without a cap an authenticated client could cheaply flood the sessions
# table + the .partials inode count without ever sending payload bytes
# (the sweeper only reclaims sessions idle > 24h). Generous enough for
# any real parallel-upload UI, low enough to bound abuse.
my $MAX_OPEN_SESSIONS_PER_USER = 100;

# Default per-user drive quota: 1 TiB. Applied when a user has no row in
# drive.quotas (see migration 010); an admin sets a row to override one
# user's limit. Usage counts live (non-trashed) bytes only, matching the
# usage figure shown to the user.
my $DEFAULT_QUOTA_BYTES = 1024 ** 4;   # 1 TiB

# This user's live usage (bytes).
sub _user_used ($c, $email) {
    my $row = $c->app->pg->db->query(
        'SELECT COALESCE(SUM(size_bytes), 0) AS used FROM drive.files WHERE user_email = ? AND deleted_at IS NULL',
        $email)->hash;
    return ($row->{used} // 0) + 0;
}

# This user's quota limit (their override, else the default).
sub _user_limit ($c, $email) {
    my $row = $c->app->pg->db->query('SELECT limit_bytes FROM drive.quotas WHERE user_email = ?', $email)->hash;
    return $row ? $row->{limit_bytes} + 0 : $DEFAULT_QUOTA_BYTES;
}

# True if adding $incoming bytes would push this user over their quota.
sub _quota_would_exceed ($c, $email, $incoming) {
    return 0 unless defined $incoming && $incoming > 0;
    return (_user_used($c, $email) + $incoming) > _user_limit($c, $email) ? 1 : 0;
}

# Returns the logged-in user's email, or undef (and does NOT redirect —
# callers decide what "not logged in" means for their own route).
# Re-checks the JWT against homelab-api on every request rather than
# trusting the session blindly, same "don't assume, verify" reasoning
# as Homelab::Common::AuthClient exists for in the first place — a
# session that's still present but whose JWT expired must not keep
# working.
#
# Checks a Bearer Authorization header FIRST, falling back to the
# browser session cookie -- this is what lets the same handler back
# both the browser UI (session cookie, set via the SSO redirect flow)
# and the /api/v1/files JSON API below (a bearer token, e.g. homelab-cli
# holding its own homelab-api JWT directly -- no session/cookie
# involved at all for a CLI client).
sub _current_email ($c) {
    my ($email) = _current_auth($c);
    return $email;
}

# Same as _current_email above, but also hands back the raw JWT itself
# -- needed for the zip-job hand-off to homelab-worker (see
# create_zip_job below and README.md's "the auth hand-off" section):
# the worker fetches each manifest entry from THIS app's own
# /api/v1/files/:id using this exact forwarded token, so it has to be
# the real, still-valid JWT _current_email() already verified above,
# not re-derived some other way. Returns (undef, undef) on any auth
# failure, same "caller renders its own 401" convention as
# _current_email.
sub _current_auth ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    $jwt //= $c->session('token');
    return (undef, undef) unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    # Third value (jti) is new, for the audit trail -- every existing
    # 2-variable caller (and _current_email's 1-variable one) silently
    # ignores it via list destructuring, same additive-return-list
    # precedent used throughout this codebase.
    return $result ? ($result->{email}, $jwt, $result->{jti}) : (undef, undef, undef);
}

# Walks the parent chain from the given folder up to the root,
# returning an arrayref of {id, name} from root-most to current --
# what the template renders as the clickable breadcrumb trail. Root
# itself isn't a row (see migrations/002-folders.sql: NULL parent_folder_id
# IS the root, no sentinel row needed), so it's never included here --
# the template renders its own fixed "Home" link for that.
sub _breadcrumb ($c, $email, $folder_id) {
    my @trail;
    while (defined $folder_id) {
        my $folder = $c->app->pg->db->query(
            'SELECT id, name, parent_folder_id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NULL',
            $folder_id, $email,
        )->hash;
        last unless $folder;
        unshift @trail, { id => $folder->{id}, name => $folder->{name} };
        $folder_id = $folder->{parent_folder_id};
    }
    return \@trail;
}

# Backs both GET / (root) and GET /folders/:id (a specific folder) --
# :id is simply absent for the root case, and drive.folders.parent_folder_id
# IS NULL is what "root" means throughout this file (see
# migrations/002-folders.sql). Shows this folder's own subfolders (the
# "directories on the left" of the two-pane layout) and files (the main
# pane) side by side -- deliberately only direct children, not a full
# recursive tree view; see README.md's Folders section for why that's a
# deliberate v1 scope choice, not an oversight.
sub index ($c) {
    my $email = _current_email($c);
    return $c->redirect_to('/login') unless $email;

    my $folder_id = $c->param('id');

    if (defined $folder_id) {
        my $folder = $c->app->pg->db->query(
            'SELECT id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NULL', $folder_id, $email,
        )->hash;
        return $c->render(text => 'folder not found', status => 404) unless $folder;
    }

    # drive.folders self-references via parent_folder_id; drive.files
    # points at a folder via folder_id -- two different column names,
    # deliberately NOT reused as one shared filter string here (that
    # was a real bug once: querying drive.folders with a "folder_id ="
    # filter, a column that table doesn't have at all).
    my $subfolder_filter = defined $folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my $file_filter      = defined $folder_id ? 'folder_id = ?'        : 'folder_id IS NULL';
    my @folder_bind       = defined $folder_id ? ($folder_id) : ();

    my $subfolders = $c->app->pg->db->query(
        "SELECT id, name FROM drive.folders WHERE user_email = ? AND $subfolder_filter AND deleted_at IS NULL ORDER BY name",
        $email, @folder_bind,
    )->hashes;

    # uploaded_at_display is a browser-UI-only presentation column --
    # the JSON API (api_list) deliberately keeps selecting plain
    # uploaded_at with full precision and a numeric offset, since a
    # script consuming it might actually want that. to_char's TZ format
    # spec pulls the zone ABBREVIATION (e.g. "CDT") from the session's
    # `timezone` GUC (already a real IANA zone, "America/Chicago" --
    # confirmed via `SHOW timezone` -- not a bare offset), which is what
    # makes this DST-correct for free: to_char picks CDT or CST based on
    # the actual date of each row, not a hardcoded label. This also
    # drops fractional seconds as a side effect of the explicit format
    # string (no regex trimming needed, unlike the old plain-offset
    # version of this field).
    my $files = $c->app->pg->db->query(
        "SELECT id, filename, size_bytes, mime_type, uploaded_at,
                to_char(uploaded_at, 'YYYY-MM-DD HH24:MI:SS TZ') AS uploaded_at_display
         FROM drive.files
         WHERE user_email = ? AND $file_filter AND deleted_at IS NULL ORDER BY uploaded_at DESC",
        $email, @folder_bind,
    )->hashes;

    return $c->render(
        template => 'index', email => $email, files => $files, folders => $subfolders,
        current_folder_id => $folder_id, breadcrumb => _breadcrumb($c, $email, $folder_id),
        error => $c->flash('error'),
        account_manage_url => $c->app->account_manage_url,
    );
}

sub _random_state {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $state = '';
    $state .= $chars[int(rand(@chars))] for 1 .. 32;
    return $state;
}

# There is no local password form any more — homelab-sso is the one
# place a password ever gets typed, so every relying party (this one
# included) redirects there instead of collecting credentials itself.
# `state` is a one-time CSRF nonce: stashed in Drive's own session here,
# checked against what the callback actually receives back, so a
# forged/replayed callback can't complete a login on this browser's
# behalf.
sub login_form ($c) {
    return $c->redirect_to('/') if _current_email($c);

    my $state = _random_state();
    $c->session(oauth_state => $state);

    my $url = Mojo::URL->new($c->app->sso_base . '/oauth/authorize')->query(
        client_id    => $c->app->sso_client_id,
        redirect_uri => $c->app->sso_redirect_uri,
        state        => $state,
        scope        => 'openid',
    );
    return $c->redirect_to($url);
}

# GET /oauth/callback?code=...&state=... — homelab-sso sends the
# browser here after a successful login (or an already-live IdP
# session, in which case the user never even saw a form). The code
# exchange itself is server-to-server (Homelab::Common::SSOClient),
# never exposed to the browser.
sub oauth_callback ($c) {
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state');
    $c->session(oauth_state => undef);

    unless ($code && $expected && $state eq $expected) {
        return $c->render(template => 'login', error => 'Login failed: the request expired or was invalid. Please try again.');
    }

    my $result = exchange_code($code,
        sso_base      => $c->app->sso_internal_base,
        client_id     => $c->app->sso_client_id,
        client_secret => $c->app->sso_client_secret,
        redirect_uri  => $c->app->sso_redirect_uri,
    );
    unless ($result->{success}) {
        return $c->render(template => 'login', error => 'Login failed: could not complete sign-in. Please try again.');
    }

    $c->session(token => $result->{access_token}, refresh_token => $result->{refresh_token});
    return $c->redirect_to('/');
}

# Deliberately does NOT revoke the token itself (homelab-api's
# AuthClient::revoke() is still there, but calling it here would only
# be half of "logout everywhere"). Instead this redirects to
# homelab-sso's own /logout, which revokes the shared session centrally
# AND clears the IdP cookie — the single place that mechanism lives, so
# every relying party's logout button just routes through it. See
# ../../sso/README.md.
sub logout ($c) {
    $c->session(expires => 1);
    my $post_logout_uri = Mojo::URL->new($c->app->sso_redirect_uri)->path('/login');
    my $url = Mojo::URL->new($c->app->sso_base . '/logout')->query(redirect_uri => $post_logout_uri);
    return $c->redirect_to($url);
}

# A folder_id param that's present-but-empty (an unset <select> in the
# upload form, or an omitted JSON/query field) means the same thing as
# absent entirely: root. Centralized here since every folder-aware
# handler below needs this exact normalization.
#
# Anything that isn't a plain 1-18 digit integer is also normalized to
# undef (root): a non-numeric or absurdly-long value would otherwise
# reach the `WHERE id = ?` bigint comparison in _owned_folder and make
# Postgres raise "invalid input syntax for type bigint" / "out of range"
# -- an unhandled 500. The 18-digit cap keeps it comfortably inside
# bigint's range. This guards EVERY folder-aware handler (upload,
# api_upload, append, create_upload_session, folder creation), the same
# "a malformed id matches nothing rather than crashing" reasoning as the
# strict UUID check in _load_owned_session.
sub _normalize_folder_id ($raw) {
    return undef unless defined $raw && $raw =~ /^\d{1,18}$/;
    return $raw + 0;
}

# undef unless the given folder both exists AND belongs to $email --
# used everywhere a caller-supplied folder_id needs validating before
# it's trusted (uploading into it, listing it, nesting a new folder
# under it).
sub _owned_folder ($c, $email, $folder_id) {
    return undef unless defined $folder_id;
    return $c->app->pg->db->query(
        'SELECT id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NULL', $folder_id, $email,
    )->hash;
}

# Shared by the browser form (upload()) and the JSON API (api_upload())
# below -- inserts the DB row and moves the uploaded file into storage,
# returning the new row (id, filename, size_bytes, mime_type,
# uploaded_at). Callers decide how to respond (redirect vs JSON).
sub _save_upload ($c, $email, $upload, $folder_id) {
    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type, folder_id)
          VALUES (?, ?, ?, ?, ?) RETURNING id, filename, size_bytes, mime_type, uploaded_at, folder_id, uuid},
        $email, $upload->filename, $upload->size, $upload->headers->content_type, $folder_id,
    )->hash;

    my $dest = $c->app->storage_path . '/' . $row->{uuid};
    $upload->move_to($dest);

    # The client-declared Content-Type used in the INSERT above is never
    # trustworthy (a browser/script can send anything, including a
    # generic default) -- now that the real bytes are on disk, sniff
    # them for real and correct the stored mime_type if it disagrees.
    # This is also what decides whether image derivatives get generated
    # below, so the "does this file get a thumbnail" decision and the
    # "Type" column/sort-by-type feature (see README.md) both end up
    # looking at the same real answer instead of two signals that can
    # disagree -- a real, caught-by-its-own-test bug the first version
    # of this had: a client that didn't send a proper image/* Content-
    # Type still got real thumbnail/slideshow-image files generated
    # (sniffed correctly) but the file row never showed them (the
    # template trusted the client-declared type instead).
    my $sniffed = $MAGIC->checktype_filename($dest);
    if ($sniffed && $sniffed ne ($row->{mime_type} // '')) {
        $c->app->pg->db->query('UPDATE drive.files SET mime_type = ? WHERE id = ?', $sniffed, $row->{id});
        $row->{mime_type} = $sniffed;
    }

    _generate_image_derivatives($c, $dest, $row->{uuid}, $sniffed);

    delete $row->{uuid};    # internal storage detail, never exposed
    return $row;
}

# Best-effort: a thumbnail/slideshow-image failure must never fail the
# upload itself -- the real file already landed on disk successfully,
# only these two derivatives are at risk. $mime_type is the already-
# sniffed (not client-declared) type from _save_upload above -- feeding
# attacker-controlled bytes into Image::Magick under a spoofed image/*
# Content-Type is exactly the kind of format-confusion ImageMagick has a
# real CVE history around, so the decision to even attempt decoding
# never rests on client input.
#
# Generated synchronously, inline with the upload request: this repo has
# no background job queue yet (unlike the old homelab-drive-web-ui,
# which offloaded this to homelab-api-backend-processor), and
# ImageMagick thumbnailing typical photos is fast enough that this is
# the simpler choice for now -- revisit with a real queue (see
# ../../CLAUDE.md's Minion plans) if large/frequent image uploads ever
# make upload latency a real problem.
sub _generate_image_derivatives ($c, $path, $uuid, $mime_type) {
    return unless ($mime_type // '') =~ m{^image/};

    my $cfg = $c->app->image_config;
    my %variant = (
        thumbnails => [$cfg->{thumbnail_geometry} // '200x200>',   $cfg->{thumbnail_quality} // 80],
        slideshow  => [$cfg->{slideshow_geometry}  // '1280x1280>', $cfg->{slideshow_quality} // 82],
    );

    for my $subdir (sort keys %variant) {
        my ($geometry, $quality) = @{ $variant{$subdir} };
        my $dest_dir = $c->app->storage_path . "/.$subdir";
        make_path($dest_dir) unless -d $dest_dir;
        my $dest = "$dest_dir/$uuid.jpg";

        eval {
            my $img = Image::Magick->new;
            my $err = $img->Read($path);
            die "$err\n" if $err;
            $img->Thumbnail(geometry => $geometry);
            $img->Set(quality => $quality);
            $err = $img->Write("jpeg:$dest");
            die "$err\n" if $err;
        };
        $c->app->log->warn("homelab-drive: $subdir generation failed for $uuid: $@") if $@;
    }
    return;
}

# Derivative files (thumbnail, slideshow-image) are looked up purely by
# uuid, never queried for -- unlinked alongside the original here and in
# _delete_folder()'s bulk cleanup below. A missing derivative (non-image
# file, or generation failed/skipped) is silently a no-op, same as the
# original file's own "unlink if -f" convention.
sub _unlink_derivatives ($c, $uuid) {
    for my $subdir (qw(thumbnails slideshow)) {
        my $path = $c->app->storage_path . "/.$subdir/$uuid.jpg";
        unlink($path) if -f $path;
    }
    return;
}

sub upload ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    my $back = $folder_id ? "/folders/$folder_id" : '/';

    my $upload = $c->req->upload('file');
    return $c->redirect_to($back) unless $upload;

    # A tampered/stale folder_id (deleted since the page was loaded, or
    # someone else's id) silently falls back to root rather than 500ing
    # or trusting an unowned folder -- same "fail to somewhere safe, not
    # to an error page" spirit as this file's other browser-facing
    # handlers.
    $folder_id = undef unless _owned_folder($c, $email, $folder_id);

    # Quota: refuse an upload that would push the user over their limit.
    if (_quota_would_exceed($c, $email, $upload->size)) {
        $c->flash(error => 'Upload would exceed your storage quota.');
        return $c->redirect_to($back);
    }

    _save_upload($c, $email, $upload, $folder_id);
    return $c->redirect_to($folder_id ? "/folders/$folder_id" : '/');
}

# POST /api/v1/files (multipart, field name "file", optional field
# "folder_id") -- Bearer-authed equivalent of the browser upload form
# above, for homelab-cli (`homelab-cli drive upload`) or any third-party
# script (see ../../CLAUDE.md and this package's own README on why a
# real JSON API matters here, not just the browser UI).
sub api_upload ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $upload = $c->req->upload('file');
    return $c->render(json => { error => 'no file provided (multipart field name must be "file")' }, status => 400)
        unless $upload;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    if (defined $folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $folder_id);
    }

    return $c->render(json => { error => 'upload would exceed your storage quota' }, status => 413)
        if _quota_would_exceed($c, $email, $upload->size);

    my $row = _save_upload($c, $email, $upload, $folder_id);
    return $c->render(json => $row, status => 201);
}

# ====================================================================
# Chunked / resumable uploads. See migrations/006-upload-sessions.sql
# for the protocol and why it exists. Four handlers, all dual-mounted
# (bare path for the browser UI, /api/v1/... for homelab-cli); the bytes
# accumulate in ONE .partial file per session, whose on-disk size is the
# authoritative resume offset.
# ====================================================================

sub _partial_path ($c, $id) { return $c->app->storage_path . "/.partials/$id"; }

# Loads the session named by the :id route param, scoped to the owner.
# The strict UUID shape check matters: an :id that isn't a syntactically
# valid UUID would make Postgres raise "invalid input syntax for type
# uuid" (a 500) rather than simply matching no row -- so a malformed id
# is rejected as "not found" here before it ever reaches the query.
sub _load_owned_session ($c, $email) {
    my $id = $c->stash('id') // '';
    return undef unless $id =~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
    return $c->app->pg->db->query(
        q{SELECT id, user_email, filename, total_size, received_bytes, folder_id, state, result_file_id
          FROM drive.upload_sessions WHERE id = ? AND user_email = ?},
        $id, $email,
    )->hash;
}

# Turns a fully-received partial into a real drive.files row: insert the
# row first (to get its uuid), rename the partial into storage under that
# uuid (a cheap SAME-FS move -- the partial already lives on the storage
# filesystem), then flip the session to 'completed' WITH result_file_id
# in a SINGLE UPDATE. That atomicity is load-bearing: an earlier version
# marked 'completed' first and set result_file_id last (with slow work in
# between), so a concurrent GET / retried final PATCH could observe a
# 'completed' session with a NULL file_id and report a null id for a
# file that really exists (found by review). Insert-then-move ordering
# (same as _run_append_jobs) means a failed move never orphans a blob,
# and on that failure the partial is unlinked too so it doesn't leak.
# Dies on an unrecoverable move failure; the caller renders 500. mime
# sniffing + image derivatives are deliberately NOT done here -- they run
# in _postprocess_upload AFTER the caller releases the flock, so their
# latency neither holds the per-session lock nor widens any window.
# Returns { id, uuid, dest }.
sub _finalize_upload_session ($c, $session, $partial) {
    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type, folder_id)
          VALUES (?, ?, ?, ?, ?) RETURNING id, uuid},
        $session->{user_email}, $session->{filename}, $session->{total_size},
        'application/octet-stream', $session->{folder_id},
    )->hash;

    my $dest = $c->app->storage_path . '/' . $row->{uuid};
    unless (rename($partial, $dest)) {
        require File::Copy;
        unless (File::Copy::move($partial, $dest)) {
            my $err = "$!";
            $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $row->{id});
            unlink($partial) if -e $partial;   # don't leak the partial on a move failure
            $c->app->pg->db->query(
                q{UPDATE drive.upload_sessions SET state = 'aborted', updated_at = NOW() WHERE id = ?},
                $session->{id});
            die "could not move finalized upload into storage: $err\n";
        }
    }

    $c->app->pg->db->query(
        q{UPDATE drive.upload_sessions SET state = 'completed', result_file_id = ?, updated_at = NOW() WHERE id = ?},
        $row->{id}, $session->{id});

    return { id => $row->{id}, uuid => $row->{uuid}, dest => $dest };
}

# Post-finalize, best-effort, and OUTSIDE the per-session flock: sniff the
# real mime (client-declared type is never trusted -- same reasoning as
# _save_upload) and generate image derivatives. Runs after the session is
# already 'completed' with its file_id set, so however long Image::Magick
# takes it can't widen the finalize window or block a concurrent PATCH.
sub _postprocess_upload ($c, $dest, $uuid, $file_id) {
    my $sniffed = eval { $MAGIC->checktype_filename($dest) };
    $c->app->pg->db->query('UPDATE drive.files SET mime_type = ? WHERE id = ?', $sniffed, $file_id)
        if $sniffed;
    _generate_image_derivatives($c, $dest, $uuid, $sniffed);
    return;
}

# Renders the right response for a PATCH that finds its session is no
# longer 'open' (a concurrent finalize/abort/sweep won the race, or the
# partial vanished under it). A 'completed' session reports done + the
# real file_id (so a duplicate final chunk still gets a usable answer);
# anything else is a 409 the client can act on.
sub _upload_state_response ($c, $s) {
    return $c->render(json => { error => 'upload session not found' }, status => 404) unless $s;
    if ($s->{state} eq 'completed') {
        return $c->render(json => {
            offset => $s->{total_size} + 0, done => \1,
            file_id => $s->{result_file_id}, state => 'completed',
        }, status => 409);
    }
    return $c->render(json => { error => "upload is $s->{state}", state => $s->{state}, offset => 0 }, status => 409);
}

# POST /uploads (+ /api/v1/uploads): open a session.
# Body JSON: { filename, total_size, folder_id? }. Returns
# { upload_id, offset:0, chunk_size } (201). A zero-byte file has nothing
# to PATCH, so it's finalized right here and comes back { done, file_id }.
sub create_upload_session ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body     = $c->req->json // {};
    my $filename = $body->{filename};
    $filename = basename($filename) if defined $filename;   # never a path
    return $c->render(json => { error => 'filename is required' }, status => 400)
        unless defined $filename && $filename =~ /\S/;

    my $total = $body->{total_size};
    return $c->render(json => { error => 'total_size (bytes) is required and must be a non-negative integer' }, status => 400)
        unless defined $total && "$total" =~ /^\d+$/;
    $total += 0;
    return $c->render(json => { error => "total_size exceeds the maximum of $MAX_UPLOAD_BYTES bytes" }, status => 413)
        if $total > $MAX_UPLOAD_BYTES;
    # Quota: refuse up front (before allocating a session) if the declared
    # size would push the user over their limit.
    return $c->render(json => { error => 'upload would exceed your storage quota' }, status => 413)
        if _quota_would_exceed($c, $email, $total);

    my $folder_id = _normalize_folder_id($body->{folder_id});
    if (defined $folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $folder_id);
    }

    # Bound how many sessions one user may hold open at once (see
    # $MAX_OPEN_SESSIONS_PER_USER) -- otherwise a client could flood the
    # table + .partials without ever sending bytes.
    my $open = $c->app->pg->db->query(
        q{SELECT count(*) AS n FROM drive.upload_sessions WHERE user_email = ? AND state = 'open'},
        $email)->hash->{n};
    return $c->render(json => { error => 'too many uploads in progress; finish, resume, or delete some first' }, status => 429)
        if $open >= $MAX_OPEN_SESSIONS_PER_USER;

    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.upload_sessions (user_email, filename, total_size, folder_id)
          VALUES (?, ?, ?, ?) RETURNING id},
        $email, $filename, $total, $folder_id,
    )->hash;
    my $id = $row->{id};

    # Create the empty partial up front so GET/PATCH always have a real
    # file to stat and flock.
    my $partial = _partial_path($c, $id);
    unless (open(my $fh, '>', $partial)) {
        $c->app->log->error("upload $id: could not create partial: $!");
        return $c->render(json => { error => 'could not start upload' }, status => 500);
    }

    if ($total == 0) {
        my $file = eval { _finalize_upload_session($c, {
            id => $id, user_email => $email, filename => $filename,
            total_size => 0, folder_id => $folder_id,
        }, $partial) };
        return $c->render(json => { error => 'could not finalize empty upload' }, status => 500) unless $file;
        _postprocess_upload($c, $file->{dest}, $file->{uuid}, $file->{id});
        return $c->render(json => { upload_id => $id, offset => 0, done => \1, file_id => $file->{id} }, status => 201);
    }

    return $c->render(json => {
        upload_id  => $id,
        offset     => 0,
        chunk_size => $UPLOAD_CHUNK_SIZE,   # a suggestion; the client may use its own
    }, status => 201);
}

# GET /uploads/:id (+ /api/v1): status, for resume. Returns the
# authoritative offset (the on-disk partial size), or the finished
# file_id once completed.
sub get_upload_session ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $s = _load_owned_session($c, $email);
    return $c->render(json => { error => 'upload session not found' }, status => 404) unless $s;

    if ($s->{state} eq 'completed') {
        return $c->render(json => {
            upload_id => $s->{id}, state => 'completed',
            offset => $s->{total_size} + 0, total_size => $s->{total_size} + 0,
            filename => $s->{filename}, file_id => $s->{result_file_id},
        });
    }

    # Touch updated_at so a client that's actively resuming (it GETs the
    # offset before re-PATCHing) can't be reaped by the stale-session
    # sweeper in the window between this status check and its next chunk,
    # even if the upload had been paused past the retention cutoff.
    $c->app->pg->db->query(
        q{UPDATE drive.upload_sessions SET updated_at = NOW() WHERE id = ? AND state = 'open'},
        $s->{id});

    my $partial = _partial_path($c, $s->{id});
    my $offset  = -e $partial ? (stat $partial)[7] : 0;
    return $c->render(json => {
        upload_id => $s->{id}, state => $s->{state},
        offset => $offset + 0, total_size => $s->{total_size} + 0,
        filename => $s->{filename}, chunk_size => $UPLOAD_CHUNK_SIZE,
    });
}

# PATCH /uploads/:id (+ /api/v1): append one chunk. The request carries
# an `Upload-Offset` header (the byte offset this chunk begins at, which
# MUST equal the bytes already stored) and the raw chunk as the body.
# Returns { offset, done, file_id? }; a 409 carrying the TRUE { offset }
# tells a resuming or duplicate client where to actually continue from.
sub patch_upload_chunk ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $s = _load_owned_session($c, $email);
    return $c->render(json => { error => 'upload session not found' }, status => 404) unless $s;
    if ($s->{state} ne 'open') {
        # Already finished or aborted -- tell a retrying client, with the
        # file id if there is one, so it doesn't try to resume.
        return $c->render(json => {
            error  => "upload is $s->{state}", state => $s->{state},
            offset => $s->{total_size} + 0,
            ($s->{state} eq 'completed' ? (file_id => $s->{result_file_id}, done => \1) : ()),
        }, status => 409);
    }

    my $claimed = $c->req->headers->header('Upload-Offset');
    return $c->render(json => { error => 'Upload-Offset header (a non-negative integer) is required' }, status => 400)
        unless defined $claimed && $claimed =~ /^\d+$/;
    $claimed += 0;

    my $asset      = $c->req->content->asset;
    my $chunk_size = $asset ? $asset->size : 0;

    my $partial = _partial_path($c, $s->{id});
    # NO O_CREAT: the partial is pre-created when the session opens and is
    # only ever removed by finalize (rename), DELETE, or the sweeper --
    # each of which also settles the row. So a MISSING partial here means
    # one of those raced us; recreating it (an earlier O_CREAT bug) would
    # resurrect an orphan blob nothing could ever reclaim. Treat "gone" as
    # "the session moved on" and report its real current state.
    sysopen(my $fh, $partial, O_RDWR)
        or return _upload_state_response($c, _load_owned_session($c, $email));
    # LOCK_EX serializes concurrent PATCHes for the SAME session across
    # hypnotoad workers, and -- because the finalize below runs while this
    # lock is still held -- also serializes a duplicate final chunk
    # against the finalizer. The on-disk size read under this lock is the
    # single source of truth for the resume offset.
    flock($fh, LOCK_EX) or do {
        close($fh);
        return $c->render(json => { error => 'upload storage busy' }, status => 503);
    };

    # Re-check state UNDER the lock: while we waited for it, a finalize or
    # abort on another worker may have completed/aborted this session (the
    # row we loaded at the top of the handler is stale by now).
    my $fresh = _load_owned_session($c, $email);
    unless ($fresh && $fresh->{state} eq 'open') {
        close($fh);
        return _upload_state_response($c, $fresh);
    }

    my $actual = (stat $fh)[7] // 0;
    if ($claimed != $actual) {
        close($fh);   # releases the lock
        return $c->render(json => { error => 'offset mismatch', offset => $actual + 0 }, status => 409);
    }
    if ($actual + $chunk_size > $s->{total_size}) {
        close($fh);
        return $c->render(json => {
            error => 'chunk would exceed the declared total_size', offset => $actual + 0,
        }, status => 409);
    }

    # Append the incoming chunk, streamed from the request asset in 1MB
    # slices so even an oversized single chunk never sits wholly in RAM.
    sysseek($fh, 0, SEEK_END);
    my $off = 0;
    while ($off < $chunk_size) {
        my $piece = $asset->get_chunk($off, 1048576);
        last unless length $piece;
        my $poff = 0;
        while ($poff < length $piece) {
            my $w = syswrite($fh, $piece, length($piece) - $poff, $poff);
            unless (defined $w) {
                my $err = "$!";
                close($fh);
                $c->app->log->error("upload $s->{id}: write failed near offset " . ($actual + $off) . ": $err");
                return $c->render(json => { error => 'upload write failed', offset => ((stat $partial)[7] // 0) + 0 }, status => 500);
            }
            $poff += $w;
        }
        $off += length $piece;
    }
    my $new_size = (stat $fh)[7] // ($actual + $chunk_size);

    $c->app->pg->db->query(
        q{UPDATE drive.upload_sessions SET received_bytes = ?, updated_at = NOW() WHERE id = ? AND state = 'open'},
        $new_size, $s->{id});

    if ($new_size < $s->{total_size}) {
        close($fh);   # flush + release lock; more chunks to come
        return $c->render(json => { offset => $new_size + 0, done => \0 });
    }

    # Last chunk landed. Finalize WHILE STILL HOLDING THE LOCK, so a
    # duplicate final chunk on another worker is serialized behind us --
    # it'll re-check state (above) after we've flipped it to 'completed'
    # and take the _upload_state_response path instead of double-inserting.
    # _finalize sets 'completed' + result_file_id atomically only after
    # the bytes are safely renamed into storage. mime sniff + derivatives
    # run AFTER the lock is released (they touch the stored file, not the
    # partial), so their latency neither holds the lock nor widens a window.
    my $file = eval { _finalize_upload_session($c, {
        id => $s->{id}, user_email => $email, filename => $s->{filename},
        total_size => $s->{total_size}, folder_id => $s->{folder_id},
    }, $partial) };
    my $ferr = $file ? undef : ($@ || 'finalize failed');
    close($fh);   # release the lock (finalize is done, success or not)
    if (!$file) {
        $c->app->log->error("upload $s->{id}: finalize failed: $ferr");
        return $c->render(json => { error => 'could not finalize upload', offset => $new_size + 0 }, status => 500);
    }
    _postprocess_upload($c, $file->{dest}, $file->{uuid}, $file->{id});
    return $c->render(json => { offset => $new_size + 0, done => \1, file_id => $file->{id} });
}

# DELETE /uploads/:id (+ /api/v1): abort an in-progress upload, dropping
# its partial. A completed session is left alone (its bytes are a real
# file now) -- deleting that file is the files API's job, not this one.
sub delete_upload_session ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $s = _load_owned_session($c, $email);
    return $c->render(json => { error => 'upload session not found' }, status => 404) unless $s;
    if ($s->{state} eq 'completed') {
        return $c->render(json => { error => 'upload already completed; delete the file instead' }, status => 409);
    }

    my $partial = _partial_path($c, $s->{id});
    unlink($partial) if -e $partial;
    $c->app->pg->db->query('DELETE FROM drive.upload_sessions WHERE id = ?', $s->{id});
    return $c->render(json => { ok => \1 });
}

# GET /api/v1/files -- this user's own files, as JSON. Optional
# ?folder_id=<id> query param scopes to one folder's direct contents,
# same as index()'s own browser view; omitted means root, NOT "every
# file everywhere" (see README.md's Folders section -- this is a
# deliberate behavior change from before folders existed, but a
# backward-compatible one: every file uploaded before this migration
# has folder_id NULL, i.e. already "at the root").
sub api_list ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    if (defined $folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $folder_id);
    }
    my $folder_filter = defined $folder_id ? 'folder_id = ?' : 'folder_id IS NULL';
    my @folder_bind   = defined $folder_id ? ($folder_id) : ();

    my $files = $c->app->pg->db->query(
        "SELECT id, filename, size_bytes, mime_type, uploaded_at, folder_id FROM drive.files
         WHERE user_email = ? AND $folder_filter AND deleted_at IS NULL ORDER BY uploaded_at DESC",
        $email, @folder_bind,
    )->hashes;
    return $c->render(json => $files);
}

# GET /api/v1/usage -- this user's live drive usage in bytes. Used by
# homelab-accountmanage's storage panel (via the api gateway's
# /api/v1/drive/usage). Counts non-trashed files only.
sub api_usage ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    return $c->render(json => {
        used_bytes  => _user_used($c, $email),
        limit_bytes => _user_limit($c, $email),
    });
}

# --- Folders -------------------------------------------------------

# Shared by the browser form (create_folder()) and the JSON API
# (api_create_folder()) below. Returns (row, undef) on success or
# (undef, error_message) on failure -- a duplicate name in the same
# parent, or a parent_folder_id that doesn't exist/isn't this user's.
# No UNIQUE constraint backs the duplicate-name check (see
# migrations/002-folders.sql for why NULL parent_folder_id made that
# not work cleanly) -- this check-then-insert has the usual narrow
# TOCTOU race under real concurrent requests, accepted here the same
# way homelab-api's own register() accepts one for email uniqueness:
# annoying on a collision, not a security or data-integrity problem
# (worst case is two folders sharing a name, not silent data loss).
sub _create_folder ($c, $email, $name, $parent_folder_id) {
    if (defined $parent_folder_id) {
        return (undef, 'parent folder not found') unless _owned_folder($c, $email, $parent_folder_id);
    }

    my $folder_filter = defined $parent_folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my @folder_bind   = defined $parent_folder_id ? ($parent_folder_id) : ();
    my $existing = $c->app->pg->db->query(
        "SELECT id FROM drive.folders WHERE user_email = ? AND name = ? AND $folder_filter AND deleted_at IS NULL",
        $email, $name, @folder_bind,
    )->hash;
    return (undef, 'a folder with that name already exists here') if $existing;

    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.folders (user_email, name, parent_folder_id)
          VALUES (?, ?, ?) RETURNING id, name, parent_folder_id},
        $email, $name, $parent_folder_id,
    )->hash;
    return ($row, undef);
}

sub create_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $parent_folder_id = _normalize_folder_id($c->param('parent_folder_id'));
    my $back = $parent_folder_id ? "/folders/$parent_folder_id" : '/';
    my $name = $c->param('name');

    unless (defined $name && length $name) {
        $c->flash(error => 'Folder name is required');
        return $c->redirect_to($back);
    }

    my (undef, $error) = _create_folder($c, $email, $name, $parent_folder_id);
    $c->flash(error => $error) if $error;
    return $c->redirect_to($back);
}

# POST /api/v1/folders {name, parent_folder_id} (parent_folder_id
# omitted/null means root) -- Bearer-authed equivalent of the browser
# form above.
sub api_create_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body = $c->req->json // {};
    my $name = $body->{name};
    return $c->render(json => { error => 'name is required' }, status => 400) unless defined $name && length $name;

    my ($row, $error) = _create_folder($c, $email, $name, $body->{parent_folder_id});
    return $c->render(json => { error => $error }, status => 409) if $error;
    return $c->render(json => $row, status => 201);
}

# GET /api/v1/folders?parent_id=<id> -- this user's own subfolders of
# the given parent (omitted means root), as JSON. Same query index()
# uses for the browser's own sidebar.
sub api_list_folders ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $parent_folder_id = _normalize_folder_id($c->param('parent_id'));
    if (defined $parent_folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $parent_folder_id);
    }
    my $folder_filter = defined $parent_folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my @folder_bind   = defined $parent_folder_id ? ($parent_folder_id) : ();

    my $folders = $c->app->pg->db->query(
        "SELECT id, name, parent_folder_id FROM drive.folders WHERE user_email = ? AND $folder_filter AND deleted_at IS NULL ORDER BY name",
        $email, @folder_bind,
    )->hashes;
    return $c->render(json => $folders);
}

# Shared by the browser form (delete_folder()) and the JSON API
# (api_delete_folder()) below. Deleting a folder deletes everything
# inside it, recursively -- every subfolder and file, via the ON DELETE
# CASCADE chains in migrations/002-folders.sql. The DB cascade only
# removes rows, though; it has no idea these files also have real
# on-disk blobs, so this walks the whole subtree FIRST (a recursive
# CTE) to collect every uuid that's about to be orphaned, then unlinks
# them from disk after the DB delete succeeds -- skipping this would
# leak storage forever on every folder delete. Returns (1,
# parent_folder_id_of_the_deleted_folder) on success, (0, undef) if
# there was nothing to delete (nonexistent id, or someone else's --
# deliberately indistinguishable, same reasoning as this file's other
# "not found" checks).
sub _delete_folder ($c, $email, $id, $soft = 0) {
    my $folder = $c->app->pg->db->query(
        'SELECT parent_folder_id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NULL', $id, $email,
    )->hash;
    return (0, undef) unless $folder;

    if ($soft) {
        # Soft-delete the WHOLE subtree (this folder, its descendant
        # folders, and every file under any of them) so nothing lingers
        # in a live view and Restore brings the whole thing back as a
        # unit. Already-trashed rows keep their original deleted_at.
        my $cte = q{WITH RECURSIVE subtree AS (
                        SELECT id FROM drive.folders WHERE id = ?
                        UNION ALL
                        SELECT f.id FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
                    )};
        $c->app->pg->db->query(
            "$cte UPDATE drive.folders SET deleted_at = NOW() WHERE id IN (SELECT id FROM subtree) AND deleted_at IS NULL",
            $id);
        $c->app->pg->db->query(
            "$cte UPDATE drive.files SET deleted_at = NOW() WHERE folder_id IN (SELECT id FROM subtree) AND deleted_at IS NULL",
            $id);
        return (1, $folder->{parent_folder_id});
    }

    # HARD delete: collect every blob under the subtree, drop the folder
    # (ON DELETE CASCADE removes descendant folder + file rows), then
    # unlink the blobs the DB no longer references.
    my $orphaned = $c->app->pg->db->query(
        q{WITH RECURSIVE subtree AS (
            SELECT id FROM drive.folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
          )
          SELECT uuid FROM drive.files WHERE folder_id IN (SELECT id FROM subtree)},
        $id,
    )->hashes;

    $c->app->pg->db->query('DELETE FROM drive.folders WHERE id = ?', $id);

    _hard_remove_file($c, $_->{uuid}) for @$orphaned;
    return (1, $folder->{parent_folder_id});
}

sub delete_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    # Browser folder delete is SOFT (whole subtree goes to Trash).
    my (undef, $parent_folder_id) = _delete_folder($c, $email, $c->param('id'), 1);
    return $c->redirect_to($parent_folder_id ? "/folders/$parent_folder_id" : '/');
}

# DELETE /api/v1/folders/:id -- Bearer-authed equivalent of the browser
# delete form above.
sub api_delete_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    # Hard by default (immediate); ?soft=1 opts a script/CLI into Trash.
    my $soft = $c->param('soft') ? 1 : 0;
    my ($deleted) = _delete_folder($c, $email, $c->param('id'), $soft);
    return $c->render(json => { error => 'not found' }, status => 404) unless $deleted;
    return $c->render(json => { ok => \1, trashed => ($soft ? \1 : \0) });
}

sub download ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;

    my $id = $c->param('id');
    my $file = $c->app->pg->db->query(
        'SELECT filename, uuid, mime_type FROM drive.files WHERE id = ? AND user_email = ?',
        $id, $email,
    )->hash;
    return $c->render(text => 'not found', status => 404) unless $file;

    my $path = $c->app->storage_path . '/' . $file->{uuid};
    return $c->render(text => 'file missing on disk', status => 404) unless -f $path;

    $c->res->headers->content_type($file->{mime_type} || 'application/octet-stream');
    $c->res->headers->content_disposition(qq{attachment; filename="} . basename($file->{filename}) . qq{"});
    return $c->reply->file($path);
}

# GET /files/:id/thumbnail and GET /files/:id/slideshow-image -- both
# serve a pre-generated JPEG derivative (see _generate_image_derivatives
# above), never the original file data, and never as an attachment (an
# <img> tag/the lightbox need these inline, not downloaded). Same
# ownership check and "someone else's id -> 404, not 403" reasoning as
# download() above. 404 for a missing derivative is expected, not an
# error -- a non-image file, a failed generation, or a file uploaded
# before this feature existed all land here, and both callers (the file
# row's thumbnail <img> and the lightbox image) have an onerror fallback
# for exactly that -- see templates/index.html.ep.
sub _serve_derivative ($c, $email, $subdir) {
    my $id   = $c->param('id');
    my $file = $c->app->pg->db->query(
        'SELECT uuid FROM drive.files WHERE id = ? AND user_email = ?', $id, $email,
    )->hash;
    return $c->render(text => 'not found', status => 404) unless $file;

    my $path = $c->app->storage_path . "/.$subdir/$file->{uuid}.jpg";
    return $c->render(text => 'not found', status => 404) unless -f $path;

    $c->res->headers->content_type('image/jpeg');
    return $c->reply->file($path);
}

sub thumbnail ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;
    return _serve_derivative($c, $email, 'thumbnails');
}

sub slideshow_image ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;
    return _serve_derivative($c, $email, 'slideshow');
}

# Shared by the browser form (delete_file()) and the JSON API
# (api_delete()) below. Returns (1, folder_id_the_file_was_in) if a
# matching file was found and deleted, (0, undef) if there was nothing
# to delete (nonexistent id, or one belonging to a different user --
# deliberately indistinguishable, same as download()'s own "not found"
# for the same reason: a bare id in a URL shouldn't confirm/deny
# another user's file exists).
# Removes a file's blob + its image derivatives from storage. Shared by
# the hard-delete path (api/cli) and the permanent-purge path (empty
# trash / retention).
sub _hard_remove_file ($c, $uuid) {
    my $path = $c->app->storage_path . '/' . $uuid;
    unlink($path) if -f $path;
    _unlink_derivatives($c, $uuid);
    return;
}

# $soft = 1 -> SOFT delete (move to Trash: set deleted_at, keep the blob
# on disk so Restore works). $soft = 0 -> HARD delete (unlink the blob +
# derivatives + drop the row), the original behavior. Only operates on a
# LIVE (not already-trashed) file; permanent removal of a trashed file
# goes through _purge_file. Returns (1, folder_id) or (0, undef).
sub _delete_file ($c, $email, $id, $soft = 0) {
    my $file = $c->app->pg->db->query(
        'SELECT uuid, folder_id FROM drive.files WHERE id = ? AND user_email = ? AND deleted_at IS NULL', $id, $email,
    )->hash;
    return (0, undef) unless $file;

    if ($soft) {
        $c->app->pg->db->query('UPDATE drive.files SET deleted_at = NOW() WHERE id = ?', $id);
    }
    else {
        $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $id);
        _hard_remove_file($c, $file->{uuid});
    }
    return (1, $file->{folder_id});
}

sub delete_file ($c) {
    my ($email, undef, $jti) = _current_auth($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $id = $c->param('id');
    # Browser delete is SOFT (goes to Trash, recoverable) -- see the
    # Trash feature in README.md.
    my ($ok, $folder_id) = _delete_file($c, $email, $id, 1);
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $jti, action => 'file.delete',
        resource_type => 'drive.file', resource_id => $id, source_service => 'homelab-drive',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
    ) if $ok;
    return $c->redirect_to($folder_id ? "/folders/$folder_id" : '/');
}

# DELETE /api/v1/files/:id -- Bearer-authed equivalent of the browser
# delete form above.
sub api_delete ($c) {
    my ($email, undef, $jti) = _current_auth($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $id = $c->param('id');
    # Hard by default (immediate); ?soft=1 opts a script/CLI into Trash.
    my $soft = $c->param('soft') ? 1 : 0;
    my ($deleted) = _delete_file($c, $email, $id, $soft);
    return $c->render(json => { error => 'not found' }, status => 404) unless $deleted;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $jti, action => 'file.delete',
        resource_type => 'drive.file', resource_id => $id, source_service => 'homelab-drive',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
    );
    return $c->render(json => { ok => \1, trashed => ($soft ? \1 : \0) });
}

# --- Bulk select: delete + zip-and-download -----------------------

# POST /bulk/delete (+ /api/v1/bulk/delete) {file_ids: [...], folder_ids: [...]}
# Both _delete_file/_delete_folder already do the real work correctly
# (DB row + on-disk blob + derivatives + ownership check, folder version
# already recursive) and are fast enough for a synchronous loop over a
# selection -- no job/worker involvement needed here at all, matching
# the approved plan: only zip-building was ever called out as
# potentially slow. Folders are processed BEFORE files (not just an
# arbitrary choice -- see README.md): a file that lives inside a
# selected folder is already gone by the time its own individual
# delete is attempted, and reports as "not_found" there -- an accepted,
# expected outcome under this file's existing indistinguishable-404
# convention, not a bug, and it makes the split deterministic regardless
# of what order the two arrays happen to list ids in.
sub bulk_delete ($c) {
    my ($email, undef, $jti) = _current_auth($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body       = $c->req->json // {};
    my $file_ids   = ref $body->{file_ids}   eq 'ARRAY' ? $body->{file_ids}   : [];
    my $folder_ids = ref $body->{folder_ids} eq 'ARRAY' ? $body->{folder_ids} : [];

    # soft_delete comes from the route default: the browser /bulk/delete
    # route sets it (delete-to-Trash); the /api/v1/bulk/delete route
    # leaves it off (immediate hard delete), matching the single-file
    # routes' browser-soft / api-hard split.
    my $soft = $c->stash('soft_delete') ? 1 : 0;

    my (@folders_deleted, @folders_not_found, @files_deleted, @files_not_found);

    for my $id (@$folder_ids) {
        my ($ok) = _delete_folder($c, $email, $id, $soft);
        push @{ $ok ? \@folders_deleted : \@folders_not_found }, $id;
    }
    for my $id (@$file_ids) {
        my ($ok) = _delete_file($c, $email, $id, $soft);
        push @{ $ok ? \@files_deleted : \@files_not_found }, $id;
    }

    if (@files_deleted || @folders_deleted) {
        enqueue(
            $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $jti, action => 'file.delete.bulk',
            resource_type => 'drive.file', source_service => 'homelab-drive',
            ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
            detail => { file_ids => \@files_deleted, folder_ids => \@folders_deleted },
        );
    }
    return $c->render(json => {
        files   => { deleted => \@files_deleted,   not_found => \@files_not_found },
        folders => { deleted => \@folders_deleted, not_found => \@folders_not_found },
        counts  => {
            deleted   => scalar(@files_deleted) + scalar(@folders_deleted),
            not_found => scalar(@files_not_found) + scalar(@folders_not_found),
        },
    });
}

# ---- Trash: restore, permanent-purge, listing (soft delete, migration 009) ----

# Un-deletes a folder's ancestor chain so a restored item lands somewhere
# reachable even if its parent folder(s) were trashed too.
sub _restore_ancestors ($c, $folder_id) {
    return unless defined $folder_id;
    $c->app->pg->db->query(
        q{WITH RECURSIVE anc AS (
            SELECT id, parent_folder_id FROM drive.folders WHERE id = ?
            UNION ALL
            SELECT f.id, f.parent_folder_id FROM drive.folders f JOIN anc a ON f.id = a.parent_folder_id
          )
          UPDATE drive.folders SET deleted_at = NULL WHERE id IN (SELECT id FROM anc) AND deleted_at IS NOT NULL},
        $folder_id);
    return;
}

sub _restore_file ($c, $email, $id) {
    my $file = $c->app->pg->db->query(
        'SELECT folder_id FROM drive.files WHERE id = ? AND user_email = ? AND deleted_at IS NOT NULL', $id, $email,
    )->hash;
    return 0 unless $file;
    $c->app->pg->db->query('UPDATE drive.files SET deleted_at = NULL WHERE id = ?', $id);
    _restore_ancestors($c, $file->{folder_id});
    return 1;
}

sub _restore_folder ($c, $email, $id) {
    my $folder = $c->app->pg->db->query(
        'SELECT id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NOT NULL', $id, $email,
    )->hash;
    return 0 unless $folder;
    _restore_ancestors($c, $id);   # the folder itself + its ancestors
    my $cte = q{WITH RECURSIVE subtree AS (
                    SELECT id FROM drive.folders WHERE id = ?
                    UNION ALL
                    SELECT f.id FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
                )};
    $c->app->pg->db->query("$cte UPDATE drive.folders SET deleted_at = NULL WHERE id IN (SELECT id FROM subtree)", $id);
    $c->app->pg->db->query("$cte UPDATE drive.files SET deleted_at = NULL WHERE folder_id IN (SELECT id FROM subtree)", $id);
    return 1;
}

# Permanent removal of a TRASHED file / folder subtree (delete-forever
# from Trash). Only ever touches already-trashed rows.
sub _purge_file ($c, $email, $id) {
    my $file = $c->app->pg->db->query(
        'SELECT uuid FROM drive.files WHERE id = ? AND user_email = ? AND deleted_at IS NOT NULL', $id, $email,
    )->hash;
    return 0 unless $file;
    $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $id);
    _hard_remove_file($c, $file->{uuid});
    return 1;
}

sub _purge_folder ($c, $email, $id) {
    my $folder = $c->app->pg->db->query(
        'SELECT id FROM drive.folders WHERE id = ? AND user_email = ? AND deleted_at IS NOT NULL', $id, $email,
    )->hash;
    return 0 unless $folder;
    my $orphaned = $c->app->pg->db->query(
        q{WITH RECURSIVE subtree AS (
            SELECT id FROM drive.folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
          )
          SELECT uuid FROM drive.files WHERE folder_id IN (SELECT id FROM subtree)},
        $id)->hashes;
    $c->app->pg->db->query('DELETE FROM drive.folders WHERE id = ?', $id);   # ON DELETE CASCADE
    _hard_remove_file($c, $_->{uuid}) for @$orphaned;
    return 1;
}

# This user's trashed files + folders, newest-deleted first.
sub _trash_contents ($c, $email) {
    my $files = $c->app->pg->db->query(
        q{SELECT id, filename, size_bytes, mime_type,
                 to_char(deleted_at, 'YYYY-MM-DD HH24:MI:SS TZ') AS deleted_at_display
          FROM drive.files WHERE user_email = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC},
        $email)->hashes;
    my $folders = $c->app->pg->db->query(
        q{SELECT id, name,
                 to_char(deleted_at, 'YYYY-MM-DD HH24:MI:SS TZ') AS deleted_at_display
          FROM drive.folders WHERE user_email = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC},
        $email)->hashes;
    return ($files, $folders);
}

# GET /trash -- browser Trash view.
sub trash ($c) {
    my $email = _current_email($c);
    return $c->redirect_to('/login') unless $email;
    my ($files, $folders) = _trash_contents($c, $email);
    return $c->render(template => 'trash', email => $email, trash_files => $files, trash_folders => $folders);
}

# GET /api/v1/trash -- JSON, for homelab-cli.
sub api_trash_list ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my ($files, $folders) = _trash_contents($c, $email);
    return $c->render(json => { files => $files, folders => $folders });
}

# :id is a BIGINT; guard the shape so a non-numeric one can't 500 the
# cast (matches nothing -> a clean 404).
sub _trash_id ($c) {
    my $id = $c->param('id') // '';
    return $id =~ /^\d{1,18}$/ ? $id : undef;
}

sub restore_file ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $id = _trash_id($c);
    return $c->render(json => { error => 'not found' }, status => 404) unless defined $id && _restore_file($c, $email, $id);
    return $c->render(json => { ok => \1 });
}

sub restore_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $id = _trash_id($c);
    return $c->render(json => { error => 'not found' }, status => 404) unless defined $id && _restore_folder($c, $email, $id);
    return $c->render(json => { ok => \1 });
}

sub purge_file ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $id = _trash_id($c);
    return $c->render(json => { error => 'not found' }, status => 404) unless defined $id && _purge_file($c, $email, $id);
    return $c->render(json => { ok => \1 });
}

sub purge_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $id = _trash_id($c);
    return $c->render(json => { error => 'not found' }, status => 404) unless defined $id && _purge_folder($c, $email, $id);
    return $c->render(json => { ok => \1 });
}

# POST /trash/empty -- permanently delete everything in this user's Trash.
sub empty_trash ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $files = $c->app->pg->db->query(
        'SELECT id, uuid FROM drive.files WHERE user_email = ? AND deleted_at IS NOT NULL', $email)->hashes;
    for my $f (@$files) {
        $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $f->{id});
        _hard_remove_file($c, $f->{uuid});
    }
    my $folders = $c->app->pg->db->query(
        'DELETE FROM drive.folders WHERE user_email = ? AND deleted_at IS NOT NULL RETURNING id', $email)->hashes;
    return $c->render(json => { ok => \1, purged => { files => scalar(@$files), folders => scalar(@$folders) } });
}

# Turns a numbered fallback path's own extension-splitting into a small
# helper: "name.ext" -> ("name", ".ext"); "name" (no dot, or a dot only
# inside an earlier path segment) -> ("name", ""). Deliberately not a
# backtracking regex trying to do this in one shot -- anchoring "the
# LAST dot, but only if it's after the last slash" cleanly needs the
# slash-aware [^.\/]+ character class either way, and doing the split as
# two plain statements is easier to get right than a single regex
# capturing both pieces at once.
sub _split_ext ($path) {
    my ($ext) = $path =~ /(\.[^.\/]+)$/;
    return (defined $ext) ? (substr($path, 0, -length($ext)), $ext) : ($path, '');
}

# Renames a zip_path on collision with a numbered suffix (e.g.
# "notes.txt" -> "notes (01).txt") -- drive.files has no
# UNIQUE(folder_id, filename), so two files can legitimately share a
# name in one folder (see README.md's manifest-resolution section), and
# the flat archive being built has no folders of its own to keep them
# apart the way the real folder tree does. $seen is shared across the
# WHOLE resolved manifest (not reset per folder), so a collision between
# two entries that came from entirely different source folders is still
# caught.
sub _dedupe_zip_path ($seen, $path) {
    unless ($seen->{$path}) {
        $seen->{$path} = 1;
        return $path;
    }
    my ($base, $ext) = _split_ext($path);
    my $n = 1;
    my $candidate;
    do {
        $candidate = sprintf('%s (%02d)%s', $base, $n, $ext);
        $n++;
    } while ($seen->{$candidate});
    $seen->{$candidate} = 1;
    return $candidate;
}

# Resolves a bulk selection (folder_ids + file_ids, both possibly empty)
# into a flat manifest of [{id, uuid, zip_path}] -- one entry per real
# file, exactly what create_zip_job below turns into a homelab-worker
# zip job's `entries`. Storage is flat (storage_path/<uuid>, see
# README.md's "Key finding" section) -- there is no on-disk folder tree
# to just archive directly, so zip_path here is what reconstructs one
# inside the finished .zip.
#
# Two real edge cases, both handled:
#  1. A folder AND a file already inside it both selected -> ONE entry,
#     folder-nested path wins. %by_id is populated from folder
#     resolution FIRST; the file-id pass below skips any id already
#     present, so an individually-selected duplicate never overwrites
#     the nested-path version.
#  2. drive.files has no UNIQUE(folder_id, filename) -- two files can
#     legitimately share a name in one folder. _dedupe_zip_path is
#     applied across the WHOLE resolved list (one shared %seen_path),
#     not just within one folder's own contents.
#
# A folder_id/file_id the caller doesn't actually own simply doesn't
# match either query's `user_email = ?` filter and is silently dropped
# -- same indistinguishable-404-style convention as every other
# ownership check in this file, not a separate error path.
sub _resolve_manifest ($c, $email, $file_ids, $folder_ids) {
    my %by_id;   # drive.files.id => {id, uuid, zip_path}

    if (@$folder_ids) {
        my $placeholders = join(',', ('?') x scalar @$folder_ids);
        my $rows = $c->app->pg->db->query(
            qq{WITH RECURSIVE subtree AS (
                SELECT id, name FROM drive.folders WHERE id IN ($placeholders) AND user_email = ? AND deleted_at IS NULL
                UNION ALL
                SELECT f.id, s.name || '/' || f.name
                FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
                WHERE f.user_email = ? AND f.deleted_at IS NULL
              )
              SELECT fi.id, fi.uuid, s.name || '/' || fi.filename AS zip_path
              FROM drive.files fi JOIN subtree s ON fi.folder_id = s.id
              WHERE fi.user_email = ? AND fi.deleted_at IS NULL},
            @$folder_ids, $email, $email, $email,
        )->hashes;
        for my $row (@$rows) {
            $by_id{ $row->{id} } = { id => $row->{id}, uuid => $row->{uuid}, zip_path => $row->{zip_path} };
        }
    }

    if (@$file_ids) {
        my $placeholders = join(',', ('?') x scalar @$file_ids);
        my $rows = $c->app->pg->db->query(
            qq{SELECT id, uuid, filename AS zip_path FROM drive.files WHERE id IN ($placeholders) AND user_email = ? AND deleted_at IS NULL},
            @$file_ids, $email,
        )->hashes;
        for my $row (@$rows) {
            next if $by_id{ $row->{id} };   # already covered via a selected ancestor folder -- nested path wins, see above
            $by_id{ $row->{id} } = { id => $row->{id}, uuid => $row->{uuid}, zip_path => $row->{zip_path} };
        }
    }

    my %seen_path;
    my @manifest;
    # Sorted by id for a deterministic archive order -- which entry
    # "wins" an unrenamed zip_path on collision is otherwise arbitrary
    # either way (both files really exist and really get archived, just
    # one of them gets the numbered-suffix name).
    for my $id (sort { $a <=> $b } keys %by_id) {
        my $entry = $by_id{$id};
        push @manifest, {
            id => $entry->{id}, uuid => $entry->{uuid},
            zip_path => _dedupe_zip_path(\%seen_path, $entry->{zip_path}),
        };
    }
    return \@manifest;
}

# Looks up homelab-worker's own address via the service registry --
# undef if it's not currently registered/reachable, same "the caller
# decides how to render that" convention as _gateway() in
# homelab-api/lib/Homelab/API/App.pm (this app has no direct in-process
# registry DB access the way homelab-api does, so it's always the real
# HTTP lookup, not a shortcut).
sub _worker_entry ($c) {
    my $entry = eval { lookup('homelab-worker', api_base => $c->app->api_base) };
    return ($entry && $entry->{host} && $entry->{port}) ? $entry : undef;
}

# Finds this user's root-level "Archives" folder, creating it on first
# use -- every completed zip job lands here (see create_zip_job below
# and _claim_and_deliver_zip_placement in the App package above). Reuses
# _create_folder's own existing-name check rather than duplicating it;
# if that check loses a create race against a concurrent first zip job
# from the same user (accepted minor race, same "soft guideline, not
# worth locking for" tone as homelab-worker's own concurrency-cap race
# -- see migrations/003-zip-placements.sql), the folder exists either
# way, so just re-fetch its id instead of failing the whole submission.
sub _ensure_archives_folder ($c, $email) {
    my $find = sub {
        return $c->app->pg->db->query(
            q{SELECT id FROM drive.folders WHERE user_email = ? AND parent_folder_id IS NULL AND name = 'Archives' AND deleted_at IS NULL},
            $email,
        )->hash;
    };
    my $existing = $find->();
    return $existing->{id} if $existing;
    my ($row) = _create_folder($c, $email, 'Archives', undef);
    return $row ? $row->{id} : $find->()->{id};
}

# POST /zip-jobs (+ /api/v1/zip-jobs) {file_ids: [...], folder_ids: [...]}
# Resolves the selection into a manifest (above), builds the generic
# zip-job payload homelab-worker expects (see ../../worker/README.md),
# and submits it with the caller's OWN forwarded JWT as every entry's
# auth_header -- explained at length in README.md's "the auth hand-off"
# section: this app has no narrower credential to hand out instead, and
# the worker fetches each entry back from THIS app's own
# /api/v1/files/:id using exactly that token, re-verified there the
# normal way. Drive itself never builds the zip -- but it DOES now
# record a drive.zip_placements row so the background timer in the App
# package above can deliver the finished artifact into this user's own
# Archives folder once the job completes; there's no live status/
# download response here any more (zip build time is unpredictable, so
# the response just names where the finished file will land -- see
# README.md's "Bulk select: zip download" section).
sub create_zip_job ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body       = $c->req->json // {};
    my $file_ids   = ref $body->{file_ids}   eq 'ARRAY' ? $body->{file_ids}   : [];
    my $folder_ids = ref $body->{folder_ids} eq 'ARRAY' ? $body->{folder_ids} : [];
    return $c->render(json => { error => 'file_ids and/or folder_ids must be provided' }, status => 400)
        unless @$file_ids || @$folder_ids;

    my $manifest = _resolve_manifest($c, $email, $file_ids, $folder_ids);
    return $c->render(json => { error => 'nothing found to zip' }, status => 400) unless @$manifest;

    my $entry = _worker_entry($c);
    return $c->render(json => { error => 'homelab-worker is not currently available' }, status => 502) unless $entry;

    (my $email_slug = $email) =~ s/[^A-Za-z0-9]+/-/g;
    my $output_name = "drive-export-$email_slug-" . time . '.zip';
    my @job_entries = map {
        {
            fetch_url   => $c->app->public_base_url . "/api/v1/files/$_->{id}",
            auth_header => "Bearer $jwt",
            zip_path    => $_->{zip_path},
        }
    } @$manifest;

    my $tx = $WORKER_UA->post(
        "http://$entry->{host}:$entry->{port}/internal/v1/jobs" => { Authorization => "Bearer $jwt" }
            => json => { type => 'zip', input => { output_name => $output_name, entries => \@job_entries } },
    );
    unless ($tx->res->code) {
        return $c->render(json => { error => 'homelab-worker is not reachable' }, status => 504);
    }
    unless ($tx->res->code == 201) {
        return $c->render(json => $tx->res->json, status => $tx->res->code);
    }
    my $job_id = $tx->res->json->{id};

    my $archives_folder_id = _ensure_archives_folder($c, $email);
    $c->app->pg->db->query(
        q{INSERT INTO drive.zip_placements (job_id, user_email, jwt, dest_folder_id, output_name, mime_type)
          VALUES (?, ?, ?, ?, ?, 'application/zip')},
        $job_id, $email, $jwt, $archives_folder_id, $output_name,
    );

    return $c->render(json => { id => $job_id, output_name => $output_name, dest_path => "Archives/$output_name" }, status => 201);
}

# POST /append-jobs (+ /api/v1/append-jobs)
#   { file_ids: [...ordered...], output_name: "...", folder_id: <dest>? }
# Reassembles several files into one, by concatenating their bytes END
# TO END in the EXACT order of file_ids given (unlike zip, order is
# load-bearing here). The caller owns the ordering policy: the web UI
# sorts the selected files alphabetically by filename before posting;
# homelab-cli passes the user's explicit order. This handler honors the
# received order verbatim -- it does NOT reuse _resolve_manifest, which
# sorts by file id.
#
# Background-job shape like create_zip_job, but the byte-work runs
# DRIVE-LOCAL, not on homelab-worker: a recurring timer (_run_append_jobs)
# claims the drive.append_jobs row this inserts and cats the already-local
# source blobs in a forked subprocess, streaming into a deterministic
# temp whose growth a heartbeat mirrors into received_bytes for the
# progress bar (GET /append-jobs/:id). The output lands in the
# caller-chosen folder_id (default: the folder the first source lives in,
# so the reassembled file appears right alongside its pieces), NOT the
# Archives folder zips use.
#
# Every requested file must be a real file this user owns: unlike zip
# (which silently drops an unowned id), a concat with a missing piece
# would produce a silently-wrong result, so any unresolved id is a hard
# 400 -- completeness and order both matter.
sub create_append_job ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body     = $c->req->json // {};
    my $file_ids = ref $body->{file_ids} eq 'ARRAY' ? $body->{file_ids} : [];
    return $c->render(json => { error => 'file_ids must list at least two files, in order' }, status => 400)
        if @$file_ids < 2;

    # Resolve every id to its (uuid, filename, folder_id), scoped to the
    # owner, then re-order the rows back into the caller's given order.
    my $placeholders = join(',', ('?') x scalar @$file_ids);
    my $rows = $c->app->pg->db->query(
        qq{SELECT id, uuid, filename, folder_id, size_bytes FROM drive.files WHERE id IN ($placeholders) AND user_email = ? AND deleted_at IS NULL},
        @$file_ids, $email,
    )->hashes->to_array;
    my %by_id = map { $_->{id} => $_ } @$rows;

    my @ordered;
    my $combined_size = 0;
    for my $id (@$file_ids) {
        my $r = $by_id{$id}
            or return $c->render(json => { error => "file $id not found (or not yours) -- every piece must exist to combine" }, status => 400);
        push @ordered, $r;
        $combined_size += $r->{size_bytes} // 0;
    }

    # Quota: the combined file is a NEW blob (~sum of the pieces), added on
    # top of the pieces that already count -- refuse if it wouldn't fit.
    return $c->render(json => { error => 'combined file would exceed your storage quota' }, status => 413)
        if _quota_would_exceed($c, $email, $combined_size);

    # Default the output name off the first piece with a trailing split
    # suffix stripped (bigfile.iso.001 -> bigfile.iso, bigfile.part1 ->
    # bigfile), else a timestamped fallback. Basename-only, never a path.
    my $output_name = $body->{output_name};
    if (!defined $output_name || $output_name !~ /\S/) {
        ($output_name = $ordered[0]{filename}) =~ s/\.(?:\d+|part\d+|[a-z]{2})$//i;
        $output_name = 'combined-' . time unless length $output_name;
    }
    $output_name =~ s{.*/}{};

    # Destination folder: caller-chosen (validated) or the first piece's
    # own folder so the result appears next to its pieces.
    my $dest_folder_id;
    if (defined $body->{folder_id} && $body->{folder_id} ne '') {
        my $folder = _owned_folder($c, $email, $body->{folder_id});
        return $c->render(json => { error => 'destination folder not found' }, status => 400) unless $folder;
        $dest_folder_id = $folder->{id};
    }
    else {
        $dest_folder_id = $ordered[0]{folder_id};
    }

    # Queue a drive-LOCAL append job (see migrations/005-append-jobs.sql
    # for why this is on-host, not offloaded to homelab-worker): the
    # source blobs already live under storage_path here, so the recurring
    # timer's forked subprocess just cats them in order into a new blob.
    # source_uuids captured in the caller's exact order.
    my @source_uuids = map { $_->{uuid} } @ordered;
    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.append_jobs (user_email, source_uuids, output_name, dest_folder_id)
          VALUES (?, ?, ?, ?) RETURNING id},
        $email, { -json => \@source_uuids }, $output_name, $dest_folder_id,
    )->hash;

    return $c->render(json => { id => $row->{id}, output_name => $output_name }, status => 202);
}

# GET /append-jobs/:id (+ /api/v1): status of a drive-local concat job,
# owner-scoped. Reports state (pending|processing|completed|failed), live
# byte progress (received_bytes/total_bytes, kept fresh by the heartbeat
# in _run_append_jobs), the finished file_id once completed, and the
# error on failure -- so a slow combine shows progress and a failed one
# is actually surfaced instead of a file that silently never appears.
sub get_append_job ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    # append_jobs.id is a BIGINT; guard the shape so a non-numeric :id
    # can't 500 the cast (matches nothing -> 404 instead).
    my $id = $c->stash('id') // '';
    return $c->render(json => { error => 'append job not found' }, status => 404) unless $id =~ /^\d{1,18}$/;

    my $job = $c->app->pg->db->query(
        q{SELECT id, state, output_name, total_bytes, received_bytes, result_file_id, error_message
          FROM drive.append_jobs WHERE id = ? AND user_email = ?},
        $id, $email)->hash;
    return $c->render(json => { error => 'append job not found' }, status => 404) unless $job;

    return $c->render(json => {
        id             => $job->{id} + 0,
        state          => $job->{state},
        output_name    => $job->{output_name},
        received_bytes => ($job->{received_bytes} // 0) + 0,
        total_bytes    => (defined $job->{total_bytes} ? $job->{total_bytes} + 0 : undef),
        file_id        => $job->{result_file_id},
        error          => $job->{error_message},
    });
}

# GET /zip-jobs/:id (+ /api/v1): status of a zip export, owner-scoped.
# :id is the homelab-worker job id create_zip_job returned. A zip's life
# spans TWO systems -- the worker BUILDS it, then a drive timer DELIVERS
# it into Archives -- so this collapses both into one phase the client
# can act on: queued | building (with N-of-M entry progress from the
# worker) | delivering | completed (with the file id) | failed (with the
# reason). Before this, a failed build/delivery was invisible and the
# browser just said "check back in Archives".
sub get_zip_job ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $id = $c->stash('id') // '';   # worker job id, a BIGINT
    return $c->render(json => { error => 'zip job not found' }, status => 404) unless $id =~ /^\d{1,18}$/;

    my $p = $c->app->pg->db->query(
        q{SELECT job_id, state, output_name, result_file_id, error_message, jwt
          FROM drive.zip_placements WHERE job_id = ? AND user_email = ?},
        $id, $email)->hash;
    return $c->render(json => { error => 'zip job not found' }, status => 404) unless $p;

    my $dest_path = "Archives/$p->{output_name}";
    if ($p->{state} eq 'completed') {
        return $c->render(json => {
            id => $p->{job_id} + 0, state => 'completed',
            output_name => $p->{output_name}, dest_path => $dest_path, file_id => $p->{result_file_id},
        });
    }
    if ($p->{state} eq 'failed') {
        return $c->render(json => {
            id => $p->{job_id} + 0, state => 'failed',
            output_name => $p->{output_name}, error => $p->{error_message},
        });
    }

    # Placement not yet delivered -- consult the worker to distinguish
    # "still building" (with progress) from "built, delivery pending".
    my %resp = (id => $p->{job_id} + 0, state => 'queued', output_name => $p->{output_name}, dest_path => $dest_path);
    my $entry = _worker_entry($c);
    if ($entry) {
        # Short-timeout UA (see $WORKER_STATUS_UA) so a hung worker can't
        # freeze this event loop on a browser poll.
        my $tx = $WORKER_STATUS_UA->get(
            "http://$entry->{host}:$entry->{port}/internal/v1/jobs/$p->{job_id}"
                => { Authorization => "Bearer $p->{jwt}" });
        if ($tx->res->code && $tx->res->code == 200) {
            my $wj = $tx->res->json;
            if (($wj->{state} // '') eq 'failed') {
                $resp{state} = 'failed';
                $resp{error} = 'zip build failed: ' . ($wj->{error_message} // 'unknown error');
            }
            elsif (($wj->{state} // '') eq 'completed') {
                $resp{state} = 'delivering';   # built; the drive timer will place it into Archives shortly
            }
            else {
                $resp{state} = 'building';
                $resp{progress_current} = $wj->{progress_current} + 0 if defined $wj->{progress_current};
                $resp{progress_total}   = $wj->{progress_total} + 0   if defined $wj->{progress_total};
            }
        }
        # If the worker 404s the job (expired/swept) while the placement
        # is still undelivered, we leave state 'queued' -- the delivery
        # timer will either deliver it or mark the placement failed, and
        # the next poll reflects that. Avoids a false 'failed' on a
        # transient worker blip.
    }
    return $c->render(json => \%resp);
}

1;
