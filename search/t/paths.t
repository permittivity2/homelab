use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib 'lib';

use Homelab::Search::Paths qw(maildir_for mailbox_dir_for drive_blob_for contained_ok);

# These are the tests that matter most in this package: the search hosts
# mount every account's mail, so this module is the authorization boundary
# for the filesystem half. A regression here is a cross-account disclosure,
# not a cosmetic bug.
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/root/dom/user/cur", "$tmp/root/dom/user/.Sub Folder/cur", "$tmp/outside");
open my $fh, '>', "$tmp/outside/loot" or die; print $fh "secret"; close $fh;
symlink "$tmp/outside", "$tmp/root/dom/user/escape" or plan skip_all => 'no symlink support';

my $root = "$tmp/root";

ok  defined eval { maildir_for($root, 'dom', 'user') },        'normal maildir resolves';
ok !defined eval { maildir_for($root, 'dom', '..') },          'bare .. refused';
ok !defined eval { maildir_for($root, 'dom', '../../outside') }, 'embedded traversal refused';
ok !defined eval { maildir_for($root, 'dom', 'user/../..') },  'separator in local part refused';
ok !defined eval { maildir_for($root, '', 'user') },           'empty domain refused';

# A symlink out of the tree is the case a string-prefix check misses: the
# unresolved path looks fine and only realpath() exposes it.
ok !defined eval { mailbox_dir_for($root, 'dom', 'user', 'escape', 'cur') },
    'symlinked mailbox escaping the account is refused';

# Legitimate shapes that must NOT be refused.
ok  defined eval { mailbox_dir_for($root, 'dom', 'user', 'INBOX', 'cur') }, 'INBOX/cur resolves';
ok  defined eval { mailbox_dir_for($root, 'dom', 'user', 'INBOX', 'tmp') },
    'a sub-directory that does not exist yet still resolves';
ok  defined eval { mailbox_dir_for($root, 'dom', 'user', '.Sub Folder', 'cur') },
    'Maildir++ folder name with a space resolves';
ok !defined eval { mailbox_dir_for($root, 'dom', 'user', 'INBOX', '../..') }, 'bad sub refused';

ok  defined eval { drive_blob_for($tmp, 'AB97C271-3093-4363-A5CC-1852480D0E50') },
    'uuid blob resolves (and is lower-cased)';
ok !defined eval { drive_blob_for($tmp, '../outside/loot') }, 'non-uuid blob path refused';
ok !defined eval { drive_blob_for($tmp, 'not-a-uuid') },      'malformed uuid refused';

# Without a separator boundary, a root of /x would also "contain" /x-evil.
make_path("$tmp/root-evil");
ok !contained_ok("$tmp/root", "$tmp/root-evil"), 'sibling sharing a name prefix is not contained';

done_testing();
