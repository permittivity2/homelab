package Homelab::Search::Index;
use Mojo::Base -base, -signatures;
use Homelab::Search::Extract ();

use Homelab::Search::MailParse qw(HEADER_ALLOWLIST);

has 'pg';
has 'log';
# Interning caches. Bounded: a fleet-wide address list is unbounded in
# principle, and an unbounded hash in a daemon that never exits is a slow
# memory leak rather than a cache.
has cache_limit => 50_000;
has _cache      => sub { {} };

# How much text is fed to the tsvector. A tsvector is capped at about 1 MB
# and a large message or text file will error the INSERT outright, so the
# full text is kept in body_text while only this prefix is vectorized, with
# `truncated` recording that it happened. 256 KB is far below the ceiling
# and far beyond where more prose changes a relevance ranking.
use constant TSV_BUDGET => 262_144;

# EVERY WRITE IN THIS MODULE CROSSES ACCOUNTS, which the per-account RLS
# policy forbids. The indexer therefore marks its own session with
# `homelab.indexer = 'on'`, which the indexer_all policy keys on. Two
# things make that safe rather than a hole:
#   - it is SET LOCAL, so it lasts exactly one transaction and cannot leak
#     onto a pooled connection someone else picks up;
#   - the web app's request path never sets it (it sets a numeric
#     homelab.account_id), so the application can never accidentally
#     acquire cross-account visibility by reusing this code.
# Granting the runtime role BYPASSRLS would have been simpler and would
# have handed the same power to the web app, which must never have it.
sub _tx ($self, $cb) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my @r = $cb->($db);
    $tx->commit;
    return wantarray ? @r : $r[0];
}

sub _cached ($self, $ns, $key, $maker) {
    my $c = $self->_cache;
    $c->{$ns} //= {};
    return $c->{$ns}{$key} if exists $c->{$ns}{$key};
    my $id = $maker->();
    # Stop caching rather than grow without bound; correctness is
    # unaffected, only speed.
    $c->{$ns}{$key} = $id if keys %{ $c->{$ns} } < $self->cache_limit;
    return $id;
}

# SELECT first, then INSERT ... ON CONFLICT DO NOTHING, then SELECT again.
#
# The obvious shortcut is ON CONFLICT DO UPDATE ... RETURNING, which always
# returns a row in one round trip. It also takes an exclusive ROW LOCK on the
# existing row even though nothing needs changing -- and these tables are
# shared vocabulary that all three indexers intern concurrently, in whatever
# order their work happens to arrive in. That is a textbook deadlock, and it
# was not theoretical: mail discovery (iterating domains then users) and drive
# discovery (iterating drive.files by id) upserted the same search.accounts
# rows in opposite orders and Postgres killed one of them --
#
#   ERROR: deadlock detected ... while locking tuple in relation "accounts"
#
# The read path takes no lock at all and hits on essentially every call after
# the first, so the extra round trip costs nothing in practice and the
# contention disappears.
#
# Table and column names here are fixed literals in this file; nothing from a
# row or a request reaches the SQL text.
sub _get_or_create ($self, $db, $table, $id_col, $where, $wbind, $insert, $ibind) {
    my $r = $db->query("SELECT $id_col FROM $table WHERE $where", @$wbind)->array;
    return $r->[0] if $r;
    $db->query($insert, @$ibind);
    $r = $db->query("SELECT $id_col FROM $table WHERE $where", @$wbind)->array;
    return $r ? $r->[0] : undef;
}

sub _intern ($self, $db, $sql, @bind) {
    my $r = $db->query($sql, @bind)->array;
    return $r ? $r->[0] : undef;
}

my %META_KEY = map { $_->{key_name} => $_ }
              @{ Homelab::Search::Extract::keys_catalogue() };

