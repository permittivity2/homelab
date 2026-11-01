package Homelab::Search::Query;
use Mojo::Base -base, -signatures;
use Homelab::Search::Mime qw(token_sql);

has 'pg';
has 'log';

# THE ONLY PLACE SEARCH SQL IS BUILT. No route composes its own.
#
# Every method here opens a transaction, sets `homelab.account_id` with
# SET LOCAL, and runs. Three things about that, in order of how badly each
# would bite:
#
#  1. SET LOCAL, never a bare SET. The pgbouncer tier runs
#     pool_mode = session; a bare SET persists on the pooled server
#     connection and the next client inherits it. SET LOCAL dies with the
#     transaction.
#
#  2. The account id comes from the SESSION, resolved from the introspected
#     email, and is never read from a query parameter. There is deliberately
#     no argument anywhere in this module that lets a caller name a different
#     account.
#
#  3. The WHERE clauses here still filter on account_id explicitly, even
#     though row-level security already does. That is not redundancy for its
#     own sake: RLS is the backstop for a mistake in this file, and this file
#     is the backstop for a mistake in the policies. Neither alone.
# The PUBLIC form of _scoped, for AI mode's own tables.
#
# ai_consent, ai_requests and ai_cache carry an account_id and an RLS
# policy WITH CHECK, so a write through a bare $db is refused -- correctly:
# the GUC is what says who is asking, and without it the policy has nothing
# to compare against. Rather than let the AI code open its own connections
# and set the GUC itself (a second place for the account scope to be
# forgotten, which is exactly what §1c of the plan exists to prevent), it
# borrows this one.
#
# Writes commit; the transaction wrapper is what makes `set_config(...,
# true)` apply at all, since a transaction-local setting outside a
# transaction lasts for one statement.
sub scoped ($self, $account_id, $cb) { return $self->_scoped($account_id, $cb) }

sub _scoped ($self, $account_id, $cb) {
    # Refuse to scope to anything that is not an account id. Setting the GUC
    # to '' or undef does not fail here -- it fails later, inside the RLS
    # policy, as a confusing cast error on an unrelated table.
    die "Homelab::Search::Query: refusing to scope to a non-numeric account id\n"
        unless defined $account_id && $account_id =~ /\A[0-9]+\z/;
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query('SELECT set_config(?, ?, true)', 'homelab.account_id', $account_id);
    my @r = $cb->($db);
    $tx->commit;
    return wantarray ? @r : $r[0];
}

# The account row for a signed-in address, or undef. An address with no row
# has simply never been indexed (a brand-new mailbox, or drive-only); callers
# render an empty result rather than an error.
sub account_for ($self, $email) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    # The indexer marker, because this lookup happens BEFORE we know the
    # account id -- it is the query that finds it. Read-only, one row, and
    # the only thing it can return is the id for the address we were handed.
    $db->query(q{SELECT set_config('homelab.indexer', 'on', true)});
    my $r = $db->query(q{SELECT account_id, email, has_mail, has_drive
                           FROM search.accounts WHERE email = lower(?)}, $email)->hash;
    $tx->commit;
    return $r;
}

# websearch_to_tsquery, not plainto_tsquery or to_tsquery: it accepts what a
# person actually types -- quoted phrases, OR, and a leading minus to exclude
# -- and it never throws on malformed input, which to_tsquery does. A search
# box that 500s on an unbalanced quote is not acceptable, and catching that
# per-input is a losing game.
my $TSQ = q{websearch_to_tsquery('english', ?)};

sub _date_bounds ($f) {
    my ($from, $to) = ($f->{from}, $f->{to});
    undef $from unless defined $from && $from =~ /\A\d{4}-\d{2}-\d{2}\z/;
    undef $to   unless defined $to   && $to   =~ /\A\d{4}-\d{2}-\d{2}\z/;
    return ($from, $to);
}

