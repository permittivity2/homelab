package Homelab::Search::Paths;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

use Cwd qw(realpath);
use File::Spec;

our @EXPORT_OK = qw(maildir_for mailbox_dir_for drive_blob_for contained_ok);

# THE SINGLE PLACE A PATH INTO EITHER READ-ONLY STORE IS BUILT.
#
# These hosts mount every user's mail and every user's drive blobs, so the
# filesystem will happily hand over anyone's data and the code is the
# authorization boundary. Two different shapes of rule, because the two
# stores are not symmetric:
#
#   MAIL IS PATH-SCOPED. dovecot's layout is
#   mail_path = /var/mail/vhosts/%{user|domain}/%{user|username}, so an
#   account's mail is exactly one directory, derivable from its address.
#   Every path here is therefore built from (domain, local_part) taken
#   from search.accounts -- NEVER from a request parameter -- and checked
#   for containment before any read.
#
#   DRIVE IS NOT PATH-SCOPED. Blobs are stored flat by uuid
#   (/var/lib/homelab/drive-storage/<uuid>), so the filesystem cannot tell
#   you who owns a file; only drive.files.user_email can. The rule that
#   follows: a blob is only ever opened for a uuid a `user_email = ?`
#   query just returned, and the storage directory is NEVER enumerated.
#   There is deliberately no function here that lists it.
#
# contained_ok() is what makes the mail rule hold against two concrete
# attacks that a naive join would not: a local part containing '..' (so a
# crafted or mis-parsed address walks out of the tree), and a symlink
# planted inside a maildir pointing somewhere else. realpath() resolves
# both, so comparing the resolved child against the resolved root catches
# them. A prefix test on the UNRESOLVED string catches neither.

# True if $path resolves to something inside $root. Both are resolved, so
# symlinks and '..' are defeated rather than string-matched -- a prefix
# test on the unresolved strings catches neither.
#
# realpath() returns undef for a path whose leaf does not exist, which a
# mailbox legitimately hits (not every maildir has tmp/). So the deepest
# EXISTING ancestor is resolved and the not-yet-existing remainder is
# appended, after checking each remaining component. That keeps the
# symlink guarantee -- a symlink can only exist in the part that exists --
# without refusing to look at a directory that is simply absent.
sub contained_ok ($root, $path) {
    return 0 unless defined $root && defined $path && length $root && length $path;
    my $rroot = realpath($root) or return 0;
    $rroot =~ s{/+$}{};

    my @parts = File::Spec->splitdir($path);
    my @tail;
    my $probe = $path;
    my $rpath;
    while (@parts) {
        $probe = File::Spec->catdir(@parts);
        last if $rpath = realpath($probe);
        my $leaf = pop @parts;
        # A component we are about to trust unresolved must be inert.
        return 0 if !defined $leaf || $leaf eq '..';
        unshift @tail, $leaf if length $leaf;
    }
    return 0 unless $rpath;
    $rpath = File::Spec->catdir($rpath, @tail) if @tail;

    return 1 if $rpath eq $rroot;
    return index($rpath, "$rroot/") == 0 ? 1 : 0;
}

# A component that may never appear in a path we build. Checked before
# touching the filesystem at all, so a bad account row is a loud refusal
# rather than a realpath() that happens to land somewhere readable.
sub _safe_component ($c) {
    return 0 unless defined $c && length $c;
    return 0 if $c eq '.' || $c eq '..';
    return 0 if $c =~ m{/};         # no separators inside one component
    return 0 if $c =~ m{\0};        # no NUL
    return 0 if $c =~ m{^\s|\s$};   # no leading/trailing whitespace
    return 1;
}

# Absolute maildir root for one account. Dies rather than returning
# something unusable: every caller is about to read files with it.
sub maildir_for ($root, $domain, $local_part) {
    die "maildir_for: unsafe domain '" . ($domain // '') . "'\n"
        unless _safe_component($domain);
    die "maildir_for: unsafe local_part '" . ($local_part // '') . "'\n"
        unless _safe_component($local_part);

    my $path = File::Spec->catdir($root, $domain, $local_part);
    die "maildir_for: '$path' does not resolve inside '$root'\n"
        unless contained_ok($root, $path);
    return $path;
}

# One maildir folder inside an account, e.g. ('INBOX') or ('.House Stuff').
# $sub is cur|new|tmp. Maildir++ folder names legitimately contain spaces
# and dots, so those are allowed -- but not separators, and the result is
# still containment-checked against the ACCOUNT's own root, which is what
# stops a crafted folder name reaching another account.
sub mailbox_dir_for ($root, $domain, $local_part, $mailbox, $sub) {
    my $acct = maildir_for($root, $domain, $local_part);
    die "mailbox_dir_for: unsafe mailbox '" . ($mailbox // '') . "'\n"
        unless _safe_component($mailbox);
    die "mailbox_dir_for: bad sub '" . ($sub // '') . "'\n"
        unless defined $sub && $sub =~ /\A(?:cur|new|tmp)\z/;

    # 'INBOX' is the account root itself in Maildir++; named folders are
    # dot-prefixed siblings.
    my $dir = $mailbox eq 'INBOX' ? File::Spec->catdir($acct, $sub)
                                  : File::Spec->catdir($acct, $mailbox, $sub);
    die "mailbox_dir_for: '$dir' does not resolve inside '$acct'\n"
        unless contained_ok($acct, $dir);
    return $dir;
}

# One drive blob, by the uuid the DATABASE returned for this account. The
# uuid format check is not decoration: it is what guarantees the result
# cannot be a traversal, since a uuid cannot contain '/' or '..'.
sub drive_blob_for ($root, $uuid) {
    die "drive_blob_for: '" . ($uuid // '') . "' is not a uuid\n"
        unless defined $uuid
            && $uuid =~ /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/;
    my $path = File::Spec->catfile($root, lc $uuid);
    die "drive_blob_for: '$path' does not resolve inside '$root'\n"
        unless contained_ok($root, $path);
    return $path;
}

1;
