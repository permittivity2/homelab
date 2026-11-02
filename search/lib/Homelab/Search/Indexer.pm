package Homelab::Search::Indexer;
use Mojo::Base -base, -signatures;

use Sys::Hostname qw(hostname);
use Mojo::Pg;
use Homelab::Search::Index;
use Homelab::Search::MailParse qw(parse_message parse_maildir_name);
use Homelab::Search::Paths     qw(maildir_for mailbox_dir_for drive_blob_for);
use Homelab::Search::Extract   qw(extract best_created_at EXTRACTOR_VERSION);

has 'pg';
has 'drive_pg';          # separate handle: the drive schema is another role's
has 'config';
has 'log';
has 'index';
has host         => sub { hostname() };
has mail_root    => '/srv/mail-ro';
has drive_root   => '/srv/drive-ro';
# How many metadata-stale files to re-queue per discovery pass. See (2b).
has stale_batch  => 400;
has lease_secs   => 300;
has max_attempts => 5;
has batch_size   => 200;
# How often a full drive reconcile runs. The watermark and the deleted-state
# check handle the common cases; this is the net for the rest.
has reconcile_interval => 3600;

# A long-running service on each of the three search hosts. ALL THREE INDEX;
# none sits idle.
#
# DISCOVERY IS SINGLE-FLIGHT, EXECUTION IS SHARED. One host takes a Postgres
# advisory lock, does the cheap scan, enqueues work, and releases; every host
# then pulls units off search.index_queue with FOR UPDATE SKIP LOCKED. That
# split is deliberate: the scan is a few hundred stat() calls and
# parallelising it only risks duplicate enqueues, while the per-unit work is
# where the time goes.
#
# Per-user or per-directory sharding was considered and rejected on the data:
# drive has two users, so any per-user split hands one host the entire drive
# corpus and leaves two idle. SKIP LOCKED balances itself with no ownership
# map and returns a dead host's unit to the pool when its lease expires.
#
# WHY NOT inotify. The mail and drive files are written by the dovecot and
# drive nodes; NFS does not deliver inotify events for changes made by
# another client, so a watch here would sit silent forever while mail
# arrived. Mail is polled by maildir directory mtime (one stat per mailbox
# decides whether to list it) and drive is polled from its own database,
# which is exact.

use constant DISCOVERY_LOCK => 918_273_641;   # arbitrary but fixed

# Every read of the search schema must run inside a transaction marked
# `homelab.indexer = 'on'`, because row-level security otherwise scopes each
# table to one account and an unset homelab.account_id matches nothing.
#
# This was a real bug, and an instructive one: _do_mailbox looked its mailbox
# up on a bare handle, got zero rows, and reported "mailbox N is gone" -- so
# 124 units parked against mailboxes that existed and were merely invisible.
# The error message was confidently wrong, which is worse than a crash.
#
# set_config's third argument is is_local = true, i.e. SET LOCAL: the setting
# dies with the transaction. A session-level SET would be shorter and is the
# wrong choice -- it would persist on the pooled server connection, where the
# web app could inherit cross-account visibility if pgbouncer's reset query
# ever changed. The whole point of the indexer having its own door rather than
# BYPASSRLS is that the application cannot walk through it.
sub _tx ($self, $cb) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my @r = $cb->($db);
    $tx->commit;
    return wantarray ? @r : $r[0];
}

sub new_from_config ($class, $config, $log) {
    my $pg = Mojo::Pg->new->dsn(sprintf('dbi:Pg:dbname=%s;host=%s;port=%s',
                                        $config->{database}{name},
                                        $config->{database}{host},
                                        $config->{database}{port}))
                          ->username($config->{database}{user})
                          ->password($config->{database}{password});
    my $self = $class->new(pg => $pg, config => $config, log => $log);
    $self->index(Homelab::Search::Index->new(pg => $pg, log => $log));
    $self->mail_root($config->{mail_root})   if $config->{mail_root};
    $self->drive_root($config->{drive_root}) if $config->{drive_root};

    if (my $d = $config->{drive_database}) {
        $self->drive_pg(Mojo::Pg->new
            ->dsn(sprintf('dbi:Pg:dbname=%s;host=%s;port=%s', $d->{name}, $d->{host}, $d->{port}))
            ->username($d->{user})->password($d->{password}));
    }
    return $self;
}