# ------------------------------------------------------------------- mail
sub search_mail ($self, $account_id, $f) {
    my ($from, $to) = _date_bounds($f);
    my $q     = $f->{q}      // '';
    my $limit = $f->{limit}  || 50;
    my $off   = $f->{offset} || 0;

    # BINDS ARE COLLECTED PER CLAUSE, IN STATEMENT ORDER, and assembled at the
    # end in that same order. The rank expression lives in the SELECT list,
    # which precedes WHERE -- so its placeholder is the FIRST one in the
    # statement, not the last.
    #
    # Appending the rank's bind at the end instead is what this code did
    # first, and it does not fail cleanly: the tsquery parameter silently
    # received the account id and the bigint account_id column received the
    # search term, so every search 500'd with
    #   invalid input syntax for type bigint: "invoice"
    # Keeping each fragment next to its own binds is what makes the ordering
    # structurally right rather than something to remember.
    my (@sel_bind, @where, @where_bind);
    push @where, 'm.account_id = ?'; push @where_bind, $account_id;

    # Ranking: subject weighted above participants above body, which is what
    # makes "invoice" find the message ABOUT invoices rather than the one that
    # merely mentions the word in a footer.
    my $rank = q{0};
    if (length $q) {
        $rank = qq{ts_rank_cd(
            setweight(to_tsvector('english', coalesce(m.subject,'')), 'A')
         || setweight(coalesce(b.tsv, ''::tsvector), 'C'), $TSQ)};
        push @sel_bind, $q;
        push @where, "(b.tsv @@ $TSQ OR m.subject ILIKE ?)";
        push @where_bind, $q, '%' . $q . '%';
    }
    if (defined $f->{person} && length $f->{person}) {
        # Through message_addresses, never by reading search.addresses
        # directly -- that table is shared vocabulary across every account
        # and a typeahead over it would leak one user's contacts to another.
        # See the note at the top of migrations/001-search.sql.
        push @where, q{EXISTS (
            SELECT 1 FROM search.message_addresses ma
              JOIN search.addresses ad USING (address_id)
              LEFT JOIN search.display_names dn USING (display_name_id)
             WHERE ma.message_id = m.message_id
               AND ma.account_id = m.account_id
               AND (ad.addr_text ILIKE ? OR dn.display_name ILIKE ?))};
        push @where_bind, '%' . $f->{person} . '%', '%' . $f->{person} . '%';
    }
    push @where, 'coalesce(m.sent_at, m.received_at) >= ?::date' and push @where_bind, $from if $from;
    push @where, 'coalesce(m.sent_at, m.received_at) <  (?::date + 1)' and push @where_bind, $to if $to;
    push @where, 'm.has_attachments' if $f->{has_attachments};
    # A type filter on MAIL means "has an attachment of this type" -- the
    # message itself has no interesting mime. Include is EXISTS, exclude is
    # NOT EXISTS over the same set, which (deliberately) also keeps messages
    # with no attachments at all: "not a picture" should not mean "must have
    # an attachment that isn't a picture".
    for my $spec ([ $f->{type_in}, 0 ], [ $f->{type_ex}, 1 ]) {
        my ($frag, @b) = token_sql('ta', $spec->[0], 0);
        next unless $frag;
        my $exists = qq{EXISTS (
            SELECT 1 FROM search.attachments at
              JOIN search.mime_types ta USING (mime_type_id)
             WHERE at.message_id = m.message_id
               AND at.account_id = m.account_id
               AND $frag)};
        push @where, ($spec->[1] ? "NOT $exists" : $exists);
        push @where_bind, @b;
    }
    push @where, 'mb.name = ?' and push @where_bind, $f->{mailbox} if defined $f->{mailbox} && length $f->{mailbox};

    my $sql = qq{
        SELECT m.message_id, m.subject, m.sent_at, m.received_at, m.size_bytes,
               m.has_attachments, m.is_seen, mb.name AS mailbox,
               $rank AS rank,
               (SELECT ad.addr_text FROM search.message_addresses ma
                  JOIN search.addresses ad USING (address_id)
                 WHERE ma.message_id = m.message_id AND ma.role_id = 1
                 ORDER BY ma.position LIMIT 1) AS from_addr,
               (SELECT dn.display_name FROM search.message_addresses ma
                  JOIN search.display_names dn USING (display_name_id)
                 WHERE ma.message_id = m.message_id AND ma.role_id = 1
                 ORDER BY ma.position LIMIT 1) AS from_name,
               left(regexp_replace(coalesce(b.body_text,''), '\\s+', ' ', 'g'), 240) AS snippet
          FROM search.messages m
          JOIN search.mailboxes mb USING (mailbox_id)
          LEFT JOIN search.message_bodies b ON b.message_id = m.message_id
         WHERE } . join(' AND ', @where) . qq{
         ORDER BY } . (length $q ? 'rank DESC, ' : '') . qq{coalesce(m.sent_at, m.received_at) DESC
         LIMIT ? OFFSET ?};

    my @final = (@sel_bind, @where_bind, $limit, $off);
    _assert_binds($sql, \@final);

    return $self->_scoped($account_id, sub ($db) { $db->query($sql, @final)->hashes });
}

