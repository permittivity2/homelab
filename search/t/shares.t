use strict;
use warnings;
use Test::More;
use lib 'lib';
use Homelab::Search::Query;

# Search had to INVENT the rule for "may this account see that account's
# file", because drive does not have one: every authenticated route there
# is `WHERE user_email = ?`, and cross-account access is bearer-of-token on
# unauthenticated routes. So these are not a restatement of drive's
# behaviour -- they are the specification, and the only place it is written
# down besides the SQL.
#
# The SQL itself needs Postgres, so what is asserted here is the shape of
# the predicate and the decisions layered on top of it. The live checks in
# the plan cover the rest.

# ------------------------------------------- the predicate, clause by clause
{
    my $src = do { open my $fh, '<', 'lib/Homelab/Search/Query.pm' or die $!;
                   local $/; <$fh> };
    my ($sql) = $src =~ /(sub shared_files .*?return \[\] unless \@\$live;)/s;
    ok $sql, 'shared_files is where the share predicate lives';

    # THE ONE THAT MATTERS MOST. drive.shares holds two different things:
    # a share to a named person, and a public link, told apart only by
    # shared_with_email being NULL. Drop this clause and every public link
    # in the system is published into every account's search results.
    like $sql, qr/s\.shared_with_email IS NOT NULL/,
        'a public link share is excluded by a NOT NULL test, not by luck';

    # Drive matches the recipient case-insensitively (App.pm:2263) and
    # stores whatever case the sharer typed. Comparing exactly would make a
    # share to Huuvola@ invisible to huuvola@.
    like $sql, qr/lower\(s\.shared_with_email\) = lower\(\?\)/,
        'the recipient is matched case-insensitively, as drive does';

    # The four liveness conditions, copied from drive's _live_share so the
    # two can be diffed. A missing one is a share that outlives its own
    # revocation.
    like $sql, qr/s\.revoked_at IS NULL/,              'revoked shares are dead';
    like $sql, qr/s\.expires_at IS NULL OR s\.expires_at > now\(\)/,
        'expired shares are dead';
    like $sql, qr/s\.file_id\s+IS NULL OR f\.deleted_at IS NULL/,
        'a share of a trashed file is dead';
    like $sql, qr/s\.folder_id IS NULL OR d\.deleted_at IS NULL/,
        'a share of a trashed folder is dead';
}

# --------------------------------------------- the subtree, and its pruning
{
    my $src = do { open my $fh, '<', 'lib/Homelab/Search/Query.pm' or die $!;
                   local $/; <$fh> };
    my ($tree) = $src =~ /(WITH RECURSIVE share_tree.*?\)\n)/s;
    ok $tree, 'a folder share resolves through a recursive CTE';

    # A folder share is the whole subtree -- drive settled that deliberately
    # after a first cut that listed only the top level.
    like $tree, qr/JOIN share_tree t ON c\.parent_folder_id = t\.id/,
        'the subtree is walked, not just the shared folder itself';

    # deleted_at IS NULL in BOTH steps. In the seed alone, trashing an
    # intermediate folder would leave its children reachable through a
    # parent that no longer exists -- live rows, no live path to them.
    my @guards = $tree =~ /deleted_at IS NULL/g;
    is scalar @guards, 2,
        'trashed folders are pruned in the seed AND the recursive step';

    like $tree, qr/\n\s*UNION\n/,
        'UNION, not UNION ALL -- a cycle would otherwise never terminate';
}