# --------------------------------------------------------------- discovery
# TRANSACTION-scoped advisory lock, not session-scoped, and that distinction
# is the whole point.
#
# The first version used pg_try_advisory_lock + an explicit pg_advisory_unlock.
# Behind pgbouncer that leaks: the lock lives on the SERVER session, and if the
# holder dies between the two calls -- or the unlock never runs for any reason
# -- pgbouncer keeps that server connection alive and the lock is held by an
# idle backend forever. Observed exactly that: one idle connection holding
# objid 918273641 for minutes while every host logged "another host is
# discovering; skipping" and no discovery ran at all. Nothing recovers from
# that on its own.
#
# pg_try_advisory_xact_lock is released by COMMIT or ROLLBACK, including the
# implicit rollback when a backend dies. There is no unlock call to misroute
# and no state to leak. The transaction here does no writes -- it exists only
# to scope the lock -- so it ends in rollback; the actual upserts run on their
# own pooled connections via Index::_tx.
# NOTE ON ENDING THE TRANSACTION: Mojo::Pg::Transaction (4.28) has commit(),
# db(), new() and DESTROY -- and NO rollback() method. A transaction that is
# not committed is rolled back by its destructor when it goes out of scope, so
# the lock is released by letting $tx fall out of the block below, not by
# calling rollback on it. Calling $tx->rollback dies with "Can't locate object
# method", and because the enqueues happen BEFORE that line the symptom was
# subtle: discovery did its work, then threw, the caller logged the error, and
# the advisory lock lingered until garbage collection -- which looked exactly
# like healthy single-flight contention ("another host is discovering") on
# every host.
sub discover ($self) {
    my $db = $self->pg->db;
    my ($got, $n, $err) = (0, 0, undef);
    {
        my $tx = $db->begin;
        $got = $db->query('SELECT pg_try_advisory_xact_lock(?) AS ok', DISCOVERY_LOCK)->hash->{ok};
        if ($got) {
            eval { $n = $self->_discover_mail + $self->_discover_drive; 1 } or $err = $@ || 'discovery failed';
        }
    }   # $tx destroyed here -> ROLLBACK -> the xact lock is released
    unless ($got) {
        $self->log->debug('another host is discovering; skipping');
        return 0;
    }
    die $err if defined $err;
    return $n;
}

# One stat per mailbox decides whether to enqueue it. A maildir's cur/ and
# new/ mtime changes when a file is added or removed, so this is a few
# hundred syscalls across the whole fleet.
sub _discover_mail ($self) {
    my $root = $self->mail_root;
    my $enq  = 0;

    opendir(my $rh, $root) or do {
        $self->log->warn("cannot read the mail root $root: $! -- NO mail will be indexed."
            . " The indexer must run as uid 5000 (vmail); by hand that means"
            . " `sudo -u vmail -g vmail`, not `sudo -u homelab`.");
        return 0;
    };
    my @domains = grep { !/^\./ && -d "$root/$_" } readdir $rh;
    closedir $rh;

    for my $domain (sort @domains) {
        opendir(my $dh, "$root/$domain") or next;
        my @users = grep { !/^\./ && -d "$root/$domain/$_" } readdir $dh;
        closedir $dh;

        for my $user (sort @users) {
            my $email = lc "$user\@$domain";
            my $acct  = $self->index->upsert_account($email, has_mail => 1) or next;
            my $adir  = eval { maildir_for($root, $domain, $user) };
            unless ($adir) {
                $self->log->warn("cannot resolve a maildir for $email: $@");
                next;
            }

            # INBOX is the account root in Maildir++; named folders are
            # dot-prefixed siblings.
            my @boxes = ('INBOX');
            # An UNREADABLE account must be loud. This was `or next`, which
            # discarded EACCES without a word -- so five accounts whose
            # directories dovecot had created 0700 were skipped entirely and
            # the only symptom was a count that looked complete. A gap you
            # cannot see is worse than a crash.
            my $ah;
            unless (opendir($ah, $adir)) {
                $self->log->warn("cannot read the maildir for $email ($adir): $!"
                    . " -- this account will NOT be indexed");
                next;
            }
            push @boxes, grep { /^\./ && $_ ne '.' && $_ ne '..' && -d "$adir/$_" } readdir $ah;
            closedir $ah;

            for my $box (@boxes) {
                my $mid = $self->index->mailbox_id($acct, $box) or next;
                my $newest = 0;
                for my $sub (qw(cur new)) {
                    my $d = eval { mailbox_dir_for($root, $domain, $user, $box, $sub) } or next;
                    my @st = stat($d) or next;
                    $newest = $st[9] if $st[9] > $newest;
                }
                next unless $newest;
                my $seen = $self->index->mailbox_mtime($mid);
                next if defined $seen && $seen >= $newest;
                $enq += $self->_enqueue(kind => 'mailbox', account_id => $acct, mailbox_id => $mid);
            }
        }
    }
    return $enq;
}

