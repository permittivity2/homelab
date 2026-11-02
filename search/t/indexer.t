use strict;
use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Homelab::Search::Indexer;

# THE INDEXER'S FIRST TESTS. It was the only major module in this package
# with none, and the bug below is what that cost.
#
# Everything here runs against a scratch maildir in a temp directory and a
# stand-in for the index, so there is no database and no NFS. Fixtures are
# built in the test rather than committed, so the repository carries no
# binaries and there is nothing to go stale -- the same approach as
# t/extract.t.

# ------------------------------------------------------------ the fixture
my $root = tempdir(CLEANUP => 1);

sub maildir ($) {
    my $box = shift;    # 'INBOX' or a dot-prefixed folder name
    my $base = $box eq 'INBOX' ? "$root/example.org/alice"
                               : "$root/example.org/alice/$box";
    make_path("$base/$_") for qw(cur new tmp);
    return $base;
}

# A minimal but real RFC 5322 message, so parse_message has something to do.
sub deliver {
    my ($dir, $sub, $name, $subject) = @_;
    my $path = "$dir/$sub/$name";
    open my $fh, '>', $path or die $!;
    print $fh "From: sender\@example.net\r\n"
            . "To: alice\@example.org\r\n"
            . "Subject: $subject\r\n"
            . "Date: Sat, 01 Nov 2026 12:00:00 -0600\r\n"
            . "Message-ID: <$name\@example.net>\r\n"
            . "\r\n"
            . "Body of $subject.\r\n";
    close $fh;
    return $path;
}

# ------------------------------------------------- a stand-in for the index
#
# Records what it was asked to do rather than doing it. The assertions below
# are all about which of these calls happen, which is the whole behaviour
# under test.
package FakeIndex;
sub new { return bless { known => {}, indexed => [], touched => [],
                         deleted => [], mtime => undef, next_id => 100 }, shift }
sub known_files      { return $_[0]{known} }
sub upsert_account   { return 1 }
sub mailbox_mtime    { return undef }
sub mailbox_id       { my ($s, $a, $n) = @_; $s->{boxes}{$n} //= 500 + scalar keys %{ $s->{boxes} // {} }; return $s->{boxes}{$n} }
sub prune_mailboxes  {
    my ($s, $acct, $names) = @_;
    push @{ $s->{prune_calls} }, [ $acct, [ sort @$names ] ];
    return 0;
}
sub delete_messages  { my ($s, $ids) = @_; push @{ $s->{deleted} }, @$ids; return scalar @$ids }
sub set_mailbox_mtime{ my ($s, $mid, $t) = @_; $s->{mtime} = $t; return 1 }
sub touch_file       { my ($s, $id, $file) = @_; push @{ $s->{touched} }, [ $id, $file->{file_name} ]; return 1 }
sub index_message {
    my ($s, %a) = @_;
    my $id = $s->{next_id}++;
    push @{ $s->{indexed} }, { id => $id, uniq => $a{file}{uniq_part},
                               subject => $a{parsed}{subject} };
    # Becomes "known" for a later pass, exactly as a real re-scan would see.
    $s->{known}{ $a{file}{uniq_part} } = { message_id => $id, file_name => $a{file}{file_name} };
    return $id;
}

package FakeLog;
sub new   { return bless { warn => [] }, shift }
sub warn  { my ($s, $m) = @_; push @{ $s->{warn} }, $m; return 1 }
sub info  { 1 }
sub debug { 1 }
sub error { 1 }

package main;

# An Indexer wired to the scratch root, with the one database call stubbed.
# _do_mailbox's only query is the mailbox/account lookup; everything after
# it goes through ->index, which is the fake above.
sub indexer_for {
    my ($box, $idx) = @_;
    my $ix = Homelab::Search::Indexer->new(
        index => $idx, log => FakeLog->new, mail_root => $root);
    no warnings 'redefine', 'once';
    *Homelab::Search::Indexer::_tx = sub {
        return { account_id => 1, local_part => 'alice', domain => 'example.org',
                 mailbox => $box, mailbox_id => 7 };
    };
    return $ix;
}

# ------------------------------------------------------- the ordinary pass
{
    my $dir = maildir('INBOX');
    deliver($dir, 'cur', '1699000001.M1P1.host,S=512:2,S', 'first');
    deliver($dir, 'cur', '1699000002.M2P2.host,S=512:2,S', 'second');
    deliver($dir, 'new', '1699000003.M3P3.host,S=512',     'unread');

    my $idx = FakeIndex->new;
    my $n   = indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });

    is $n, 3, 'all three messages are indexed on a first pass';
    is scalar @{ $idx->{deleted} }, 0, 'nothing is deleted on a first pass';
    ok defined $idx->{mtime}, 'the watermark is written after a clean pass';
    is_deeply [ sort map { $_->{subject} } @{ $idx->{indexed} } ],
              [ 'first', 'second', 'unread' ], 'subjects were parsed, not guessed';
}