# ------------------------------------------------------------------ drive
sub search_drive ($self, $account_id, $f) {
    my ($from, $to) = _date_bounds($f);
    my $q     = $f->{q}     // '';
    my $limit = $f->{limit} || 50;
    my $off   = $f->{offset} || 0;

    # Same per-clause bind collection as search_mail -- see the note there.
    my (@sel_bind, @where, @where_bind);
    push @where, 'i.account_id = ?'; push @where_bind, $account_id;
    # Trash is excluded unless explicitly asked for. drive's own soft-delete
    # discipline, carried into search: a deleted file must not come back as a
    # search hit.
    push @where, ($f->{in_trash} ? 'i.deleted_at IS NOT NULL' : 'i.deleted_at IS NULL');

    my $rank = q{0};
    if (length $q) {
        $rank = qq{ts_rank_cd(coalesce(x.tsv, ''::tsvector), $TSQ)};
        push @sel_bind, $q;
        push @where, "(x.tsv @@ $TSQ OR i.file_name ILIKE ?)";
        push @where_bind, $q, '%' . $q . '%';
    }
    if (defined $f->{mime} && $f->{mime} =~ m{\A([a-z]+)(?:/([a-z0-9.+-]+))?\z}) {
        push @where, 't.type = ?'; push @where_bind, $1;
        if (defined $2) { push @where, 't.subtype = ?'; push @where_bind, $2 }
    }
    # Include/exclude by type. The file's OWN type here; for mail the same
    # tokens match its attachments (see search_mail).
    for my $spec ([ $f->{type_in}, 0 ], [ $f->{type_ex}, 1 ]) {
        my ($frag, @b) = token_sql('t', $spec->[0], $spec->[1]);
        push @where, $frag and push @where_bind, @b if $frag;
    }
    # content_created_at is the file's OWN date and is NULL for everything
    # uploaded before drive migration 012, so the date filter falls back to
    # uploaded_at rather than silently excluding the whole existing corpus.
    push @where, 'coalesce(i.content_created_at, i.uploaded_at) >= ?::date'      and push @where_bind, $from if $from;
    push @where, 'coalesce(i.content_created_at, i.uploaded_at) <  (?::date + 1)' and push @where_bind, $to   if $to;
    push @where, 'i.size_bytes >= ?' and push @where_bind, $f->{min_size} if $f->{min_size};
    push @where, 'i.size_bytes <= ?' and push @where_bind, $f->{max_size} if $f->{max_size};

    my $sql = qq{
        SELECT i.drive_item_id, i.drive_file_id, i.file_uuid::text AS file_uuid,
               i.file_name, i.folder_path, i.size_bytes, i.uploaded_at,
               i.content_created_at, i.deleted_at,
               t.type || '/' || t.subtype AS mime_type,
               $rank AS rank,
               left(regexp_replace(coalesce(x.body_text,''), '\\s+', ' ', 'g'), 240) AS snippet
          FROM search.drive_items i
          LEFT JOIN search.mime_types t USING (mime_type_id)
          LEFT JOIN search.drive_item_text x USING (drive_item_id)
         WHERE } . join(' AND ', @where) . qq{
         ORDER BY } . (length $q ? 'rank DESC, ' : '') . qq{coalesce(i.content_created_at, i.uploaded_at) DESC
         LIMIT ? OFFSET ?};

    my @final = (@sel_bind, @where_bind, $limit, $off);
    _assert_binds($sql, \@final);

    return $self->_scoped($account_id, sub ($db) { $db->query($sql, @final)->hashes });
}