# Drive is polled from its own database rather than by walking the storage
# directory. That is both exact (deletions and restores are visible) and the
# only way that respects the rule in Homelab::Search::Paths: the storage
# directory is never enumerated, and a blob is only opened for a uuid a
# user_email-scoped query just returned.
#
# THREE QUERIES, NOT ONE SWEEP. The first version selected every row of
# drive.files on every pass and enqueued all ~153 batches again, so the queue
# grew without bound and mail indexing starved behind the churn while the
# drive counts sat at a complete-looking 30,497. The fix is a watermark plus
# two targeted checks, with a full sweep only on a slow timer:
#
#   1. id > watermark          -- new uploads. drive ids only increase.
#   2. deleted-state mismatch  -- a file drive says is deleted that the index
#                                 still shows live, or vice versa. Both sets
#                                 are small, and this is what makes a trashed
#                                 file leave the index on the NEXT pass rather
#                                 than whenever a reconcile happens to run.
#   3. full sweep              -- every reconcile_interval (default 1h), to
#                                 catch anything the first two cannot see,
#                                 such as a rename or a changed mime type.
sub _discover_drive ($self) {
    my $dpg = $self->drive_pg or return 0;
    my $enq = 0;

    my $now  = time;
    my $last = $self->index->meta_get('drive_last_reconcile') // 0;
    my $reconcile = ($now - $last) >= $self->reconcile_interval ? 1 : 0;

    my @ids;

    # (1) New uploads. drive ids only increase, so anything above the
    #     watermark has never been seen.
    my $mark = $self->index->drive_watermark;
    my $new  = eval { $dpg->db->query('SELECT id FROM drive.files WHERE id > ? ORDER BY id', $mark)->hashes };
    unless ($new) { $self->log->warn("drive discovery failed: $@"); return 0 }
    push @ids, map { $_->{id} } @$new;

    # (2) Deleted or restored. The id does not change, so the watermark cannot
    #     see these -- and a trashed file must stop appearing in search on the
    #     next pass, not whenever a reconcile happens to run.
    my $live = $self->index->live_drive_ids;
    my $gone = eval { $dpg->db->query('SELECT id FROM drive.files WHERE deleted_at IS NOT NULL')->hashes } // [];
    my %gone_id;
    for my $r (@$gone) {
        $gone_id{ $r->{id} } = 1;
        push @ids, $r->{id} if $live->{ $r->{id} };          # index still thinks it is live
    }
    my $idx_dead = eval {
        $self->index->_tx(sub ($db) {
            $db->query(q{SELECT drive_file_id FROM search.drive_items
                          WHERE deleted_at IS NOT NULL AND drive_file_id IS NOT NULL})->hashes;
        });
    } // [];
    for my $r (@$idx_dead) {
        push @ids, $r->{drive_file_id} unless $gone_id{ $r->{drive_file_id} };   # restored
    }

    # (2a) Files whose SEARCHABILITY disagrees with drive.
    #
    #      Marking a folder non-searchable has to take effect on the next
    #      pass, not whenever that file happens to be touched again --
    #      otherwise someone ticks the box, nothing changes, and they
    #      reasonably conclude it is broken. Same shape as the deleted
    #      check above: compare the two sides and enqueue the difference.
    my $exdrive = eval {
        $dpg->db->query(q{
            WITH RECURSIVE excluded AS (
                SELECT id FROM drive.folders WHERE exclude_from_search
                UNION
                SELECT c.id FROM drive.folders c JOIN excluded e ON c.parent_folder_id = e.id
            )
            SELECT id FROM drive.files
             WHERE exclude_from_search
                OR folder_id IN (SELECT id FROM excluded)})->hashes } // [];
    my %want_hidden = map { $_->{id} => 1 } @$exdrive;
    my $idx_state = eval {
        $self->index->_tx(sub ($db) {
            $db->query(q{SELECT drive_file_id, searchable FROM search.drive_items
                          WHERE drive_file_id IS NOT NULL AND deleted_at IS NULL})->hashes })
    } // [];
    for my $r (@$idx_state) {
        my $is_hidden = $r->{searchable} ? 0 : 1;
        my $should    = $want_hidden{ $r->{drive_file_id} } ? 1 : 0;
        push @ids, $r->{drive_file_id} if $is_hidden != $should;
    }

    # (2b) Files whose metadata predates the current extractor.
    #
    #      This is what makes adding a tag or fixing a transform cheap:
    #      bump Extract::EXTRACTOR_VERSION and the next pass re-queues
    #      exactly the files below it, in id order, draining through the
    #      existing work queue. No migration and no flag day.
    #
    #      Every file is stamped once, text files included -- they have no
    #      metadata to extract, but stamping them is what stops them being
    #      re-queued on every subsequent pass. So the first run after a
    #      bump walks the whole corpus once and then goes quiet, rather
    #      than the ~115 files that actually yield anything.
    #
    #      CAPPED PER PASS on purpose. A version bump makes every file
    #      stale at once, and enqueuing 30k units in one go is the
    #      starvation this function's section (3) exists to avoid. A few
    #      hundred per pass drains in minutes and leaves mail indexing
    #      alive throughout.
    my $stale = eval {
        $self->index->_tx(sub ($db) {
            $db->query(q{SELECT drive_file_id FROM search.drive_items
                          WHERE deleted_at IS NULL AND drive_file_id IS NOT NULL
                            AND (extractor_version IS NULL OR extractor_version < ?)
                          ORDER BY drive_file_id LIMIT ?},
                       Homelab::Search::Extract::EXTRACTOR_VERSION, $self->stale_batch)->hashes;
        });
    } // [];
    if (@$stale) {
        $self->log->info(sprintf 'drive: %d file(s) below extractor v%d, re-queuing',
                         scalar @$stale, Homelab::Search::Extract::EXTRACTOR_VERSION);
        push @ids, map { $_->{drive_file_id} } @$stale;
    }

    # (3) The slow net: a SET DIFFERENCE, not a re-index.
    #
    #     This deliberately enqueues NOTHING when the index is in sync. The
    #     first version re-enqueued every file on a timer, which meant the
    #     same 30k rows were re-upserted forever and mail indexing starved
    #     behind the churn -- and because the drive counts looked complete,
    #     nothing about it appeared wrong. A file in drive is immutable after
    #     upload apart from deleted_at (there is no rename endpoint), so
    #     "already indexed" really does mean "nothing to do".
    if ($reconcile) {
        my $all = eval { $dpg->db->query('SELECT id FROM drive.files')->hashes };
        if ($all) {
            my $have = $self->index->all_drive_ids;
            my %in_drive;
            my @missing;
            for my $r (@$all) {
                $in_drive{ $r->{id} } = 1;
                push @missing, $r->{id} unless $have->{ $r->{id} };
            }
            my @purged = grep { !$in_drive{$_} } keys %$have;
            push @ids, @missing;
            if (@purged) {
                my $d = $self->index->delete_drive_items([@purged]);
                $self->log->info("drive reconcile: dropped $d index row(s) for purged file(s)");
            }
            $self->index->meta_set('drive_last_reconcile', $now);
            $self->log->info(sprintf('drive reconcile: %d in drive, %d indexed, %d missing, %d purged',
                scalar @$all, scalar(keys %$have), scalar @missing, scalar @purged));
        }
        else { $self->log->warn("drive reconcile failed: $@") }
    }

    my %seen; @ids = grep { defined $_ && !$seen{$_}++ } @ids;
    $self->log->debug('drive: ' . scalar(@ids) . " change(s) to index") if @ids;

    return 0 unless @ids;

    # Group by owner so a batch belongs to one account, which keeps the
    # account_id on the queue row meaningful.
    my $ph = join ',', map { '?' } @ids;
    my $own = eval { $dpg->db->query("SELECT id, user_email FROM drive.files WHERE id IN ($ph)", @ids)->hashes };
    unless ($own) { $self->log->warn("drive owner lookup failed: $@"); return 0 }

    my %by_account;
    for my $r (@$own) {
        my $acct = $self->index->upsert_account(lc $r->{user_email}, has_drive => 1) or next;
        push @{ $by_account{$acct} }, $r->{id};
    }
    for my $acct (sort keys %by_account) {
        my @a = @{ $by_account{$acct} };
        while (my @chunk = splice @a, 0, $self->batch_size) {
            $enq += $self->_enqueue(kind => 'drive_batch', account_id => $acct, file_ids => \@chunk);
        }
    }
    return $enq;
}