# ------------------------------------------------- the allowlist is a fence
# The borrowed pass runs INSIDE the owner's account scope, so the id list is
# the only thing between "what they shared" and "their whole drive". These
# assert it cannot be skipped or widened.
{
    my $q = Homelab::Search::Query->new;
    my %base = (q => '', person => '', tag => '', mailbox => '', mime => '',
                from => '', to => '', type_in => [], type_ex => [],
                in_trash => 0, has_attachments => 0, source => 'drive',
                limit => 10, offset => 0);

    my $err = '';
    eval { $q->search_drive(99, { %base, file_ids => [] }); 1 } or $err = $@;
    like $err, qr/refusing an empty shared-file allowlist/,
        'an empty allowlist is refused, not treated as "no restriction"';

    $err = '';
    eval { $q->search_drive(99, { %base, file_ids => ['7 OR 1=1'] }); 1 } or $err = $@;
    like $err, qr/non-numeric id in the shared-file allowlist/,
        'a non-numeric id is refused before it reaches the array literal';
}

# ------------------------------------------------------ the layered refusals
{
    my $src = do { open my $fh, '<', 'lib/Homelab/Search/Query.pm' or die $!;
                   local $/; <$fh> };

    # A share pointing at the asker would scope a "borrowed" pass to their
    # own account, quietly bypassing the searchable flag on their own files.
    like $src, qr/\$_->\{owner_account_id\} != \$account_id/,
        'a share back to the asker is not treated as a share';

    # visible_drive_item takes an id, so it needs the searchable test that
    # search_drive applies to results -- otherwise a borrowed id opens a
    # file its owner marked Private.
    my ($vis) = $src =~ /(sub visible_drive_item.*?\n\}\n)/s;
    ok $vis, 'visible_drive_item exists';
    like $vis, qr/next unless \$row->\{searchable\}/,
        "the owner's Private flag still wins when a borrowed id is resolved";
    like $vis, qr/next unless \$row->\{drive_file_id\} && \$ok\{/,
        'and the id is checked against the allowlist, not just the scope';
}

# ----------------------------------------------- the cache cannot outlive it
{
    my $src = do { open my $fh, '<', 'lib/Homelab/Search/AI.pm' or die $!;
                   local $/; <$fh> };
    like $src, qr/share_fp = \?/,  'the AI cache key includes the share fingerprint';
    like $src, qr/share_fingerprint/,
        '...and it is read live, because watermarks cannot see a revoke';
}

# ------------------------------------- a missing grant degrades, not 500s
# drive.shares is reachable only by an explicit cross-schema GRANT, and
# this code is on the render path of the main page, the facets, the counts
# and the serving routes. Deployed before the grant, it made every
# authenticated search 500 -- which is how this test came to exist.
{
    my $src = do { open my $fh, '<', 'lib/Homelab/Search/Query.pm' or die $!;
                   local $/; <$fh> };
    my ($fn) = $src =~ /(sub shared_files.*?\n\}\n)/s;
    like $fn, qr/die \$err unless \$err =~ \/permission denied\/i/,
        'a permission error degrades to no shared results';
    like $fn, qr/\$self->\{_no_share_grant\}/,
        '...once per process, not once per query';
    like $fn, qr/GRANT SELECT ON/,
        '...and the log line names the exact fix';

    # The narrowness is the point: a real database fault must NOT become
    # "nothing is shared with you", which is this feature's own failure
    # mode pointed the other way.
    unlike $fn, qr/eval \{.*\};\s*return \[\] if \$\@/s,
        'any other error still propagates';
}

