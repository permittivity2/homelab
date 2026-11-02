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
# ---------------------------------------------------- what is shared with me
#
# THE RULE SEARCH HAS TO INVENT. Drive does not have one: every
# authenticated route there is `WHERE user_email = ?`, and no authenticated
# route consults drive.shares at all. Cross-account access in drive is
# bearer-of-token on the unauthenticated /s/:token routes, so
# `shared_with_email` is a notification address and a list filter, never a
# check. What follows is therefore STRICTER than drive, deliberately -- it
# is what drive's own notification email already promises the recipient.
#
# RESOLVED LIVE, NEVER COPIED. The settled pattern in this schema is to
# carry a drive fact across at index time, as `searchable` does, and
# migrations/010 argues for it. That argument does not survive this case:
# a carried fact lags by one indexer pass, and for a REVOKED share the lag
# is the window in which an un-shared file is still searchable by someone
# else. Nothing here is written down, so there is nothing to go stale.
#
# Returns [{ owner_account_id, owner_email, drive_file_id }, ...].
#
# MEMOIZED FOR ONE REQUEST, and only one. Rendering a single search page
# asks this three times -- once for the results, once for the counts, once
# for the file-type facets -- and each pass rebuilt the whole list. With a
# 6,934-file share that was ~75ms of a 116ms render spent re-answering a
# question already answered microseconds earlier.
#
# NOT across requests, which looks tempting because share_fingerprint is
# cheap and would catch a grant or a revoke. It would not catch the other
# three things that change what is shared with you:
#
#   * a share passing its expires_at -- no row changes at all, time does;
#   * a file ADDED to a shared folder, which the grantee should now see;
#   * a file trashed in a shared folder, which they should now not.
#
# None of those touch drive.shares, so a fingerprint-keyed cache would
# serve a confidently stale allowlist. A request is short enough that
# nothing is expected to change inside it, which makes this window the
# only safe one.
sub shared_files ($self, $account_id, $email) {
    my $key = lc($email // '');
    return $self->{_shared_req}{$key} if $self->{_shared_req}{$key};
    return $self->{_shared_req}{$key} = $self->_resolve_shared_files($account_id, $email);
}

# Dropped at the start of every request by the before_dispatch hook in
# App.pm. A long-lived Query object with no such hook would be a cache
# that never expires, which is the bug this is shaped to avoid.
sub forget_shares ($self) { delete $self->{_shared_req}; return $self }

sub _resolve_shared_files ($self, $account_id, $email) {
    return [] unless defined $email && length $email;

    # ONE INDEXED PROBE for the overwhelmingly common case. Every account
    # that has been shared nothing -- which is almost all of them, always --
    # pays shares_shared_with_idx and stops here, before any recursion.
    # A MISSING GRANT MUST NOT TAKE SEARCH DOWN. drive.shares lives in
    # another app's schema and is reachable only by an explicit
    # GRANT SELECT. Deploying this package before that grant is applied --
    # which is exactly what happened the first time -- made every
    # authenticated search 500, because this is on the render path of the
    # main page, the facets, the counts and the serving routes.
    #
    # So a permission error degrades: no shared results, loudly logged,
    # the rest of search untouched. ONLY a permission error. Any other
    # failure propagates, because turning a real database fault into
    # "nothing is shared with you" would be the same leak-shaped silence
    # this feature exists to avoid, pointed the other way.
    return [] if ($self->{_no_share_grant} // 0);

    my $db = $self->pg->db;
    my $live = eval { $db->query(q{
        SELECT s.file_id, s.folder_id
          FROM drive.shares s
          LEFT JOIN drive.files   f ON f.id = s.file_id
          LEFT JOIN drive.folders d ON d.id = s.folder_id
         -- NOT NULL FIRST, and it is the clause that matters most: one
         -- table holds both kinds of share, and a NULL recipient means a
         -- PUBLIC LINK. Without this, every public link in the system
         -- would be published into every account's search results.
         WHERE s.shared_with_email IS NOT NULL
           AND lower(s.shared_with_email) = lower(?)
         -- The remaining five are drive's own _live_share predicate
         -- (drive/lib/Homelab/Drive/App.pm:2036), copied so the two can be
         -- diffed. Keep them in that order and in that shape.
           AND s.revoked_at IS NULL
           AND (s.expires_at IS NULL OR s.expires_at > now())
           AND (s.file_id   IS NULL OR f.deleted_at IS NULL)
           AND (s.folder_id IS NULL OR d.deleted_at IS NULL)}, $email)->hashes };
    if (my $err = $@) {
        die $err unless $err =~ /permission denied/i;
        $self->{_no_share_grant} = 1;
        $self->log->error(
            'search: cannot read drive.shares -- files shared with this '
          . 'account will NOT be searchable. Run: GRANT SELECT ON '
          . 'drive.shares TO homelab_search_runtime') if $self->log;
        return [];
    }
    return [] unless @$live;

    my @file_ids   = grep { defined } map { $_->{file_id} }   @$live;
    my @folder_ids = grep { defined } map { $_->{folder_id} } @$live;

    # A FOLDER SHARE IS THE WHOLE SUBTREE. drive settled this deliberately
    # (App.pm:2320) after a first cut that listed only the top level and so
    # hid content the owner believed they had shared.
    #
    # deleted_at IS NULL in BOTH the seed and the recursive step, exactly as
    # drive's _share_tree_sql has it: trashing an intermediate folder prunes
    # its entire subtree, even where a descendant's own deleted_at is null.
    # Testing only the file's own folder would over-grant.
    #
    # UNION, not UNION ALL: cycles are impossible by construction today and
    # this does not loop forever if that ever stops being true.
    my @rows;
    if (@folder_ids) {
        push @rows, $db->query(q{
            WITH RECURSIVE share_tree AS (
                SELECT id FROM drive.folders
                 WHERE id = ANY(?) AND deleted_at IS NULL
                UNION
                SELECT c.id FROM drive.folders c
                  JOIN share_tree t ON c.parent_folder_id = t.id
                 WHERE c.deleted_at IS NULL
            )
            SELECT f.id AS drive_file_id, lower(f.user_email) AS owner_email
              FROM drive.files f
             WHERE f.folder_id IN (SELECT id FROM share_tree)
               AND f.deleted_at IS NULL},
            '{' . join(',', @folder_ids) . '}')->hashes->@*;
    }
    if (@file_ids) {
        push @rows, $db->query(q{
            SELECT f.id AS drive_file_id, lower(f.user_email) AS owner_email
              FROM drive.files f
             WHERE f.id = ANY(?) AND f.deleted_at IS NULL},
            '{' . join(',', @file_ids) . '}')->hashes->@*;
    }
    return [] unless @rows;

    # Owner email -> account id, the same mapping the indexer uses. An owner
    # with no indexed account has nothing in the index to find, so dropping
    # them here is correct rather than a silent failure.
    my %acct;
    for my $e (do { my %s; grep { !$s{$_}++ } map { $_->{owner_email} } @rows }) {
        my $a = $self->account_for($e) or next;
        $acct{$e} = $a->{account_id};
    }

    # A share pointing back at the asker is not a share. Drive refuses to
    # create one, but a renamed address could leave one behind, and scoping
    # a "shared" pass to the asker's own account would quietly bypass the
    # searchable flag they set on their own files.
    my %seen;
    return [ grep { $_->{owner_account_id}
                    && $_->{owner_account_id} != $account_id
                    && !$seen{ $_->{drive_file_id} }++ }
             map  { { %$_, owner_account_id => $acct{ $_->{owner_email} } } } @rows ];
}

# A fingerprint of this account's live shares, for the AI answer cache.
#
# The cache key is (account, query, watermarks, contract). Watermarks are
# max(drive_item_id) per account and DO NOT MOVE when a share is granted or
# revoked -- so without this a revoked share would keep being described by
# a cached answer for the rest of the TTL.
#
# FOUR numbers, not three. The first three move on a grant (count, max id)
# and on a revoke (max timestamp). None of them moves when a share passes
# its `expires_at`: no row is written, time simply passes, and this query
# does not filter on liveness. An expired share is no longer shared, so a
# cached answer describing its files is exactly the staleness this whole
# design exists to prevent -- the live search path already gets expiry
# right, and only the answer cache could lag. Hence the fourth: a count of
# the shares that are live AT THIS MOMENT, which falls by one the instant
# an expiry passes.
sub share_fingerprint ($self, $email) {
    return '0:0:0:0' unless defined $email && length $email;
    return '0:0:0:0' if ($self->{_no_share_grant} // 0);
    my $r = eval { $self->pg->db->query(q{
        SELECT count(*)::text AS n,
               coalesce(max(id), 0)::text AS hi,
               coalesce(extract(epoch from max(coalesce(revoked_at, created_at)))::bigint, 0)::text AS mt,
               count(*) FILTER (WHERE revoked_at IS NULL
                                  AND (expires_at IS NULL OR expires_at > now()))::text AS live
          FROM drive.shares
         WHERE shared_with_email IS NOT NULL
           AND lower(shared_with_email) = lower(?)}, $email)->hash };
    if (my $err = $@) {
        die $err unless $err =~ /permission denied/i;
        $self->{_no_share_grant} = 1;
        return '0:0:0:0';
    }
    return join ':', $r->{n}, $r->{hi}, $r->{mt}, $r->{live};
}

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
    # A folder its owner marked non-searchable. The file is still indexed
    # -- its text and metadata are there, it still opens in drive -- it
    # simply never comes back from a search. Unconditional: there is no
    # caller flag to pass that turns this off, because an "include private
    # results" option is how it would end up on a shared screen.
    push @where, 'i.searchable';

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
    # Photos of a named person: an indexed join through the face table,
    # not a LIKE over a joined string -- which is what made "Jeff" also
    # match "Jefferson".
    if (length($f->{person} // '')) {
        push @where, q{EXISTS (SELECT 1 FROM search.photo_faces pf
                                 JOIN search.people pp ON pp.person_id = pf.person_id
                                WHERE pf.drive_item_id = i.drive_item_id
                                  AND pf.account_id = i.account_id
                                  AND pp.display_name ILIKE ?)};
        push @where_bind, '%' . $f->{person} . '%';
    }
    # A tag matches the node AND everything under it, so "Utah" finds the
    # photo its owner filed under Places|Earth|USA|Utah|Moab|Arches.
    #
    # MATCHED AGAINST THE LEAF'S PATH, not against the tag node. A photo is
    # linked only to the most specific tag it carries -- the ancestors
    # exist as rows but nothing points at them -- so asking "which tag node
    # is named Utah" finds the node and then no photo. Asking instead
    # "which photo's tag path contains Utah as a segment" is the question
    # that has the answer.
    #
    # Four patterns because a segment can sit anywhere: the whole path, the
    # start, the end, or the middle. The leading wildcards cost an index
    # scan, which is irrelevant here -- this runs over an account's tag
    # list, which is tens of rows, not its photos.
    if (length($f->{tag} // '')) {
        my $tg = $f->{tag};
        push @where, q{EXISTS (SELECT 1 FROM search.photo_tags pt
                                 JOIN search.tags tg ON tg.tag_id = pt.tag_id
                                WHERE pt.drive_item_id = i.drive_item_id
                                  AND pt.account_id = i.account_id
                                  AND (tg.path ILIKE ? OR tg.path ILIKE ?
                                    OR tg.path ILIKE ? OR tg.path ILIKE ?))};
        push @where_bind, $tg, "$tg|%", "%|$tg", "%|$tg|%";
    }
    push @where, 'i.size_bytes >= ?' and push @where_bind, $f->{min_size} if $f->{min_size};
    push @where, 'i.size_bytes <= ?' and push @where_bind, $f->{max_size} if $f->{max_size};
    # THE SHARED-PASS ALLOWLIST. Only ever set by search_drive_all, and only
    # for a pass that is scoped to somebody ELSE's account -- so this is the
    # clause standing between "the files they shared with me" and "their
    # whole drive". It is an explicit id set computed from drive.shares, not
    # a predicate a caller can widen, and an empty set never gets here:
    # search_drive_all does not open a pass without one.
    if (my $ids = $f->{file_ids}) {
        die "Homelab::Search::Query: refusing an empty shared-file allowlist\n"
            unless ref $ids eq 'ARRAY' && @$ids;
        die "Homelab::Search::Query: non-numeric id in the shared-file allowlist\n"
            if grep { !defined || !/\A[0-9]+\z/ } @$ids;
        push @where, 'i.drive_file_id = ANY(?)';
        push @where_bind, '{' . join(',', @$ids) . '}';
    }

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

# ------------------------------------------- own files plus borrowed ones
#
# TWO QUESTIONS, NOT ONE WIDER QUESTION. The first pass is the ordinary
# account-scoped search, unchanged. Then, per owner who has shared
# something with this account, a SECOND pass scoped to THAT OWNER with an
# explicit allowlist of the file ids the share resolves to.
#
# Scoping each borrowed pass to its owner is what makes the rest of the
# schema work untouched: row-level security stays a flat
# `account_id = one GUC` on every table and the composite foreign keys
# still hold. Widening the policies instead would have meant five of them,
# and one that recurses into the table it guards.
#
# The corollary, which cost a round of live verification to notice: a
# borrowed row's CHILD rows -- its metadata, its tagged people, its tag
# paths -- also carry the owner's account_id, so looking them up in the
# asking account returns nothing at all. Not an error; RLS matches zero
# rows and the page renders a photo with no camera, no people and no
# tags. metadata_for_rows / faces_and_tags_for_rows below exist for
# exactly that, and every caller that has a mixed-owner row list must use
# them rather than the single-account forms.
#
# The allowlist is the boundary. It comes from drive.shares via
# shared_files and never from a request parameter, and search_drive itself
# refuses an empty one -- so a bug that produced no ids fails loudly rather
# than running an unrestricted query inside someone else's account.
#
# $f->{shared} is 'include' (default), 'exclude' or 'only'.
sub search_drive_all ($self, $account_id, $email, $f) {
    my $mode = $f->{shared} // 'include';
    my @rows;
    push @rows, @{ $self->search_drive($account_id, $f) } unless $mode eq 'only';
    return \@rows if $mode eq 'exclude';

    my $shared = $self->shared_files($account_id, $email);
    if (@$shared) {
        my %by_owner;
        push @{ $by_owner{ $_->{owner_account_id} }{ids} }, $_->{drive_file_id} for @$shared;
        $by_owner{ $_->{owner_account_id} }{email} = $_->{owner_email} for @$shared;

        for my $owner (sort keys %by_owner) {
            # offset is deliberately dropped for a borrowed pass: paging is
            # applied to the MERGED list below, and an offset applied twice
            # would silently skip rows.
            my %g = (%$f, file_ids => $by_owner{$owner}{ids}, offset => 0);
            delete $g{shared};
            my $got = $self->search_drive($owner, \%g);
            # Both the email (shown on the page) and the account id (used
            # to resolve this row's metadata, people and tags back in the
            # scope that owns them -- see metadata_for_rows).
            for my $r (@$got) {
                $r->{shared_by}            = $by_owner{$owner}{email};
                $r->{shared_by_account_id} = $owner;
            }
            push @rows, @$got;
        }
    }

    # Re-sort the merged list the way a single pass would have ordered it,
    # then page. Borrowed rows are not pinned below owned ones: a result is
    # ranked on how well it matches, which is the only thing the person
    # asking cares about.
    my $ranked = length($f->{q} // '');
    @rows = sort {
        ($ranked ? ($b->{rank} // 0) <=> ($a->{rank} // 0) : 0)
          || (($b->{content_created_at} // $b->{uploaded_at} // '')
              cmp ($a->{content_created_at} // $a->{uploaded_at} // ''))
    } @rows;

    my $off   = $f->{offset} || 0;
    my $limit = $f->{limit}  || 50;
    return [] if $off >= @rows;
    my $end = $off + $limit - 1;
    $end = $#rows if $end > $#rows;
    return [ @rows[$off .. $end] ];
}

# ---------------------------------------------- mixed-owner row lists
#
# A result list from search_drive_all may hold rows from several accounts:
# the asker's own, plus one group per owner who has shared something. Every
# child table is under the same `account_id = current_setting(...)` policy
# as its parent, so one query in the asker's scope can only ever resolve
# the asker's own rows -- the borrowed ones come back empty and the page
# quietly loses the camera, the people and the tag paths.
#
# So: group the ids by the account that owns them, one scoped query per
# group, merge. Keyed on drive_item_id, which is unique across accounts
# (it is a BIGSERIAL), so the merged hash cannot collide.
sub _ids_by_owner ($self, $account_id, $rows) {
    my %g;
    push @{ $g{ $_->{shared_by_account_id} // $account_id } }, $_->{drive_item_id}
        for grep { defined $_->{drive_item_id} } @$rows;
    return \%g;
}

sub metadata_for_rows ($self, $account_id, $rows, $visibility = 'all') {
    my $g = $self->_ids_by_owner($account_id, $rows);
    my %out;
    for my $owner (sort keys %$g) {
        my $m = $self->metadata_for($owner, $g->{$owner}, $visibility);
        @out{ keys %$m } = values %$m;
    }
    return \%out;
}

sub faces_and_tags_for_rows ($self, $account_id, $rows) {
    my $g = $self->_ids_by_owner($account_id, $rows);
    my %out;
    for my $owner (sort keys %$g) {
        my $m = $self->faces_and_tags_for($owner, $g->{$owner});
        @out{ keys %$m } = values %$m;
    }
    return \%out;
}

# One item the asking account may SEE -- its own, or one shared with it.
#
# This is the whole boundary for serving bytes. Paths::drive_blob_for takes
# a uuid and has no account notion, so an item resolved here is an item
# served; there is no second check further down and there should not be a
# second place to forget one.
sub visible_drive_item ($self, $account_id, $email, $id) {
    my $own = $self->drive_item($account_id, $id);
    return $own if $own;

    my $shared = $self->shared_files($account_id, $email);
    return undef unless @$shared;
    my %ok = map { $_->{drive_file_id} => $_ } @$shared;

    # Resolved in the OWNER's scope, then checked against the allowlist --
    # both, not either. The scope makes the row visible at all; the
    # allowlist is what stops a borrowed id from reaching the rest of that
    # owner's drive.
    for my $owner (do { my %s; grep { !$s{$_}++ } map { $_->{owner_account_id} } @$shared }) {
        my $row = $self->drive_item($owner, $id) or next;
        next unless $row->{drive_file_id} && $ok{ $row->{drive_file_id} };
        # THE OWNER'S PRIVATE FLAG WINS, even here. search_drive filters on
        # `searchable` so a Private file never appears in results -- but
        # this path takes an id, and without the same test a borrowed id
        # would open a file its owner had marked unsearchable. Not applied
        # to the own-item branch above: the owner may always open their
        # own, which is the point of the flag meaning "hide from search"
        # rather than "lock".
        next unless $row->{searchable};
        $row->{shared_by} = $ok{ $row->{drive_file_id} }{owner_email};
        return $row;
    }
    return undef;
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

# Who appears in this account's photos, with counts. The list a person
# wants before they search: "show me everyone I have tagged".
sub people ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        return $db->query(q{
            SELECT p.person_id, p.display_name, count(f.face_id)::int AS photos
              FROM search.people p
              LEFT JOIN search.photo_faces f ON f.person_id = p.person_id
             WHERE p.account_id = ?
             GROUP BY 1, 2 ORDER BY 3 DESC, 2}, $account_id)->hashes;
    });
}

# The tag tree, with how many photos sit at or under each node. Ordered by
# path so the caller can render it as a tree without a second query.
sub tags ($self, $account_id) {
    return $self->_scoped($account_id, sub ($db) {
        return $db->query(q{
            SELECT t.tag_id, t.path, t.name, t.parent_id,
                   (SELECT count(*) FROM search.photo_tags pt
                     JOIN search.tags d ON d.tag_id = pt.tag_id
                    WHERE pt.account_id = t.account_id
                      AND (d.path = t.path OR d.path LIKE t.path || '|%'))::int AS photos
              FROM search.tags t
             WHERE t.account_id = ?
             ORDER BY t.path}, $account_id)->hashes;
    });
}

# Faces and tags for a set of items, for display under each result.
sub faces_and_tags_for ($self, $account_id, $ids) {
    return {} unless $ids && @$ids;
    my @ids = grep { defined && /\A\d+\z/ } @$ids;
    return {} unless @ids;
    my $ph = join ',', ('?') x @ids;
    return $self->_scoped($account_id, sub ($db) {
        my %out;
        my $f = $db->query(qq{
            SELECT f.drive_item_id, f.person_id, p.display_name,
                   f.area_x, f.area_y, f.area_w, f.area_h
              FROM search.photo_faces f
              LEFT JOIN search.people p ON p.person_id = f.person_id
             WHERE f.account_id = ? AND f.drive_item_id IN ($ph)
             ORDER BY f.drive_item_id, p.display_name NULLS LAST},
            $account_id, @ids)->hashes;
        push @{ $out{ $_->{drive_item_id} }{faces} }, $_ for @$f;
        my $g = $db->query(qq{
            SELECT pt.drive_item_id, t.tag_id, t.path, t.name
              FROM search.photo_tags pt JOIN search.tags t USING (tag_id)
             WHERE pt.account_id = ? AND pt.drive_item_id IN ($ph)
             ORDER BY pt.drive_item_id, t.path}, $account_id, @ids)->hashes;
        push @{ $out{ $_->{drive_item_id} }{tags} }, $_ for @$g;
        return \%out;
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
                   i.size_bytes, i.deleted_at, i.searchable,
                   -- drive_file_id is what a share is expressed in, so
                   -- visible_drive_item cannot check its allowlist without
                   -- it. The dates are here because the raw-metadata page
                   -- prints them and was rendering a blank line instead.
                   i.drive_file_id, i.content_created_at, i.uploaded_at,
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

sub counts ($self, $account_id, $email = undef) {
    my $c = $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT (SELECT count(*) FROM search.messages    WHERE account_id = ?) AS messages,
                   (SELECT count(*) FROM search.drive_items WHERE account_id = ? AND deleted_at IS NULL) AS drive_items},
            $account_id, $account_id)->hash;
    });
    # Counted SEPARATELY, not added in. "37,433 files indexed for you" would
    # be a lie about whose they are, and the number people check this line
    # for is how much of their own is in.
    $c->{shared_items} = scalar @{ $self->shared_files($account_id, $email) };
    return $c;
}

# The leaf types THIS account actually has, for the granular half of the
# type picker. Per-account on purpose: a global list of every mime type in
# the index would tell one person that somebody, somewhere, stores .dwg --
# small, but it is still a fact about another account, and the whole schema
# is built so that cannot happen by accident. Both sides are unioned because
# the picker is shared: a type may exist only as an attachment, or only on
# drive, and either way a person should be able to pick it.
#
# The two sides are also counted SEPARATELY, because which side a type
# lives on decides whether it can match at all. With "Files" unticked,
# offering MP4 video -- a type this account has only on drive -- is
# offering a filter that provably returns nothing, with no hint why. The
# picker uses drive_n/mail_n to drop exactly those.
#
# Drive's side honours `searchable`, so a type that exists only inside a
# folder marked private does not appear in the picker either.
sub mime_facets ($self, $account_id, $email = undef) {
    my $own = $self->_mime_facets_scoped($account_id, undef);

    # Types that exist only among borrowed files still have to be offered,
    # or the picker quietly cannot narrow to them: an account owning three
    # text files and holding seven thousand shared photos would be shown no
    # way to ask for a photo. Counted per owner, under that owner's scope,
    # restricted to the same allowlist the search uses.
    my $shared = $self->shared_files($account_id, $email);
    return $own unless @$shared;

    my %by_owner;
    push @{ $by_owner{ $_->{owner_account_id} } }, $_->{drive_file_id} for @$shared;

    my %merged;
    for my $r (@$own) { $merged{ $r->{mime} } = { %$r } }
    for my $owner (sort keys %by_owner) {
        for my $r (@{ $self->_mime_facets_scoped($owner, $by_owner{$owner}) }) {
            my $m = $merged{ $r->{mime} } ||= { mime => $r->{mime}, n => 0, drive_n => 0, mail_n => 0 };
            $m->{$_} += $r->{$_} for qw(n drive_n);
        }
    }
    return [ sort { $b->{n} <=> $a->{n} || $a->{mime} cmp $b->{mime} } values %merged ];
}

# One account's facets. $ids restricts to an allowlist of drive file ids and
# drops the mail half, which is what a borrowed pass wants: another
# account's attachments are not shared by sharing a file.
sub _mime_facets_scoped ($self, $account_id, $ids) {
    if ($ids) {
        return [] unless @$ids;
        return $self->_scoped($account_id, sub ($db) {
            $db->query(q{
                SELECT t.type || '/' || t.subtype AS mime, count(*)::bigint AS n,
                       count(*)::bigint AS drive_n, 0::bigint AS mail_n
                  FROM search.drive_items i JOIN search.mime_types t USING (mime_type_id)
                 WHERE i.account_id = ? AND i.deleted_at IS NULL AND i.searchable
                   AND i.drive_file_id = ANY(?)
                 GROUP BY 1}, $account_id, '{' . join(',', @$ids) . '}')->hashes;
        });
    }
    return $self->_scoped($account_id, sub ($db) {
        $db->query(q{
            SELECT type || '/' || subtype AS mime,
                   sum(n)::bigint       AS n,
                   sum(drive_n)::bigint AS drive_n,
                   sum(mail_n)::bigint  AS mail_n
              FROM (
                SELECT t.type, t.subtype, count(*) AS n, count(*) AS drive_n, 0 AS mail_n
                  FROM search.drive_items i JOIN search.mime_types t USING (mime_type_id)
                 WHERE i.account_id = ? AND i.deleted_at IS NULL AND i.searchable
                 GROUP BY 1, 2
                UNION ALL
                SELECT t.type, t.subtype, count(*) AS n, 0 AS drive_n, count(*) AS mail_n
                  FROM search.attachments a JOIN search.mime_types t USING (mime_type_id)
                 WHERE a.account_id = ?
                 GROUP BY 1, 2
            ) u GROUP BY 1 ORDER BY 2 DESC, 1}, $account_id, $account_id)->hashes;
    });
}

1;