# Idempotent enqueue. "Already queued" must include units that are IN FLIGHT,
# not just unclaimed ones.
#
# The first version checked `claimed_by IS NULL`, which meant: host A claims
# mailbox 5, the next discovery pass does not see a free unit for mailbox 5 and
# enqueues another, host B claims that one, and both index the same maildir at
# once -- producing
#   duplicate key value violates unique constraint "message_files_mailbox_id_uniq_part_key"
# and parking 18 mailboxes. Dropping the claimed_by condition is the actual
# fix; _do_mailbox tolerating the collision (below) is the belt to this braces,
# because a lease can still expire under a slow worker.
sub _enqueue ($self, %a) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my $dup = $db->query(q{
        SELECT 1 FROM search.index_queue
         WHERE kind = ? AND account_id = ? AND coalesce(mailbox_id, -1) = coalesce(?, -1)
           AND parked = FALSE
         LIMIT 1}, $a{kind}, $a{account_id}, $a{mailbox_id})->hash;
    if ($dup && $a{kind} eq 'mailbox') { $tx->commit; return 0 }

    $db->query(q{
        INSERT INTO search.index_queue (kind, account_id, mailbox_id, file_ids)
        VALUES (?, ?, ?, ?)},
        $a{kind}, $a{account_id}, $a{mailbox_id},
        ($a{file_ids} ? '{' . join(',', @{ $a{file_ids} }) . '}' : undef));
    $tx->commit;
    return 1;
}