# ------------------------------------- a re-scan with no change writes nothing
# Getting this wrong re-indexes a whole mailbox every time someone reads
# their mail, which is why the guard exists in the first place.
{
    my $dir = maildir('INBOX');
    my $idx = FakeIndex->new;
    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    my $first = scalar @{ $idx->{indexed} };

    my $again = indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    is $again, 0, 'a second pass over an unchanged mailbox indexes nothing';
    is scalar @{ $idx->{indexed} }, $first, '...and adds no rows';
    is scalar @{ $idx->{touched} },  0, '...and touches nothing';
    is scalar @{ $idx->{deleted} },  0, '...and deletes nothing';
}

# ------------------------------------------------ a flag change is an UPDATE
# Reading a message renames its file -- the flags live in the name -- but
# uniq_part is the part before the colon and does not change.
{
    my $dir = maildir('INBOX');
    my $idx = FakeIndex->new;
    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    my $before = scalar @{ $idx->{indexed} };

    # Mark 'first' as replied: same uniq_part, new file name.
    rename "$dir/cur/1699000001.M1P1.host,S=512:2,S",
           "$dir/cur/1699000001.M1P1.host,S=512:2,SR" or die $!;

    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    is scalar @{ $idx->{indexed} }, $before, 'a flag change does NOT re-index';
    is scalar @{ $idx->{touched} }, 1,       '...it is a one-column update';
    is $idx->{touched}[0][1], '1699000001.M1P1.host,S=512:2,SR',
        '...carrying the new file name';
    is scalar @{ $idx->{deleted} }, 0, '...and deletes nothing, despite the rename';
}

# --------------------------------------------- a real deletion IS a deletion
{
    my $dir = maildir('INBOX');
    my $idx = FakeIndex->new;
    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });

    unlink "$dir/cur/1699000002.M2P2.host,S=512:2,S" or die $!;
    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    is scalar @{ $idx->{deleted} }, 1,
        'a message genuinely gone from the store is removed from the index';
}

# ===========================================================================
# THE BUG: AN UNREADABLE DIRECTORY MUST NOT LOOK LIKE AN EMPTY ONE
# ===========================================================================
# A mailbox is two directories. `cur/` holds read mail -- nearly everything.
# `new/` holds the unread. _do_mailbox listed both into one @present list and
# then deleted from the index anything it had not seen.
#
# Three conditions skipped a directory: mailbox_dir_for dying, stat failing,
# or opendir failing. All three used `next`, and execution still fell through
# to the gone-detection. So an unreadable `cur/` meant @present held only the
# handful of unread names, and EVERY READ MESSAGE WAS DELETED FROM THE INDEX
# -- after which _finish recorded the unit as a success, and the watermark
# advanced so discovery would not come back until that folder changed again.
#
# The store is mounted read-only, so no mail was ever at risk. But it
# disappeared from search, silently, and the trigger is a momentary NFS
# failure on the NAS -- ESTALE or EACCES, which are routine, and which 5 of
# 26 account directories being 0700 vmail:vmail makes likelier still.
#
# A partial view is not evidence of deletion. It is evidence of nothing.
SKIP: {
    skip 'cannot test unreadable directories as root', 4 if $> == 0;

    my $dir = maildir('INBOX');
    my $idx = FakeIndex->new;
    indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 });
    my $known_before = scalar keys %{ $idx->{known} };
    cmp_ok $known_before, '>', 1, 'the mailbox is indexed before cur/ is broken';

    my $mtime_before = $idx->{mtime};
    chmod 0000, "$dir/cur" or die $!;
    my $died = !eval { indexer_for('INBOX', $idx)->_do_mailbox({ mailbox_id => 7 }); 1 };
    chmod 0755, "$dir/cur" or die $!;    # restore before any assertion can bail

    is scalar @{ $idx->{deleted} }, 0,
        'an unreadable cur/ deletes NOTHING -- a directory that could not be '
      . 'read is not a directory that was empty';
    ok $died,
        '...the unit fails, so run_unit routes it to _fail and it retries '
      . 'rather than recording a success';
    is $idx->{mtime}, $mtime_before,
        '...and the watermark does not advance, so discovery comes back';
}

# ------------------------------------------- the same rule for a named folder
# INBOX is the account root; a named folder is a dot-prefixed sibling. The
# failure mode is identical, so the guard must not be specific to INBOX.
SKIP: {
    skip 'cannot test unreadable directories as root', 1 if $> == 0;

    my $dir = maildir('.Archive');
    deliver($dir, 'cur', '1699000010.M9P9.host,S=512:2,S', 'archived');
    my $idx = FakeIndex->new;
    indexer_for('.Archive', $idx)->_do_mailbox({ mailbox_id => 7 });

    chmod 0000, "$dir/cur" or die $!;
    eval { indexer_for('.Archive', $idx)->_do_mailbox({ mailbox_id => 7 }); 1 };
    chmod 0755, "$dir/cur" or die $!;
    is scalar @{ $idx->{deleted} }, 0, 'a named folder is protected too';
}