# Placeholder count must equal bind count. Postgres would reject a mismatch
# anyway, but it reports it as a type error on whichever parameter happened to
# line up wrong -- which reads like a data problem rather than a bug in this
# file, and sent the first diagnosis of exactly that failure in the wrong
# direction. Failing here names the real problem.
sub _assert_binds ($sql, $binds) {
    my $holes = () = $sql =~ /\?/g;
    die sprintf("Homelab::Search::Query: %d placeholders but %d bind values -- "
              . "a clause was added without its bind, or in the wrong order\n",
                $holes, scalar @$binds)
        unless $holes == @$binds;
    return 1;
}

# --------------------------------------------------------- one item, scoped
# Re-resolving an id under the account's own scope is what makes a link safe:
# an id that is not this account's simply does not come back, so there is no
# separate ownership check to forget.
sub message ($self, $account_id, $message_id) {
    return undef unless defined $message_id && $message_id =~ /\A\d+\z/;
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT m.message_id, m.subject, m.sent_at, m.received_at, m.size_bytes,
                   mb.name AS mailbox, s.sub AS maildir_sub, f.file_name,
                   a.local_part, d.domain
              FROM search.messages m
              JOIN search.mailboxes mb USING (mailbox_id)
              JOIN search.message_files f ON f.message_id = m.message_id
              JOIN search.maildir_subs s USING (sub_id)
              JOIN search.accounts a ON a.account_id = m.account_id
              JOIN search.domains  d ON d.domain_id  = a.domain_id
             WHERE m.message_id = ? AND m.account_id = ?}, $message_id, $account_id)->hash;
    });
}

# How much of this account has been indexed, as two monotonic numbers.
#
# These are the AI response cache's key, so that a cached answer can never
# outlive the data it described -- new mail or a new upload moves a
# watermark, the key changes, and the old entry is simply never looked up
# again. No invalidation hook to forget.
#
# max() over a serial primary key, not count(*): a count goes DOWN on a
# delete and can return to a value it held before, which would resurrect a
# stale entry. Both measured at well under a millisecond on the largest
# account (0.13 ms / 0.08 ms over 27k and 30k rows).
sub watermarks ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        my $r = $db->query(q{
            SELECT coalesce((SELECT max(message_id)    FROM search.messages    WHERE account_id = ?), 0) AS mail,
                   coalesce((SELECT max(drive_item_id) FROM search.drive_items WHERE account_id = ?), 0) AS drive
        }, $account_id, $account_id)->hash;
        return { mail => $r->{mail} + 0, drive => $r->{drive} + 0 };
    });
}

# Per-type metadata for a set of drive items, ready to display.
#
# $visibility is 'all' or 'safe'. 'safe' omits every key flagged sensitive
# in metadata_keys -- today that is the GPS trio. The filter is a WHERE
# clause rather than a post-filter in Perl, so a caller cannot forget it
# and a key added as sensitive later is excluded the moment it is added.
#
# Returns { drive_item_id => [ { key_name, label, kind, value }, ... ] }.
sub metadata_for ($self, $account_id, $ids, $visibility = 'all') {
    return {} unless $ids && @$ids;
    my @ids = grep { defined && /\A\d+\z/ } @$ids;
    return {} unless @ids;
    my $ph = join ',', ('?') x @ids;
    my $only_safe = $visibility eq 'safe' ? 'AND NOT k.sensitive' : '';
    return $self->_scoped($account_id, sub ($db) {
        my $rows = $db->query(qq{
            SELECT m.drive_item_id, k.key_name, k.label, k.value_kind,
                   m.value_text, m.value_num, m.value_at
              FROM search.drive_metadata m
              JOIN search.metadata_keys k USING (key_id)
             WHERE m.account_id = ? AND m.drive_item_id IN ($ph) $only_safe
             ORDER BY m.drive_item_id, k.key_name}, $account_id, @ids)->hashes;
        my %out;
        for my $r (@$rows) {
            my $v = $r->{value_kind} eq 'num' ? $r->{value_num}
                  : $r->{value_kind} eq 'at'  ? $r->{value_at}
                  :                             $r->{value_text};
            next unless defined $v;
            push @{ $out{ $r->{drive_item_id} } }, {
                key_name => $r->{key_name}, label => $r->{label},
                kind     => $r->{value_kind}, value => $v,
            };
        }
        return \%out;
    });
}