# ------------------------------------------------------------------- claim
sub claim ($self) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my $row = $db->query(q{
        UPDATE search.index_queue q
           SET claimed_by = ?, claimed_at = NOW(),
               lease_until = NOW() + (? || ' seconds')::interval,
               attempts = attempts + 1
         WHERE queue_id = (
               SELECT queue_id FROM search.index_queue
                WHERE parked = FALSE
                  AND (claimed_by IS NULL OR lease_until < NOW())
                ORDER BY priority, enqueued_at
                  FOR UPDATE SKIP LOCKED
                LIMIT 1)
        RETURNING *}, $self->host, $self->lease_secs)->hash;
    $tx->commit;
    return $row;
}

sub _finish ($self, $queue_id) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    $db->query('DELETE FROM search.index_queue WHERE queue_id = ?', $queue_id);
    $tx->commit;
}

# A unit that keeps failing is PARKED with its error rather than retried
# forever. One malformed message or one extractor that dies must not sit at
# the head of the queue blocking everything behind it.
sub _fail ($self, $row, $err) {
    chomp(my $msg = "$err");
    my $park = $row->{attempts} >= $self->max_attempts ? 1 : 0;
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    $db->query(q{
        UPDATE search.index_queue
           SET claimed_by = NULL, lease_until = NULL, last_error = ?, parked = ?
         WHERE queue_id = ?}, substr($msg, 0, 2000), $park, $row->{queue_id});
    $tx->commit;
    $self->log->error(sprintf('unit %s (%s) failed%s: %s',
        $row->{queue_id}, $row->{kind}, ($park ? ' and was PARKED' : ''), $msg));
}