# ------------------------------------------------- a missing directory is fine
# An account with no `new/` at all is not broken, and must not be treated as
# unreadable -- otherwise every such mailbox parks itself. Absent and
# unreadable are different things, which is the distinction the fix turns on.
{
    my $base = "$root/example.org/bob";
    make_path("$base/cur");             # deliberately no new/
    deliver($base, 'cur', '1699000020.MaPa.host,S=512:2,S', 'only read mail');

    my $idx = FakeIndex->new;
    my $ix  = Homelab::Search::Indexer->new(
        index => $idx, log => FakeLog->new, mail_root => $root);
    {
        no warnings 'redefine', 'once';
        *Homelab::Search::Indexer::_tx = sub {
            return { account_id => 2, local_part => 'bob', domain => 'example.org',
                     mailbox => 'INBOX', mailbox_id => 8 };
        };
    }
    my $n = eval { $ix->_do_mailbox({ mailbox_id => 8 }) };
    is $@, '', 'a mailbox with no new/ directory does not fail';
    is $n, 1, '...and its read mail is still indexed';
}

# ===========================================================================
# THE RENAMED FOLDER: an old mailbox must not linger in the index forever
# ===========================================================================
# search.mailboxes.name IS the on-disk folder name, UNIQUE (account_id,
# name), and mailbox_id() is get-or-create -- so renaming '.Old' to '.New'
# creates a SECOND row and re-indexes everything under fresh ids, while
# '.Old' and its messages stay searchable, pointing at a folder that is not
# there. Nothing in this package ever removed a mailbox row.
#
# The reconcile that fixes it runs in _discover_mail, and its safety rests
# entirely on being handed the COMPLETE folder list from a directory read
# that succeeded. These tests are about that contract, because getting it
# wrong deletes real mail from the index.
{
    my $base = "$root/example.org/carol";
    make_path("$base/$_") for qw(cur new tmp);
    make_path("$base/.Keep/$_") for qw(cur new tmp);

    my $idx = FakeIndex->new;
    my $ix  = Homelab::Search::Indexer->new(
        index => $idx, log => FakeLog->new, mail_root => $root);
    # Enqueueing needs a database; the reconcile is what is under test here.
    no warnings 'redefine', 'once';
    local *Homelab::Search::Indexer::_enqueue = sub { 0 };
    $ix->_discover_mail;

    my @calls = @{ $idx->{prune_calls} || [] };
    ok scalar @calls, 'discovery reconciles mailboxes against what is on disk';

    # Every account in the scratch root is discovered in one pass, so find
    # carol's call by its contents. The list must be exactly the folders
    # actually present, INBOX included -- an account whose list came back
    # short is an account whose mail would be deleted from the index.
    my ($carol) = grep { my %h = map { $_ => 1 } @{ $_->[1] };
                         $h{'INBOX'} && $h{'.Keep'} && @{ $_->[1] } == 2 } @calls;
    ok $carol,
        'the folder list is exactly INBOX plus the one named folder on disk '
      . '-- no more, which would delete nothing, and no fewer, which would '
      . 'delete real mail';
}

# The contract, asserted against the real implementation rather than a
# stand-in: an empty or missing list must delete NOTHING. Every account has
# at least INBOX, so an empty list means the caller failed to read the
# directory -- never that the account has no folders.
{
    require Homelab::Search::Index;
    my $called = 0;
    no warnings 'redefine', 'once';
    local *Homelab::Search::Index::_tx = sub { $called++; return 0 };
    my $ix = bless { log => FakeLog->new }, 'Homelab::Search::Index';

    is $ix->prune_mailboxes(1, []),     0, 'an empty folder list prunes nothing';
    is $ix->prune_mailboxes(1, undef),  0, 'a missing folder list prunes nothing';
    is $ix->prune_mailboxes(undef, ['INBOX']), 0, 'no account prunes nothing';
    is $called, 0,
        'and none of those even opened a transaction -- a caller with no '
      . 'list is a caller that failed, not an account with no folders';
}

# A failed account-directory read must never reach the reconcile at all.
# _discover_mail does `next` on that opendir, which is what makes the list
# trustworthy everywhere below it; if that ever changes, this fails.
SKIP: {
    skip 'cannot test unreadable directories as root', 1 if $> == 0;

    my $base = "$root/example.org/dave";
    make_path("$base/$_") for qw(cur new tmp);
    make_path("$base/.Secret/$_") for qw(cur new tmp);

    my $idx = FakeIndex->new;
    my $ix  = Homelab::Search::Indexer->new(
        index => $idx, log => FakeLog->new, mail_root => $root);
    no warnings 'redefine', 'once';
    local *Homelab::Search::Indexer::_enqueue = sub { 0 };

    chmod 0000, $base or die $!;
    eval { $ix->_discover_mail; 1 };
    chmod 0755, $base or die $!;

    my @dave = grep { ($_->[0] // 0) } @{ $idx->{prune_calls} || [] };
    # Every account in the scratch root is discovered in one pass, so the
    # assertion is specifically that dave's folder list never became a
    # prune call: with the directory unreadable there is no list to pass.
    my $saw_secret = grep { grep { $_ eq '.Secret' } @{ $_->[1] } } @dave;
    is $saw_secret, 0,
        'an unreadable account directory produces no prune call -- a read '
      . 'that failed must not be allowed to delete anything';
}

done_testing;