# The ALREADY-EXTRACTED text of one item, for AI mode's get_excerpt.
#
# Deliberately not message()/drive_item() with an extra column: those two
# exist to serve the BYTES from disk and are called on the download path.
# This one never touches the filesystem -- it reads what the indexer already
# parsed, which is the only thing that should ever be fed to a model. A
# request for a mail body here cannot be turned into a read of an arbitrary
# path, because there is no path in it.
#
# Scoped like everything else: an id belonging to another account returns
# undef because the row is not visible, not because of a check here.
sub excerpt ($self, $account_id, $kind, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return undef unless $kind eq 'mail' || $kind eq 'file';
    return $self->_scoped($account_id, sub ($db) {
        return $db->query(q{
            SELECT m.message_id AS id, m.subject AS title, b.body_text
              FROM search.messages m
              LEFT JOIN search.message_bodies b
                     ON b.message_id = m.message_id AND b.account_id = m.account_id
             WHERE m.message_id = ? AND m.account_id = ?}, $id, $account_id)->hash
            if $kind eq 'mail';
        return $db->query(q{
            SELECT i.drive_item_id AS id, i.file_name AS title, x.body_text
              FROM search.drive_items i
              LEFT JOIN search.drive_item_text x
                     ON x.drive_item_id = i.drive_item_id AND x.account_id = i.account_id
             WHERE i.drive_item_id = ? AND i.account_id = ?}, $id, $account_id)->hash;
    });
}

sub drive_item ($self, $account_id, $drive_item_id) {
    return undef unless defined $drive_item_id && $drive_item_id =~ /\A\d+\z/;
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT i.drive_item_id, i.file_uuid::text AS file_uuid, i.file_name,
                   i.size_bytes, i.deleted_at,
                   t.type || '/' || t.subtype AS mime_type
              FROM search.drive_items i
              LEFT JOIN search.mime_types t USING (mime_type_id)
             WHERE i.drive_item_id = ? AND i.account_id = ?}, $drive_item_id, $account_id)->hash;
    });
}

# Mailboxes and the top correspondents, for the filter dropdowns. Both are
# account-scoped reads, so the participant list is this user's own contacts
# and nobody else's.
sub mailboxes ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT mb.name, count(m.message_id) AS n
              FROM search.mailboxes mb
              LEFT JOIN search.messages m USING (mailbox_id)
             WHERE mb.account_id = ?
             GROUP BY 1 HAVING count(m.message_id) > 0
             ORDER BY 2 DESC}, $account_id)->hashes;
    });
}

sub counts ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT (SELECT count(*) FROM search.messages    WHERE account_id = ?) AS messages,
                   (SELECT count(*) FROM search.drive_items WHERE account_id = ? AND deleted_at IS NULL) AS drive_items},
            $account_id, $account_id)->hash;
    });
}

# The leaf types THIS account actually has, for the granular half of the
# type picker. Per-account on purpose: a global list of every mime type in
# the index would tell one person that somebody, somewhere, stores .dwg --
# small, but it is still a fact about another account, and the whole schema
# is built so that cannot happen by accident. Both sides are unioned because
# the picker is shared: a type may exist only as an attachment, or only on
# drive, and either way a person should be able to pick it.
sub mime_facets ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT type || '/' || subtype AS mime, sum(n)::bigint AS n FROM (
                SELECT t.type, t.subtype, count(*) AS n
                  FROM search.drive_items i JOIN search.mime_types t USING (mime_type_id)
                 WHERE i.account_id = ? AND i.deleted_at IS NULL
                 GROUP BY 1, 2
                UNION ALL
                SELECT t.type, t.subtype, count(*) AS n
                  FROM search.attachments a JOIN search.mime_types t USING (mime_type_id)
                 WHERE a.account_id = ?
                 GROUP BY 1, 2
            ) u GROUP BY 1 ORDER BY 2 DESC, 1}, $account_id, $account_id)->hashes;
    });
}

1;