sub run_unit ($self, $row) {
    my $items = eval {
          $row->{kind} eq 'mailbox'     ? $self->_do_mailbox($row)
        : $row->{kind} eq 'drive_batch' ? $self->_do_drive_batch($row)
        :                                 die "unknown unit kind '$row->{kind}'\n";
    };
    if ($@) { $self->_fail($row, $@); return (0, 1) }
    $self->_finish($row->{queue_id});
    return ($items // 0, 0);
}

# ---------------------------------------------------------------- mailbox
sub _do_mailbox ($self, $row) {
    my $info = $self->_tx(sub ($db) {
        $db->query(q{
            SELECT a.account_id, a.local_part, d.domain, m.name AS mailbox, m.mailbox_id
              FROM search.mailboxes m
              JOIN search.accounts a ON a.account_id = m.account_id
              JOIN search.domains  d ON d.domain_id  = a.domain_id
             WHERE m.mailbox_id = ?}, $row->{mailbox_id})->hash;
    }) or die "mailbox $row->{mailbox_id} not found in the index\n";

    my $known   = $self->index->known_files($info->{mailbox_id});
    my $indexed = 0;
    my @present;
    my $newest  = 0;

    # Did we actually see everything? A mailbox is two directories, `cur`
    # holding read mail -- nearly all of it -- and `new` holding the unread.
    # @present is built from both and then used to decide what has been
    # DELETED, so a directory we failed to enumerate must stop that decision
    # being made at all. It used to `next` and fall through, which meant an
    # unreadable `cur` looked exactly like an empty one and every read
    # message was removed from the index, with the unit recorded as a
    # success. The store is read-only so no mail was ever at risk, but it
    # vanished from search until something unrelated touched the folder --
    # and the trigger is a momentary ESTALE or EACCES on the NAS, which is
    # routine.
    #
    # A partial view is not evidence of deletion. It is evidence of nothing.
    my $partial = 0;

    for my $sub (qw(cur new)) {
        my $dir = eval {
            mailbox_dir_for($self->mail_root, $info->{domain}, $info->{local_part},
                            $info->{mailbox}, $sub)
        };
        # Could not even work out the path: we have enumerated nothing here.
        unless (defined $dir) { $partial = 1; next }

        # ABSENT AND UNREADABLE ARE DIFFERENT THINGS, and the whole fix turns
        # on the distinction. Plenty of mailboxes have only one of the two
        # directories, and treating that as a failure would park every one of
        # them. A directory that EXISTS and cannot be read is the dangerous
        # case, and the only one that sets $partial.
        unless (-e $dir) { next }

        my @st = stat($dir);
        unless (@st) {
            $self->log->warn("cannot stat $dir: $!");
            $partial = 1;
            next;
        }
        $newest = $st[9] if $st[9] > $newest;

        my $dh;
        unless (opendir($dh, $dir)) {
            $self->log->warn("cannot read $dir: $!");
            $partial = 1;
            next;
        }
        while (defined(my $name = readdir $dh)) {
            next if $name =~ /^\./;
            my $path = "$dir/$name";
            my @fst  = stat($path) or next;
            next unless -f _;

            my $fl = parse_maildir_name($name);
            push @present, $fl->{uniq_part};
            my $file = {
                %$fl, sub => $sub, file_name => $name,
                size => $fst[7], mtime => $fst[9], inode => $fst[1],
            };

            # Already known: a flag change renames the file without changing
            # uniq_part, so this is a one-column update, NOT a re-index.
            # Getting this wrong re-indexes a whole mailbox every time
            # someone reads their mail.
            if (my $prev = $known->{ $fl->{uniq_part} }) {
                $self->index->touch_file($prev->{message_id}, $file)
                    if $prev->{file_name} ne $name;
                next;
            }

            open(my $fh, '<', $path) or next;
            binmode $fh;
            local $/ = undef;
            my $raw = <$fh>;
            close $fh;

            my $parsed = parse_message($raw, { size => $fst[7], mtime => $fst[9] });
            unless ($parsed) {
                # Metadata-only rather than skipped: a message that will not
                # parse should still be findable by its file and date.
                $self->log->warn("unparseable: $path");
                $parsed = {
                    subject => undef, body_text => '', addresses => {}, headers => {},
                    attachments => [], has_attachments => 0,
                    size_bytes => $fst[7], received_at => $fst[9], sent_at => $fst[9],
                };
            }
            # A unique violation on (mailbox_id, uniq_part) means another worker
            # indexed this message first -- which is a success, not an error.
            # index_message runs in its own transaction, so the failed attempt
            # leaves nothing behind. Anything else is a real failure and is
            # re-thrown so the unit retries and eventually parks.
            my $okmsg = eval {
                $self->index->index_message(
                    account_id => $info->{account_id}, mailbox_id => $info->{mailbox_id},
                    parsed => $parsed, file => $file);
                1;
            };
            if (!$okmsg) {
                my $e = $@ // '';
                die $e unless $e =~ /duplicate key value|unique constraint/i;
                $self->log->debug("already indexed by another worker: $fl->{uniq_part}");
                next;
            }
            $indexed++;
        }
        closedir $dh;
    }

    # A directory we could not read means we do not know what is gone, so we
    # neither delete nor advance the watermark -- advancing it would stop
    # discovery coming back. Dying hands the unit to run_unit's eval, which
    # calls _fail: the error is recorded, the attempt counted, and the unit
    # retried and eventually parked. That is visible, which a silent wipe
    # was not.
    if ($partial) {
        die "mailbox $info->{mailbox} for $info->{local_part}\@$info->{domain}: "
          . "a message directory could not be read -- refusing to treat an "
          . "unreadable directory as an empty one\n";
    }

    # Anything we previously knew and did not see is gone from the store.
    my %seen = map { $_ => 1 } @present;
    my @gone = map { $known->{$_}{message_id} } grep { !$seen{$_} } keys %$known;
    $self->index->delete_messages(\@gone) if @gone;

    $self->index->set_mailbox_mtime($info->{mailbox_id}, $newest) if $newest;
    return $indexed;
}

# ------------------------------------------------------------ drive batch
has _created_col => undef;

sub _drive_created_col ($self, $dpg) {
    return $self->_created_col if defined $self->_created_col;
    my $has = eval {
        $dpg->db->query(q{
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'drive' AND table_name = 'files'
               AND column_name = 'content_created_at'})->hash;
    };
    my $col = $has ? 'f.content_created_at' : 'NULL::timestamptz';
    $self->log->info("drive.files.content_created_at: " . ($has ? 'present' : 'absent, falling back to NULL'))
        if $self->log;
    $self->_created_col($col);
    return $col;
}

sub _do_drive_batch ($self, $row) {
    my $dpg = $self->drive_pg or die "no drive database configured\n";
    my $ids = $row->{file_ids};
    # Mojo::Pg hands a Postgres array back as a plain string like '{1,2,3}'.
    $ids = [ grep { length } split /,/, ($ids =~ s/^\{|\}$//gr) ] unless ref $ids;
    return 0 unless @$ids;

    # content_created_at arrives with drive's migration 012. Detected once
    # rather than assumed, so this indexer runs against a drive that has not
    # been upgraded yet instead of erroring on every batch. The two possible
    # values are fixed literals in this file -- nothing from a row or a
    # request reaches the SQL text.
    my $created = $self->_drive_created_col($dpg);

    my $ph = join ',', map { '?' } @$ids;
    # `excluded` walks the folder tree UPWARDS: a file is non-searchable if
    # its own folder is marked, or ANY folder above it is. Folders nest,
    # and a folder inside Private is private -- anything else would be a
    # trap. Computed in one recursive CTE per batch rather than per file.
    my $rows = $dpg->db->query(qq{
        WITH RECURSIVE excluded AS (
            SELECT id FROM drive.folders WHERE exclude_from_search
            UNION
            SELECT c.id FROM drive.folders c JOIN excluded e ON c.parent_folder_id = e.id
        )
        SELECT f.id, f.user_email, f.filename, f.uuid::text AS uuid, f.size_bytes,
               f.mime_type, f.uploaded_at, f.deleted_at,
               $created AS content_created_at,
               fo.name AS folder_name,
               (f.exclude_from_search
                OR (f.folder_id IS NOT NULL
                    AND f.folder_id IN (SELECT id FROM excluded))) AS excluded
          FROM drive.files f
          LEFT JOIN drive.folders fo ON fo.id = f.folder_id
         WHERE f.id IN ($ph)}, @$ids)->hashes;

    my $n = 0;
    for my $r (@$rows) {
        my $acct = $self->index->upsert_account(lc $r->{user_email}, has_drive => 1) or next;
        my ($text, $meta);
        my $mime = lc($r->{mime_type} // '');
        my $path = $r->{deleted_at} ? undef
                 : eval { drive_blob_for($self->drive_root, $r->{uuid}) };

        if ($path && -r $path) {
            # Text gets its body indexed, as before.
            if ($mime =~ m{^text/} && ($r->{size_bytes} // 0) <= 8 * 1024 * 1024) {
                if (open(my $fh, '<', $path)) {
                    binmode $fh;
                    read $fh, my $buf, 1024 * 1024;
                    close $fh;
                    $text = $buf;
                    $text =~ s/\0//g;
                }
            }
            # Everything else that carries facts in its HEADERS rather than
            # its text. Cheap: ExifTool reads headers, so a 564 MB video
            # costs about as much as a thumbnail.
            elsif ($mime =~ m{^(?:image|video|audio)/}
                || $mime =~ m{^application/(?:pdf|zip|x-zip-compressed|vnd\.openxmlformats|vnd\.oasis|msword|vnd\.ms-)}) {
                $meta = extract($mime, $path, log => $self->log);
                $meta = undef unless $meta && %$meta;
            }
        }

        # THE POINT OF ALL THIS, for most people: a real creation date.
        # drive.files.uploaded_at is when we received the file, which for a
        # photo taken years earlier is simply wrong -- and before this, 8
        # of 30,499 items had any content_created_at at all. EXIF's
        # DateTimeOriginal is the date the shutter fired.
        #
        # Only fills a GAP: a date drive already captured at upload time
        # came from the client's own file and is not overridden here.
        if ($meta && !$r->{content_created_at}) {
            if (my $made = best_created_at($meta)) { $r->{content_created_at} = $made }
        }

        $self->index->index_drive_item(account_id => $acct, row => {
            %$r, folder_path => $r->{folder_name},
            # Recorded even when extraction found nothing, so a file we have
            # already looked at is not looked at again on every pass.
            extractor_version => ($path ? EXTRACTOR_VERSION : undef),
            searchable        => ($r->{excluded} ? 0 : 1),
        }, text => $text, meta => $meta);
        $n++;
    }
    return $n;
}

1;