# --------------------------------------------------- the double dereference
# `@{ $db->query(...)->hashes->@* }` is a dereference twice over: the
# postfix ->@* already flattens the collection to a list, and wrapping that
# in @{ BLOCK } evaluates the block in SCALAR context, so the block yields
# the row COUNT and Perl then tries to use that integer as a reference:
#
#     Can't use string ("6934") as an ARRAY ref while "strict refs" in use
#
# It shipped in 0.3.1 and survived 442 tests because shared_files returned
# early for every account until the GRANT existed -- the subtree query had
# never once run with rows in it. Every assertion above this point is a
# regex over the source, which is the only kind of test this file can hold
# without a live Postgres, and a regex cannot see a runtime context bug.
#
# So the guard is a lint, applied to the whole library rather than to the
# one function, because the mistake is a general one and the next instance
# will be somewhere else.
{
    my @bad;
    for my $f (glob 'lib/Homelab/Search/*.pm lib/Homelab/Search/*/*.pm') {
        open my $fh, '<', $f or next;
        while (my $line = <$fh>) {
            push @bad, "$f:$." if $line =~ /\@\{.*->\@\*/;
        }
    }
    is_deeply \@bad, [],
        'no @{ ... ->@* } anywhere: dereferencing a flattened list puts it '
      . 'in scalar context and hands you the count instead of the rows';
}

# ------------------------------------------- the borrowed row's child rows
# Finding a shared file is half the job. Its metadata, its tagged people
# and its tag paths live in search.drive_metadata / photo_faces /
# photo_tags, all of which carry the OWNER's account_id under the same RLS
# policy -- so a lookup in the asking account matches zero rows and the
# page renders a borrowed photo with no camera, no people and no tags.
#
# That is what the live check found after the headline requirement already
# worked: 0 metadata values for the grantee, 65 for the owner, same five
# photos. Nothing failed; the rows were simply invisible.
{
    my $qsrc = do { open my $fh, '<', 'lib/Homelab/Search/Query.pm' or die $!;
                    local $/; <$fh> };
    like $qsrc, qr/sub metadata_for_rows/,
        'there is an owner-aware metadata lookup';
    like $qsrc, qr/sub faces_and_tags_for_rows/,
        '...and an owner-aware people/tags lookup';
    like $qsrc, qr/\$r->\{shared_by_account_id\} = \$owner/,
        'a borrowed row carries the owner ACCOUNT, not just the owner email, '
      . 'because that is what the child lookups have to be scoped to';

    # The page must use them. Asking in the asker's own account is not an
    # error, which is exactly why this needs asserting rather than noticing.
    my $asrc = do { open my $fh, '<', 'lib/Homelab/Search/App.pm' or die $!;
                    local $/; <$fh> };
    like $asrc, qr/metadata_for_rows\(/,       'the page uses the owner-aware metadata lookup';
    like $asrc, qr/faces_and_tags_for_rows\(/, 'the page uses the owner-aware people/tags lookup';
    unlike $asrc, qr/query->metadata_for\(/,
        '...and not the single-account form, which silently drops borrowed rows';
    unlike $asrc, qr/query->faces_and_tags_for\(/,
        '...likewise for people and tags';
}

# ------------------------------------------------- AI mode sees shares too
# The plan said "AI mode needs no tool change", and that was wrong in two
# places: the tool called the own-only search_drive, and _resolve hydrated
# citations with the own-only drive_item -- so even once the tool returned
# shared rows, every citation of one would have been dropped as
# unresolvable and the answer would have described files the page did not
# list. Live, before the fix: plain search found 6,934 shared photos and
# AI mode answered "I couldn't find any photos from Arches National Park".
{
    my $tsrc = do { open my $fh, '<', 'lib/Homelab/Search/AI/Tools.pm' or die $!;
                    local $/; <$fh> };
    like $tsrc, qr/search_drive_all\(\$account_id, \$email/,
        'the drive tool answers from shared files as well as owned ones';
    unlike $tsrc, qr/\$query->search_drive\(/,
        '...and no longer from the own-only pass';

    my $aisrc = do { open my $fh, '<', 'lib/Homelab/Search/AI.pm' or die $!;
                     local $/; <$fh> };
    like $aisrc, qr/visible_drive_item\(\$account_id, \$email, \$id\)/,
        'a cited file is hydrated through the share-aware lookup';
    unlike $aisrc, qr/query->drive_item\(/,
        '...not the own-only one, which would drop every shared citation';

    # $email must not reach the model. It is a positional Perl argument to
    # run_tool and nothing else; t/ai.t asserts the schemas separately.
    unlike $tsrc, qr/description => '[^']*\bemail\b[^']*(?:shared|grantee)/,
        'the email is plumbing, not a tool parameter';
}

done_testing;
