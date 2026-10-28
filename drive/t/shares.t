use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);

# Sharing. Self-contained where it can be: the token helper and the SQL that
# decides whether a share is live are the two things a mistake in turns into
# a DATA LEAK, so they are asserted directly rather than only through the
# HTTP surface.

use lib 'lib';

my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<"YAML");
server:
  listen: "http://127.0.0.1:0"
session:
  secret: "test-only-not-a-real-secret"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
storage:
  path: "@{[ $dir->child('storage') ]}"
public_base_url: "https://drive.test"
homelab_api:
  base_url: "http://127.0.0.1:9/api"
sso:
  base_url: "https://sso.test"
  client_id: "test"
  client_secret: "test"
  redirect_uri: "https://drive.test/sso/callback"
YAML

$ENV{HOMELAB_DRIVE_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_DRIVE_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME}= '../webtheme';

my $t = eval { Test::Mojo->new('Homelab::Drive::App') };
plan skip_all => "could not start app: $@" unless $t;
my $app = $t->app;

# --- the token ---
# 32 bytes of /dev/urandom, hex. The pre-cutover implementation used
# sha256_hex(rand() . $$ . time()), which is seeded from a small and partly
# guessable space -- for a value that is the ONLY thing protecting a public
# share, that is not good enough.
my $tok = Homelab::Drive::App::Controller::Drive::_share_token();
like($tok, qr/\A[0-9a-f]{64}\z/, 'token is 64 hex chars');
my %seen = map { Homelab::Drive::App::Controller::Drive::_share_token() => 1 } 1 .. 200;
is(scalar(keys %seen), 200, '200 tokens, no collisions');

# --- routes exist, and the public ones take NO auth ---
my %routes = map { ($_->to_string // '') => 1 } @{ $app->routes->children };
for my $p ('/s/:token', '/s/:token/download', '/s/:token/thumbnail',
           '/s/:token/files/:fid/download', '/s/:token/files/:fid/thumbnail') {
    ok($routes{$p}, "public route $p is registered");
}

# A bad token must not reach the database at all -- _live_share rejects
# anything that is not 64 hex up front, so a malformed token cannot become a
# query. (The DB here points nowhere, so a query would die.)
for my $bad (undef, '', 'nope', 'x' x 64, '../../etc/passwd', '%27 OR 1=1') {
    my $got = eval { Homelab::Drive::App::Controller::Drive::_live_share($app->build_controller, $bad) };
    ok(!$@ && !defined $got, 'malformed token rejected without touching the DB: ' . (defined $bad ? "'$bad'" : 'undef'));
}

# --- the liveness SQL names every way a share can die ---
# Each of these omitted is a separate, silent leak: a revoked link that keeps
# working, an expired one that never expires, or -- worst -- a file the owner
# moved to Trash still downloadable by anyone holding the link.
my $src = Mojo::File->new('lib/Homelab/Drive/App.pm')->slurp;
my ($live) = $src =~ /(sub _live_share .*?\n\})/s;
ok($live, 'found _live_share');
like($live, qr/revoked_at IS NULL/,                 'revoked shares are excluded');
like($live, qr/expires_at IS NULL OR s\.expires_at > NOW\(\)/, 'expired shares are excluded');
like($live, qr/f\.deleted_at IS NULL/,              'a trashed FILE kills its share');
like($live, qr/d\.deleted_at IS NULL/,              'a trashed FOLDER kills its share');

# --- folder shares are RECURSIVE, and the subtree is a CLOSED set ---
# Recursive because that is what sharing a folder means everywhere else;
# the first cut listed only the top level, which protected nothing and
# silently hid content the owner believed they had shared.
my ($tree) = $src =~ /(sub _share_tree_sql .*?\n\})/s;
ok($tree, 'found the share-subtree CTE');
like($tree, qr/WITH RECURSIVE/,                  'the subtree is computed recursively');
like($tree, qr/JOIN share_tree t ON f\.parent_folder_id = t\.id/, 'it walks parent -> child');
# In the RECURSIVE step, so trashing an intermediate folder prunes its whole
# subtree instead of leaving orphans reachable.
my ($recur) = $tree =~ /UNION ALL(.*)\z/s;
like($recur, qr/deleted_at IS NULL/,             'a trashed folder prunes everything beneath it');

my ($inf) = $src =~ /(sub _file_in_shared_folder .*?\n\})/s;
ok($inf, 'found _file_in_shared_folder');
like($inf, qr/folder_id IN \(SELECT id FROM share_tree\)/,
    'a file must live somewhere INSIDE the shared subtree');
like($inf, qr/deleted_at IS NULL/,               'and must not be trashed');

my ($fis) = $src =~ /(sub _folder_in_share .*?\n\})/s;
ok($fis, 'found _folder_in_share');
like($fis, qr/SELECT id, name, parent_folder_id FROM share_tree WHERE id = \?/,
    'browsing is confined to the shared subtree');

# --- revoke is owner-scoped in the WHERE, not checked afterwards ---
my ($rev) = $src =~ /(sub revoke_share .*?\n\})/s;
like($rev, qr/WHERE id = \? AND owner_email = \?/, 'revoke can only touch your own share');

# --- sharing with yourself is refused ---
like($src, qr/You cannot share with yourself/, 'self-share is refused');

# --- an unknown recipient does NOT abort the share ---
# The link is created either way; only the notification is skipped. Failing
# the call would discard a good link over a typo, and failing silently would
# let the sharer believe it had been delivered.
my ($create) = $src =~ /(sub create_share .*?\n\})/s;
like($create, qr/\$recipient_exists = _share_recipient_exists/, 'recipient existence is checked');
unlike($create, qr/return .*status => 4\d\d.*\n.*unless \$recipient_exists/, 'but it is not a gate');
like($create, qr/nothing was emailed/, 'and the sharer is told plainly');

# --- public templates exist ---
ok(-f "templates/$_.html.ep", "template $_ ships") for qw(share_gone share_file share_folder shares);

# Column names used by the share SQL must actually exist. A typo here is a
# 500 at request time, not a compile error -- `created_at` instead of
# `uploaded_at` took the folder landing page down on first deploy.
{
    my %known = (
        'drive.files'   => [qw(id user_email filename uuid size_bytes mime_type uploaded_at folder_id deleted_at)],
        'drive.folders' => [qw(id user_email name parent_folder_id deleted_at)],
    );
    my ($pub) = $src =~ /(sub public_share .*?\n\})/s;
    # (?!FROM) stops the capture crossing an earlier SELECT: public_share
    # now queries drive.folders BEFORE drive.files, and a plain .*? happily
    # spanned both and "found" a folders column in the files list.
    my ($sel) = $pub =~ /SELECT\s+((?:(?!FROM)[\s\S])*?)\s+FROM drive\.files/;
    ok($sel, 'found the folder-listing SELECT');
    for my $col (map { s/\s//gr } split /,/, ($sel // '')) {
        next unless $col =~ /\A\w+\z/;
        ok((grep { $_ eq $col } @{ $known{'drive.files'} }), "drive.files really has a column '$col'");
    }
}

done_testing;
