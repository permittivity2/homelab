package Homelab::Search::Index;
use Mojo::Base -base, -signatures;

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

# ------------------------------------------------------------------- drive
sub index_drive_item ($self, %a) {
    my ($account_id, $row, $text) = @a{qw(account_id row text)};
    return $self->_tx(sub ($db) {
        my $id = $self->_intern($db, q{
            INSERT INTO search.drive_items
                (account_id, drive_file_id, file_uuid, file_name, folder_path, mime_type_id,
                 size_bytes, content_created_at, uploaded_at, deleted_at, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
            ON CONFLICT (account_id, file_uuid) DO UPDATE SET
                file_name          = EXCLUDED.file_name,
                folder_path        = EXCLUDED.folder_path,
                mime_type_id       = EXCLUDED.mime_type_id,
                size_bytes         = EXCLUDED.size_bytes,
                content_created_at = EXCLUDED.content_created_at,
                uploaded_at        = EXCLUDED.uploaded_at,
                deleted_at         = EXCLUDED.deleted_at,
                indexed_at         = NOW()
            RETURNING drive_item_id},
            $account_id, $row->{id}, $row->{uuid}, $row->{filename}, $row->{folder_path},
            $self->mime_type_id($db, $row->{mime_type}),
            $row->{size_bytes}, $row->{content_created_at}, $row->{uploaded_at}, $row->{deleted_at});

        if (defined $text) {
            my $src = length($text) > TSV_BUDGET ? substr($text, 0, TSV_BUDGET) : $text;
            $db->query(q{
                INSERT INTO search.drive_item_text (drive_item_id, account_id, body_text, tsv_source, truncated)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (drive_item_id) DO UPDATE SET
                    body_text = EXCLUDED.body_text, tsv_source = EXCLUDED.tsv_source,
                    truncated = EXCLUDED.truncated},
                $id, $account_id, $text, $src, (length($text) > TSV_BUDGET ? 1 : 0));
        }
        return $id;
    });
}

1;