sub domain_id ($self, $db, $domain) {
    $domain = lc($domain // '');
    return undef unless length $domain;
    return $self->_cached('domain', $domain, sub {
        $self->_get_or_create($db, 'search.domains', 'domain_id',
            'domain = ?', [$domain],
            'INSERT INTO search.domains (domain) VALUES (?) ON CONFLICT DO NOTHING', [$domain]);
    });
}

sub address_id ($self, $db, $local_part, $domain) {
    return undef unless defined $local_part && defined $domain;
    my $key = lc("$local_part\@$domain");
    return $self->_cached('addr', $key, sub {
        my $did = $self->domain_id($db, $domain) or return undef;
        $self->_get_or_create($db, 'search.addresses', 'address_id',
            'local_part = ? AND domain_id = ?', [lc $local_part, $did],
            q{INSERT INTO search.addresses (local_part, domain_id, addr_text)
              VALUES (?, ?, '') ON CONFLICT DO NOTHING}, [lc $local_part, $did]);
    });
}

sub display_name_id ($self, $db, $name) {
    return undef unless defined $name && length $name;
    return $self->_cached('dname', $name, sub {
        $self->_get_or_create($db, 'search.display_names', 'display_name_id',
            'display_name = ?', [$name],
            'INSERT INTO search.display_names (display_name) VALUES (?) ON CONFLICT DO NOTHING', [$name]);
    });
}

sub mime_type_id ($self, $db, $mime) {
    $mime = lc($mime // 'application/octet-stream');
    $mime =~ s/;.*$//;  $mime =~ s/\s+//g;
    my ($type, $subtype) = split m{/}, $mime, 2;
    $type    = 'application'  unless defined $type    && length $type;
    $subtype = 'octet-stream' unless defined $subtype && length $subtype;
    return $self->_cached('mime', "$type/$subtype", sub {
        $self->_get_or_create($db, 'search.mime_types', 'mime_type_id',
            'type = ? AND subtype = ?', [$type, $subtype],
            'INSERT INTO search.mime_types (type, subtype) VALUES (?, ?) ON CONFLICT DO NOTHING',
            [$type, $subtype]);
    });
}

# The metadata key lookup, interned like the others. Attributes come from
# Extract's catalogue, so the label and the sensitive flag have ONE
# definition -- the module that produces the value also says what it is
# called and whether it may leave the building.
# A person in this account's photos. Case-insensitively unique: photo
# managers are inconsistent about capitalisation and "jeff gardner" and
# "Jeff Gardner" are one person, not two.
sub person_id ($self, $db, $account_id, $name) {
    return undef unless defined $name && length $name;
    return $self->_cached("person:$account_id", lc $name, sub {
        return $self->_get_or_create($db, 'search.people', 'person_id',
            'account_id = ? AND lower(display_name) = lower(?)', [$account_id, $name],
            'INSERT INTO search.people (account_id, display_name) VALUES (?, ?)
             ON CONFLICT (account_id, lower(display_name)) DO UPDATE
                SET display_name = search.people.display_name
             RETURNING person_id', [$account_id, $name]);
    });
}

# A node in the tag tree, interning EVERY ANCESTOR on the way down.
#
# "Places|Earth|USA|Utah|Moab" creates five rows, each pointing at its
# parent, so "everything in Utah" is a real query rather than a string
# guess. Called once per distinct path per process and then cached, so the
# repeated walk costs nothing after the first photo.
sub tag_id ($self, $db, $account_id, $path) {
    return undef unless defined $path && length $path;
    return $self->_cached("tag:$account_id", $path, sub {
        my (@seg) = grep { length } split /\|/, $path;
        return undef unless @seg;
        my ($parent, $sofar);
        for my $seg (@seg) {
            $sofar = defined $sofar ? "$sofar|$seg" : $seg;
            $parent = $self->_get_or_create($db, 'search.tags', 'tag_id',
                'account_id = ? AND path = ?', [$account_id, $sofar],
                'INSERT INTO search.tags (account_id, parent_id, name, path)
                 VALUES (?, ?, ?, ?)
                 ON CONFLICT (account_id, path) DO UPDATE SET name = EXCLUDED.name
                 RETURNING tag_id', [$account_id, $parent, $seg, $sofar]);
            return undef unless $parent;
        }
        return $parent;
    });
}

sub metadata_key_id ($self, $db, $key_name) {
    return undef unless defined $key_name && length $key_name;
    return $self->_cached('metakey', $key_name, sub {
        my $spec = $META_KEY{$key_name} or return undef;
        return $self->_get_or_create($db, 'search.metadata_keys', 'key_id',
            'key_name = ?', [$key_name],
            'INSERT INTO search.metadata_keys (key_name, label, value_kind, sensitive)
             VALUES (?, ?, ?, ?) ON CONFLICT (key_name) DO UPDATE
                SET label = EXCLUDED.label, value_kind = EXCLUDED.value_kind,
                    sensitive = EXCLUDED.sensitive
             RETURNING key_id',
            [$key_name, $spec->{label}, $spec->{value_kind}, ($spec->{sensitive} ? 1 : 0)]);
    });
}

sub header_name_id ($self, $db, $name) {
    $name = lc($name // '');
    return undef unless length $name;
    return $self->_cached('hname', $name, sub {
        $self->_get_or_create($db, 'search.header_names', 'header_name_id',
            'name = ?', [$name],
            'INSERT INTO search.header_names (name) VALUES (?) ON CONFLICT DO NOTHING', [$name]);
    });
}

# --------------------------------------------------------------- accounts
sub upsert_account ($self, $email, %opts) {
    $email = lc $email;
    my ($lp, $dom) = $email =~ /\A(.+)\@([^@]+)\z/ or return undef;
    return $self->_tx(sub ($db) {
        my $did = $self->domain_id($db, $dom);
        my $id  = $self->_get_or_create($db, 'search.accounts', 'account_id',
            'email = ?', [$email],
            q{INSERT INTO search.accounts (email, domain_id, local_part)
              VALUES (?, ?, ?) ON CONFLICT DO NOTHING}, [$email, $did, $lp]);
        return undef unless defined $id;

        # IS DISTINCT FROM, so an unchanged flag writes nothing and takes no
        # row lock. Mail discovery sets has_mail and drive discovery sets
        # has_drive on the SAME account rows, concurrently, from different
        # hosts -- an unconditional UPDATE here is the other half of the
        # deadlock described above.
        if (defined $opts{has_mail}) {
            $db->query(q{UPDATE search.accounts SET has_mail = ?
                          WHERE account_id = ? AND has_mail IS DISTINCT FROM ?},
                       ($opts{has_mail} ? 1 : 0), $id, ($opts{has_mail} ? 1 : 0));
        }
        if (defined $opts{has_drive}) {
            $db->query(q{UPDATE search.accounts SET has_drive = ?
                          WHERE account_id = ? AND has_drive IS DISTINCT FROM ?},
                       ($opts{has_drive} ? 1 : 0), $id, ($opts{has_drive} ? 1 : 0));
        }
        return $id;
    });
}

sub mailbox_id ($self, $account_id, $name) {
    return $self->_tx(sub ($db) {
        $self->_get_or_create($db, 'search.mailboxes', 'mailbox_id',
            'account_id = ? AND name = ?', [$account_id, $name],
            q{INSERT INTO search.mailboxes (account_id, name) VALUES (?, ?)
              ON CONFLICT DO NOTHING}, [$account_id, $name]);
    });
}

sub set_mailbox_mtime ($self, $mailbox_id, $epoch) {
    $self->_tx(sub ($db) {
        $db->query('UPDATE search.mailboxes SET dir_mtime = to_timestamp(?) WHERE mailbox_id = ?',
                   $epoch, $mailbox_id);
    });
}

sub mailbox_mtime ($self, $mailbox_id) {
    return $self->_tx(sub ($db) {
        my $r = $db->query(q{SELECT extract(epoch FROM dir_mtime)::bigint AS m
                               FROM search.mailboxes WHERE mailbox_id = ?}, $mailbox_id)->hash;
        return $r ? $r->{m} : undef;
    });
}

# Which uniq_parts this mailbox already has, and under what filename. The
# filename is returned too because a flag change renames the file without
# changing its identity -- that is an UPDATE of one column, not a re-index.
sub known_files ($self, $mailbox_id) {
    return $self->_tx(sub ($db) {
        my %h;
        my $rows = $db->query(q{
            SELECT uniq_part, file_name, message_id FROM search.message_files
             WHERE mailbox_id = ?}, $mailbox_id)->hashes;
        $h{ $_->{uniq_part} } = $_ for @$rows;
        return \%h;
    });
}

# ---------------------------------------------------------------- messages
sub _thread_for ($self, $db, $account_id, $parsed) {
    my $irt = $parsed->{in_reply_to};
    if (defined $irt && length $irt) {
        my $r = $db->query(q{
            SELECT thread_id FROM search.messages
             WHERE account_id = ? AND rfc822_msgid = ? AND thread_id IS NOT NULL
             LIMIT 1}, $account_id, $irt)->hash;
        return $r->{thread_id} if $r && $r->{thread_id};
    }
    # No parent we know of: this message starts a thread. Simple and
    # deliberately so -- a full References-graph union would re-parent
    # threads retroactively, which is a different (and much larger) job.
    my $subject = $parsed->{subject} // '';
    $subject =~ s/\A\s*(?:re|fwd|fw)\s*:\s*//ig;
    return $self->_intern($db, q{
        INSERT INTO search.threads (account_id, root_rfc822_msgid, subject_norm, first_at, last_at, msg_count)
        VALUES (?, ?, ?, to_timestamp(?), to_timestamp(?), 0)
        RETURNING thread_id},
        $account_id, $parsed->{rfc822_msgid}, lc $subject,
        $parsed->{sent_at}, $parsed->{sent_at});
}

# One message, one transaction. If any part of it fails the whole message
# is absent rather than half-present, which matters because a half-indexed
# message would look indexed to the change detector and never be retried.
sub index_message ($self, %a) {
    my ($account_id, $mailbox_id, $parsed, $file) =
        @a{qw(account_id mailbox_id parsed file)};

    return $self->_tx(sub ($db) {
        my $thread_id = $self->_thread_for($db, $account_id, $parsed);

        my $mid = $self->_intern($db, q{
            INSERT INTO search.messages
                (account_id, mailbox_id, thread_id, rfc822_msgid, in_reply_to, subject,
                 sent_at, received_at, size_bytes, has_attachments, is_seen, is_flagged, is_draft)
            VALUES (?, ?, ?, ?, ?, ?, to_timestamp(?), to_timestamp(?), ?, ?, ?, ?, ?)
            RETURNING message_id},
            $account_id, $mailbox_id, $thread_id,
            $parsed->{rfc822_msgid}, $parsed->{in_reply_to}, $parsed->{subject},
            $parsed->{sent_at}, $parsed->{received_at}, $parsed->{size_bytes},
            ($parsed->{has_attachments} ? 1 : 0),
            ($file->{is_seen} ? 1 : 0), ($file->{is_flagged} ? 1 : 0), ($file->{is_draft} ? 1 : 0));

        $db->query(q{
            INSERT INTO search.message_files
                (message_id, account_id, mailbox_id, sub_id, uniq_part, file_name, size_bytes, mtime, inode)
            VALUES (?, ?, ?, (SELECT sub_id FROM search.maildir_subs WHERE sub = ?), ?, ?, ?, to_timestamp(?), ?)},
            $mid, $account_id, $mailbox_id, $file->{sub}, $file->{uniq_part},
            $file->{file_name}, $file->{size}, $file->{mtime}, $file->{inode});

        my %role_id = (from => 1, sender => 2, reply_to => 3, to => 4, cc => 5, bcc => 6);
        my %seen_pair;
        for my $role (sort keys %role_id) {
            my $list = $parsed->{addresses}{$role} or next;
            my $pos = 0;
            for my $a (@$list) {
                my $aid = $self->address_id($db, $a->{local_part}, $a->{domain}) or next;
                my $nid = $self->display_name_id($db, $a->{display_name});
                # message_addresses is keyed on message_id, which only this
                # transaction holds, so there is no cross-host contention here.
                $db->query(q{
                    INSERT INTO search.message_addresses
                        (message_id, account_id, role_id, position, address_id, display_name_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (message_id, role_id, position) DO NOTHING},
                    $mid, $account_id, $role_id{$role}, $pos++, $aid, $nid);
                $seen_pair{"$aid:$nid"} = [$aid, $nid] if $nid;
            }
        }

        # address_names IS shared across accounts and hosts -- it is the
        # "this address has been seen under this name N times" counter -- so
        # its upsert does take a row lock. Deadlock needs two transactions to
        # take two locks in opposite orders, so they are taken in a
        # deterministic global order (by address_id, then display_name_id)
        # and each pair only once per message. Sorting is the cheapest
        # deadlock prevention there is: every transaction in the fleet walks
        # these rows the same way round.
        for my $k (sort { $seen_pair{$a}[0] <=> $seen_pair{$b}[0]
                       || $seen_pair{$a}[1] <=> $seen_pair{$b}[1] } keys %seen_pair) {
            my ($aid, $nid) = @{ $seen_pair{$k} };
            $db->query(q{
                INSERT INTO search.address_names (address_id, display_name_id, msg_count)
                VALUES (?, ?, 1)
                ON CONFLICT (address_id, display_name_id) DO UPDATE
                    SET msg_count = search.address_names.msg_count + 1,
                        last_seen = NOW()}, $aid, $nid);
        }

        for my $name (sort keys %{ $parsed->{headers} // {} }) {
            my $hid = $self->header_name_id($db, $name) or next;
            my $pos = 0;
            for my $v (@{ $parsed->{headers}{$name} }) {
                $db->query(q{
                    INSERT INTO search.message_headers (message_id, account_id, header_name_id, position, value)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (message_id, header_name_id, position) DO NOTHING},
                    $mid, $account_id, $hid, $pos++, $v);
            }
        }

        my $body = $parsed->{body_text} // '';
        my $src  = length($body) > TSV_BUDGET ? substr($body, 0, TSV_BUDGET) : $body;
        $db->query(q{
            INSERT INTO search.message_bodies (message_id, account_id, body_text, tsv_source, truncated)
            VALUES (?, ?, ?, ?, ?)},
            $mid, $account_id, $body, $src, (length($body) > TSV_BUDGET ? 1 : 0));

        for my $at (@{ $parsed->{attachments} // [] }) {
            $db->query(q{
                INSERT INTO search.attachments (message_id, account_id, file_name, mime_type_id, size_bytes)
                VALUES (?, ?, ?, ?, ?)},
                $mid, $account_id, $at->{file_name},
                $self->mime_type_id($db, $at->{mime_type}), $at->{size_bytes});
        }

        $db->query(q{
            UPDATE search.threads SET msg_count = msg_count + 1,
                   last_at = GREATEST(last_at, to_timestamp(?))
             WHERE thread_id = ?}, $parsed->{sent_at}, $thread_id);

        return $mid;
    });
}

# A flag change renames the file but is not a new message.
sub touch_file ($self, $message_id, $file) {
    $self->_tx(sub ($db) {
        $db->query(q{
            UPDATE search.message_files
               SET file_name = ?, mtime = to_timestamp(?),
                   sub_id = (SELECT sub_id FROM search.maildir_subs WHERE sub = ?)
             WHERE message_id = ?}, $file->{file_name}, $file->{mtime}, $file->{sub}, $message_id);
        $db->query(q{
            UPDATE search.messages SET is_seen = ?, is_flagged = ?, is_draft = ?
             WHERE message_id = ?},
            ($file->{is_seen} ? 1 : 0), ($file->{is_flagged} ? 1 : 0),
            ($file->{is_draft} ? 1 : 0), $message_id);
    });
}

# Deletes messages by id, in chunks with explicit placeholders.
#
# Deliberately not `= ANY (?)` with a Perl arrayref: whether DBD::Pg binds
# that as text[] or bigint[] depends on inference, and a mis-inferred array
# parameter fails at runtime on real data rather than in a unit test. An
# explicit placeholder list has no type ambiguity at all. message_files,
# message_addresses, message_headers, message_bodies and attachments all
# cascade from search.messages, so this one delete is sufficient.
# Remove index rows for mailboxes that no longer exist on disk.
#
# WHY THIS IS NEEDED. search.mailboxes.name IS the on-disk folder name,
# UNIQUE (account_id, name), and mailbox_id() is get-or-create. So renaming
# '.Old' to '.New' does not rename anything here -- it creates a SECOND row
# and re-indexes every message under fresh ids, while '.Old' and all its
# messages stay in the index forever, searchable, pointing at a folder that
# no longer exists. Deleting a folder leaves the same residue. Nothing in
# this package ever removed a mailbox row; the drive side has had a
# reconcile from the start and mail had none.
#
# ONE DELETE, because every child cascades: search.messages and
# search.message_files hang off (account_id, mailbox_id) ON DELETE CASCADE,
# and message_bodies / message_addresses / message_headers / attachments all
# cascade from messages. Doing it in stages by hand would be more code and
# more ways to leave half of it behind.
#
# THE CALLER'S OBLIGATION, and it is the whole safety of this function:
# $names must be the COMPLETE list of folders seen on disk for this account,
# from a directory read that SUCCEEDED. Hand it a partial list and it
# deletes real mail from the index -- which is exactly the bug this release
# fixes one level down in _do_mailbox. Two guards here because the cost of
# being wrong is somebody's mail vanishing from search:
#
#   * an empty or non-array $names deletes nothing and returns -- a caller
#     with no list is a caller that failed, not an account with no folders
#     (every account has at least INBOX);
#   * the delete is scoped to one account_id, so even a wrong list cannot
#     reach past the account being reconciled.
sub prune_mailboxes ($self, $account_id, $names) {
    return 0 unless defined $account_id && ref $names eq 'ARRAY' && @$names;

    return $self->_tx(sub ($db) {
        my $ph   = join ',', map { '?' } @$names;
        my $gone = $db->query(
            "SELECT mailbox_id, name FROM search.mailboxes
              WHERE account_id = ? AND name NOT IN ($ph)",
            $account_id, @$names)->hashes;
        return 0 unless @$gone;

        for my $m (@$gone) {
            $db->query('DELETE FROM search.mailboxes WHERE mailbox_id = ? AND account_id = ?',
                       $m->{mailbox_id}, $account_id);
            $self->log->info("pruned mailbox '$m->{name}' (account $account_id): "
                           . "no longer on disk") if $self->log;
        }
        return scalar @$gone;
    }) // 0;
}

sub delete_messages ($self, $ids) {
    return 0 unless ref $ids eq 'ARRAY' && @$ids;
    my $n = 0;
    while (my @chunk = splice @$ids, 0, 500) {
        my $ph = join ',', map { '?' } @chunk;
        $self->_tx(sub ($db) {
            $db->query("DELETE FROM search.messages WHERE message_id IN ($ph)", @chunk);
        });
        $n += @chunk;
    }
    return $n;
}

# ------------------------------------------------------------ bookkeeping
sub meta_get ($self, $key) {
    return $self->_tx(sub ($db) {
        my $r = $db->query('SELECT value FROM search.index_meta WHERE key = ?', $key)->hash;
        return $r ? $r->{value} : undef;
    });
}

sub meta_set ($self, $key, $value) {
    $self->_tx(sub ($db) {
        $db->query(q{
            INSERT INTO search.index_meta (key, value, updated_at) VALUES (?, ?, NOW())
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()},
            $key, $value);
    });
}

# Every drive_file_id the index holds, live or trashed. Used for the
# set-difference reconcile: what drive has that we do not, and what we have
# that drive no longer does.
sub all_drive_ids ($self) {
    return $self->_tx(sub ($db) {
        my %have;
        my $rows = $db->query(q{SELECT drive_file_id FROM search.drive_items
                                 WHERE drive_file_id IS NOT NULL})->hashes;
        $have{ $_->{drive_file_id} } = 1 for @$rows;
        return \%have;
    });
}

# Purged in drive (not merely trashed) -- the index row has to go, since
# nothing will ever reference it again.
sub delete_drive_items ($self, $ids) {
    return 0 unless ref $ids eq 'ARRAY' && @$ids;
    my $n = 0;
    while (my @chunk = splice @$ids, 0, 500) {
        my $ph = join ',', map { '?' } @chunk;
        $self->_tx(sub ($db) {
            $db->query("DELETE FROM search.drive_items WHERE drive_file_id IN ($ph)", @chunk);
        });
        $n += @chunk;
    }
    return $n;
}

# Highest drive.files id already in the index. New uploads get higher ids, so
# this is what stops discovery re-enqueueing the entire corpus every pass.
sub drive_watermark ($self) {
    return $self->_tx(sub ($db) {
        my $r = $db->query('SELECT coalesce(max(drive_file_id), 0) AS m FROM search.drive_items')->hash;
        return $r ? $r->{m} : 0;
    });
}

# drive_file_ids the index currently believes are LIVE. Compared against the
# set drive says is deleted, so a trashed file leaves the index on the next
# pass rather than waiting for a full reconcile -- "deleted files must stop
# appearing immediately" is a correctness requirement, not a nicety.
sub live_drive_ids ($self) {
    return $self->_tx(sub ($db) {
        my %live;
        my $rows = $db->query(q{SELECT drive_file_id FROM search.drive_items
                                 WHERE deleted_at IS NULL AND drive_file_id IS NOT NULL})->hashes;
        $live{ $_->{drive_file_id} } = 1 for @$rows;
        return \%live;
    });
}

# ------------------------------------------------------------------- drive
sub index_drive_item ($self, %a) {
    my ($account_id, $row, $text, $meta) = @a{qw(account_id row text meta)};
    return $self->_tx(sub ($db) {
        my $id = $self->_intern($db, q{
            INSERT INTO search.drive_items
                (account_id, drive_file_id, file_uuid, file_name, folder_path, mime_type_id,
                 size_bytes, content_created_at, uploaded_at, deleted_at, extractor_version,
                 searchable, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
            ON CONFLICT (account_id, file_uuid) DO UPDATE SET
                file_name          = EXCLUDED.file_name,
                folder_path        = EXCLUDED.folder_path,
                mime_type_id       = EXCLUDED.mime_type_id,
                size_bytes         = EXCLUDED.size_bytes,
                content_created_at = EXCLUDED.content_created_at,
                extractor_version  = EXCLUDED.extractor_version,
                searchable         = EXCLUDED.searchable,
                uploaded_at        = EXCLUDED.uploaded_at,
                deleted_at         = EXCLUDED.deleted_at,
                indexed_at         = NOW()
            RETURNING drive_item_id},
            $account_id, $row->{id}, $row->{uuid}, $row->{filename}, $row->{folder_path},
            $self->mime_type_id($db, $row->{mime_type}),
            $row->{size_bytes}, $row->{content_created_at}, $row->{uploaded_at}, $row->{deleted_at},
            $row->{extractor_version},
            (exists $row->{searchable} ? ($row->{searchable} ? 1 : 0) : 1));

        # WHAT IS SEARCHABLE vs WHAT IS DISPLAYED, which is why these are
        # two columns: body_text is the document (snippets, get_excerpt),
        # tsv_source is what feeds the search vector.
        #
        # Every TEXT metadata value joins tsv_source. Without this a photo
        # is unfindable by anything in it: an image has no body text at
        # all, so a tagged person's name, the camera, the caption and a
        # zip's member list were all stored, shown on the page, and
        # impossible to type into the search box. "The zip with the
        # invoice in it" is the plan's own example of what this should
        # find, and it did not.
        #
        # Kind-driven rather than a list of keys: a text key added later is
        # searchable the day it is added, and a number or a date is left
        # out because 1920 and 2026-08-09 are filters, not search terms.
        my @meta_terms;
        if ($meta) {
            for my $key (sort keys %$meta) {
                next if $key =~ /\A_/;
                next unless ($META_KEY{$key}{value_kind} // '') eq 'text';
                push @meta_terms, $meta->{$key};
            }
            # A tagged name and a tag path are the most searchable text a
            # photo has. The path goes in with its separators turned into
            # spaces, so "Utah", "Moab" and "Arches" each match the photo
            # their owner filed under all three.
            push @meta_terms, grep { defined } map { $_->{name} } @{ $meta->{_faces} // [] };
            push @meta_terms, map { my $p = $_; $p =~ tr/|/ /; $p } @{ $meta->{_tags} // [] };
        }

        if (defined $text || @meta_terms) {
            my $body = $text;
            my $src  = join "\n", grep { defined && length } ($text, @meta_terms);
            my $trunc = length($src) > TSV_BUDGET ? 1 : 0;
            $src = substr($src, 0, TSV_BUDGET) if $trunc;
            $db->query(q{
                INSERT INTO search.drive_item_text (drive_item_id, account_id, body_text, tsv_source, truncated)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (drive_item_id) DO UPDATE SET
                    body_text = EXCLUDED.body_text, tsv_source = EXCLUDED.tsv_source,
                    truncated = EXCLUDED.truncated},
                $id, $account_id, $body, $src, $trunc);
        }

        # Faces and tags: replaced wholesale for this item, for the same
        # reason the metadata is -- a re-extraction is the authority on
        # what this photo now carries, and a face or tag removed in the
        # photo manager must disappear here too.
        #
        # The people and tags THEMSELVES are not deleted: they belong to
        # the account, not to one photo, and a person who happens to be
        # untagged from their last photo should not silently vanish from
        # the account's list mid-re-index.
        if ($meta && ($meta->{_faces} || $meta->{_tags})) {
            $db->query('DELETE FROM search.photo_faces WHERE drive_item_id = ?', $id);
            $db->query('DELETE FROM search.photo_tags  WHERE drive_item_id = ?', $id);

            for my $f (@{ $meta->{_faces} // [] }) {
                my $pid = defined $f->{name}
                        ? $self->person_id($db, $account_id, $f->{name}) : undef;
                $db->query(
                    'INSERT INTO search.photo_faces
                        (drive_item_id, account_id, person_id, region_type,
                         area_x, area_y, area_w, area_h)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                    $id, $account_id, $pid, ($f->{type} // 'Face'),
                    @{$f}{qw(x y w h)});
            }
            for my $path (@{ $meta->{_tags} // [] }) {
                my $tid = $self->tag_id($db, $account_id, $path) or next;
                $db->query(
                    'INSERT INTO search.photo_tags (drive_item_id, account_id, tag_id)
                     VALUES (?, ?, ?) ON CONFLICT DO NOTHING',
                    $id, $account_id, $tid);
            }
        }

        # Per-type metadata. Replaced wholesale rather than merged: a
        # re-extraction is the authority on what this file now has, and a
        # key that disappeared (a tag removed from the map, a file
        # replaced) must disappear with it rather than linger as a fact
        # nothing produces any more.
        if ($meta) {
            $db->query('DELETE FROM search.drive_metadata WHERE drive_item_id = ?', $id);
            for my $key (sort keys %$meta) {
                # _faces and _tags are structured and go to their own
                # tables below, not into the flat key/value store.
                next if $key =~ /\A_/;
                my $kid = $self->metadata_key_id($db, $key) or next;
                my $kind = $META_KEY{$key}{value_kind};
                my @cols = $kind eq 'num' ? ('value_num',  $meta->{$key})
                         : $kind eq 'at'  ? ('value_at',   $meta->{$key})
                         :                  ('value_text', $meta->{$key});
                next unless defined $cols[1];
                $db->query("INSERT INTO search.drive_metadata
                                (drive_item_id, account_id, key_id, $cols[0])
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT (drive_item_id, key_id) DO UPDATE
                               SET $cols[0] = EXCLUDED.$cols[0]",
                           $id, $account_id, $kid, $cols[1]);
            }
        }
        return $id;
    });
}

1;
