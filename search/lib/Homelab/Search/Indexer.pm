package Homelab::Search::Indexer;
use Mojo::Base -base, -signatures;

use Sys::Hostname qw(hostname);
use Mojo::Pg;
use Homelab::Search::Index;
use Homelab::Search::MailParse qw(parse_message parse_maildir_name);
use Homelab::Search::Paths     qw(maildir_for mailbox_dir_for drive_blob_for);

has 'pg';
has 'drive_pg';          # separate handle: the drive schema is another role's
has 'config';
has 'log';
has 'index';
has host         => sub { hostname() };
has mail_root    => '/srv/mail-ro';
has drive_root   => '/srv/drive-ro';
has lease_secs   => 300;
has max_attempts => 5;
has batch_size   => 200;

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
sub discover ($self) {
    my $db  = $self->pg->db;
    my $tx  = $db->begin;
    my $got = $db->query('SELECT pg_try_advisory_xact_lock(?) AS ok', DISCOVERY_LOCK)->hash->{ok};
    unless ($got) {
        $tx->rollback;
        $self->log->debug('another host is discovering; skipping');
        return 0;
    }
    my $n = 0;
    my $ok = eval { $n = $self->_discover_mail + $self->_discover_drive; 1 };
    my $err = $@;
    $tx->rollback;
    die $err unless $ok;
    return $n;
}

# One stat per mailbox decides whether to enqueue it. A maildir's cur/ and
# new/ mtime changes when a file is added or removed, so this is a few
# hundred syscalls across the whole fleet.
sub _discover_mail ($self) {
    my $root = $self->mail_root;
    my $enq  = 0;

    opendir(my $rh, $root) or do { $self->log->warn("cannot read $root: $!"); return 0 };
    my @domains = grep { !/^\./ && -d "$root/$_" } readdir $rh;
    closedir $rh;

    for my $domain (sort @domains) {
        opendir(my $dh, "$root/$domain") or next;
        my @users = grep { !/^\./ && -d "$root/$domain/$_" } readdir $dh;
        closedir $dh;

        for my $user (sort @users) {
            my $email = lc "$user\@$domain";
            my $acct  = $self->index->upsert_account($email, has_mail => 1) or next;
            my $adir  = eval { maildir_for($root, $domain, $user) } or next;

            # INBOX is the account root in Maildir++; named folders are
            # dot-prefixed siblings.
            my @boxes = ('INBOX');
            opendir(my $ah, $adir) or next;
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
sub _discover_drive ($self) {
    my $dpg = $self->drive_pg or return 0;
    my $enq = 0;

    my $rows = eval {
        $dpg->db->query(q{
            SELECT f.id, f.user_email
              FROM drive.files f
             ORDER BY f.id})->hashes;
    };
    unless ($rows) { $self->log->warn("drive discovery failed: $@"); return 0 }

    my %by_account;
    for my $r (@$rows) {
        my $acct = $self->index->upsert_account(lc $r->{user_email}, has_drive => 1) or next;
        push @{ $by_account{$acct} }, $r->{id};
    }
    for my $acct (sort keys %by_account) {
        my @ids = @{ $by_account{$acct} };
        while (my @chunk = splice @ids, 0, $self->batch_size) {
            $enq += $self->_enqueue(kind => 'drive_batch', account_id => $acct, file_ids => \@chunk);
        }
    }
    return $enq;
}

# Idempotent enqueue: an identical unclaimed unit already waiting is not
# duplicated, so a discovery pass that overlaps a slow one does not double
# the work.
sub _enqueue ($self, %a) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my $dup = $db->query(q{
        SELECT 1 FROM search.index_queue
         WHERE kind = ? AND account_id = ? AND coalesce(mailbox_id, -1) = coalesce(?, -1)
           AND claimed_by IS NULL AND parked = FALSE
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

    for my $sub (qw(cur new)) {
        my $dir = eval {
            mailbox_dir_for($self->mail_root, $info->{domain}, $info->{local_part},
                            $info->{mailbox}, $sub)
        } or next;
        my @st = stat($dir) or next;
        $newest = $st[9] if $st[9] > $newest;

        opendir(my $dh, $dir) or next;
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
            $self->index->index_message(
                account_id => $info->{account_id}, mailbox_id => $info->{mailbox_id},
                parsed => $parsed, file => $file);
            $indexed++;
        }
        closedir $dh;
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
    my $rows = $dpg->db->query(qq{
        SELECT f.id, f.user_email, f.filename, f.uuid::text AS uuid, f.size_bytes,
               f.mime_type, f.uploaded_at, f.deleted_at,
               $created AS content_created_at,
               fo.name AS folder_name
          FROM drive.files f
          LEFT JOIN drive.folders fo ON fo.id = f.folder_id
         WHERE f.id IN ($ph)}, @$ids)->hashes;

    my $n = 0;
    for my $r (@$rows) {
        my $acct = $self->index->upsert_account(lc $r->{user_email}, has_drive => 1) or next;
        my $text;
        # Only extract from what is worth extracting, and only if the blob is
        # actually readable. Everything else is indexed on metadata alone.
        if (!$r->{deleted_at} && ($r->{mime_type} // '') =~ m{^text/}
            && ($r->{size_bytes} // 0) <= 8 * 1024 * 1024) {
            my $path = eval { drive_blob_for($self->drive_root, $r->{uuid}) };
            if ($path && -r $path && open(my $fh, '<', $path)) {
                binmode $fh;
                read $fh, my $buf, 1024 * 1024;
                close $fh;
                $text = $buf;
                $text =~ s/\0//g;
            }
        }
        $self->index->index_drive_item(account_id => $acct, row => {
            %$r, folder_path => $r->{folder_name},
        }, text => $text);
        $n++;
    }
    return $n;
}

1;
