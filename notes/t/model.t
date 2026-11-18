use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';

# The data paths against a real PostgreSQL: notebooks, folders, notes, the
# versions and the conflict check, the trash, moving, search, links, shares
# and what they allow, preferences, the metrics. Needs TEST_PG_URL
# (postgres://user:pass@host:port/db) with the notes migrations applied;
# CI's notes-db-tests job does both. Skips otherwise.
plan skip_all => 'TEST_PG_URL not set (a PostgreSQL with the notes schema)' unless $ENV{TEST_PG_URL};
require Mojo::Pg;
require Homelab::Notes::Model;

my $pg = Mojo::Pg->new($ENV{TEST_PG_URL});
my $m  = Homelab::Notes::Model->new(pg => $pg, versions_kept => 3, max_body_bytes => 2000);
my $db = $pg->db;
my $tag = 'modeltest-' . time . "-$$";
my ($alice, $bob, $carol) = map { "$tag-$_\@example.test" } qw(alice bob carol);
sub cleanup {
    $db->query('DELETE FROM notes.notebooks WHERE owner_email LIKE ?', "$tag-%");    # notes, folders, versions, links, shares cascade
    $db->query('DELETE FROM notes.shares WHERE owner_email LIKE ?', "$tag-%");
    $db->query('DELETE FROM notes.user_prefs WHERE user_email LIKE ?', "$tag-%");
}
END { cleanup() if $db }

# --- notebooks --------------------------------------------------------------
my $nb = $m->ensure_default_notebook($alice);
is $nb->{name}, 'My notes', 'a first visit makes the default notebook';
is $m->ensure_default_notebook($alice)->{id}, $nb->{id}, '... once';
my $work = $m->create_notebook($alice, name => '  Work  ', color => '#AABBCC');
is $work->{name}, 'Work', 'a name is trimmed';
is $work->{color}, '#aabbcc', 'a colour is lowered';
eval { $m->create_notebook($alice, name => '') }; like $@, qr/Give the notebook a name/, 'no name: refused with a sentence';
eval { $m->create_notebook($alice, name => 'x', color => 'red') }; like $@, qr/colour must be like/, 'a bad colour: refused';
my $list = $m->notebooks_for($alice);
is scalar @$list, 2, 'two notebooks';
is $list->[0]{permission}, 'owner', '... owned';
is $m->notebooks_for($bob)->[0], undef, 'bob has none yet';
is $m->update_notebook($work->{id}, name => 'Work notes')->{name}, 'Work notes', 'renamed';
is $m->permission_for_notebook($alice, $work), 'owner', 'the owner owns it';
is $m->permission_for_notebook($bob, $work), undef, 'a stranger has nothing';

# --- folders ----------------------------------------------------------------
my $f1 = $m->create_folder($work->{id}, name => 'Projects');
my $f2 = $m->create_folder($work->{id}, name => 'Alpha', parent_id => $f1->{id});
is $f2->{parent_id}, $f1->{id}, 'a folder inside a folder';
eval { $m->create_folder($nb->{id}, name => 'x', parent_id => $f1->{id}) }; like $@, qr/No such folder/, "a parent from another notebook is refused";
eval { $m->update_folder($f1, parent_id => $f1->{id}) }; like $@, qr/inside itself/, 'a folder cannot be its own parent';
is scalar @{ $m->folders_for($work->{id}) }, 2, 'two folders listed';

# --- notes --------------------------------------------------------------------
my $n1 = $m->create_note($work, $alice, { title => "  Plan  ", format => 'md', body => "# Plan\n\nDo the *thing*.", folder_id => $f1->{id} });
is $n1->{title}, 'Plan', 'title trimmed';
is $n1->{format}, 'markdown', 'md means markdown';
is $n1->{folder_id}, $f1->{id}, 'in its folder';
is $n1->{revision}, 1, 'revision 1';
is $n1->{owner_email}, $alice, 'owned by the notebook owner';
my $n2 = $m->create_note($work, $alice, { title => 'Shopping', format => 'text', body => "milk\neggs" });
my $n3 = $m->create_note($nb, $alice, { title => 'Html one', format => 'html', body => '<p onclick="x">hi</p>' });
eval { $m->create_note($work, $alice, { title => 'x', format => 'docx' }) }; like $@, qr/format must be/, 'an unknown format is refused';
eval { $m->create_note($work, $alice, { title => 'x', body => 'y' x 3000 }) }; like $@, qr/too big/, 'a body over the limit is refused';
eval { $m->create_note($work, $alice, { title => 'x' x 301 }) }; like $@, qr/title is too long/, 'a title over 300 is refused';
is scalar @{ $m->notes_in(notebook_id => $work->{id}) }, 2, 'two notes in Work';
is scalar @{ $m->notes_in(notebook_id => $work->{id}, folder_id => $f1->{id}) }, 1, '... one in Projects';
is scalar @{ $m->notes_in(notebook_id => $work->{id}, folder_id => 0) }, 1, '... one at the root';
ok !exists $m->notes_in(notebook_id => $work->{id})->[0]{body}, 'the list carries no body';
ok exists $m->notes_in(notebook_id => $work->{id})->[0]{body_head}, '... but a head of it';
is scalar @{ $m->notes_for_viewer($alice) }, 3, 'alice sees her three notes across notebooks';
is scalar @{ $m->notes_for_viewer($bob) }, 0, 'bob sees none';

# --- changing, versions, the conflict check ------------------------------------------
my $n1b = $m->update_note($n1, $alice, { body => "# Plan\n\nDo the *thing* today." });
is $n1b->{revision}, 2, 'a body change bumps the revision';
is $n1b->{edited_by}, $alice, '... and records who';
is scalar @{ $m->versions_for($n1->{id}) }, 1, '... and keeps the old body as a version';
is $m->versions_for($n1->{id})->[0]{revision}, 1, '... at the old revision';
is $m->update_note($n1b, $alice, { pinned => 1 })->{revision}, 2, 'pinning is not a content change: no new revision';
is scalar @{ $m->versions_for($n1->{id}) }, 1, '... and no version';
eval { $m->update_note($n1b, $bob, { body => 'stale edit' }, expected_revision => 1) };
like $@, qr/^conflict/, 'an edit from an older copy is a conflict';
is $m->note($n1->{id})->{body}, "# Plan\n\nDo the *thing* today.", '... and nothing was written';
my $n1c = $m->update_note($m->note($n1->{id}), $bob, { body => 'bob edit' }, expected_revision => 2);
is $n1c->{revision}, 3, 'an edit from the current copy goes through';
is $n1c->{edited_by}, $bob, '... as bob';
$m->update_note($m->note($n1->{id}), $alice, { body => "v$_" }) for 4 .. 6;
is scalar @{ $m->versions_for($n1->{id}) }, 3, 'only versions_kept versions remain';
is $m->versions_for($n1->{id})->[0]{body_chars}, 2, 'the newest version is the body before the last save';
my $v = $m->version($m->versions_for($n1->{id})->[-1]{id});
my $restored = $m->restore_version($m->note($n1->{id}), $v, $alice);
is $restored->{body}, $v->{body}, 'a version restored becomes the body';
is $restored->{revision}, 7, '... as a new revision';
is $m->update_note($restored, $alice, { title => $restored->{title} })->{revision}, 7, 'saving the same words changes nothing';

# --- trash, restore, move -------------------------------------------------------------
ok $m->delete_note($n2), 'deleted';
is scalar @{ $m->notes_in(notebook_id => $work->{id}) }, 1, '... gone from the list';
is scalar @{ $m->trashed_notes($alice) }, 1, '... in the trash';
is $m->permission_for_note($alice, $m->note($n2->{id})), undef, 'a trashed note grants nothing';
ok $m->restore_note($n2->{id}), 'restored';
is scalar @{ $m->trashed_notes($alice) }, 0, '... trash empty';
my $moved = $m->move_note($m->note($n2->{id}), $nb->{id});
is $moved->{notebook_id}, $nb->{id}, 'moved to the other notebook';
is $moved->{folder_id}, undef, '... to its root';
eval { $m->move_note($moved, $work->{id}, $f1->{id} + 100000) }; like $@, qr/No such folder/, 'a folder that is not there is refused';
$m->delete_note($n3);
is $m->purge_trash($alice), 1, 'the trash emptied one note for good';
is $m->note($n3->{id}), undef, '... which no longer exists';

# --- folders deleted take their notes -------------------------------------------------------
my $in_sub = $m->create_note($work, $alice, { title => 'Deep', body => 'x', folder_id => $f2->{id} });
is $m->delete_folder($f1), 2, 'deleting Projects takes Alpha too';
ok $m->note($in_sub->{id})->{deleted_at}, '... and the note inside it is in the trash';
ok $m->note($n1->{id})->{deleted_at}, '... as is the one in Projects';
my $back = $m->restore_note($n1->{id});
is $back->{folder_id}, undef, 'restored out of a dead folder: at the root';
$m->restore_note($in_sub->{id});

# --- search ---------------------------------------------------------------------------
$m->update_note($m->note($n1->{id}), $alice, { body => 'The quarterly budget review is on Thursday with Dana.' });
my $hits = $m->search_notes($alice, 'budget review');
is scalar @$hits, 1, 'full text finds the note';
like $hits->[0]{snippet}, qr/budget/, '... with a highlighted passage';
is scalar @{ $m->search_notes($alice, 'Thursd') }, 1, 'a word stem falls back to a substring match';
is scalar @{ $m->search_notes($bob, 'budget') }, 0, 'bob finds nothing of hers';
is scalar @{ $m->search_notes($alice, '') }, 0, 'an empty query finds nothing';

# --- links --------------------------------------------------------------------------
my $l1 = $m->add_link($n1->{id}, $alice, kind => 'mail', target => { message_id => 4182, subject => 'Your invoice', from_addr => 'b@example.test', junk => 'x' });
is $l1->{kind}, 'mail', 'a mail link';
is $l1->{target}{subject}, 'Your invoice', '... keeps the subject';
ok !exists $l1->{target}{junk}, '... and drops what it does not know';
my $l2 = $m->add_link($n1->{id}, $alice, kind => 'drive', target => { file_id => 42, filename => 'a.pdf', size_bytes => 10 }, label => 'The PDF');
is $l2->{label}, 'The PDF', 'a labelled drive link';
my $l3 = $m->add_link($n1->{id}, $alice, kind => 'url', target => { url => ' https://example.test/x ' });
is $l3->{target}{url}, 'https://example.test/x', 'a web link, trimmed';
eval { $m->add_link($n1->{id}, $alice, kind => 'url', target => { url => 'javascript:alert(1)' }) }; like $@, qr/http or https/, 'a web link must be http(s)';
eval { $m->add_link($n1->{id}, $alice, kind => 'drive', target => {}) }; like $@, qr/file's id/, 'a drive link needs an id';
eval { $m->add_link($n1->{id}, $alice, kind => 'ftp', target => {}) }; like $@, qr/must be to mail/, 'an unknown kind is refused';
is scalar @{ $m->links_for($n1->{id}) }, 3, 'three links';
is ref $m->links_for($n1->{id})->[0]{target}, 'HASH', '... targets decoded';
ok $m->remove_link($l3->{id}), 'removed';
is scalar @{ $m->links_for($n1->{id}) }, 2, '... two left';

# --- shares and what they allow ------------------------------------------------------------
my $s_read = $m->create_share(owner => $alice, note_id => $n1->{id}, shared_with_email => uc $bob, permission => 'read');
is $s_read->{shared_with_email}, $bob, 'a share to an account, address lowered';
is $m->permission_for_note($bob, $m->note($n1->{id})), 'read', 'bob may read the note';
is $m->permission_for_note($carol, $m->note($n1->{id})), undef, 'carol may not';
is $m->permission_for_notebook($bob, $work), undef, 'the note share does not open the notebook';
is scalar @{ $m->notes_for_viewer($bob) }, 1, 'bob sees the one note';
my $s_nb = $m->create_share(owner => $alice, notebook_id => $work->{id}, shared_with_email => $carol, permission => 'edit', expires_days => 2);
ok $s_nb->{expires_at}, 'a notebook share with an expiry';
ok $s_nb->{expires_at_epoch} > time, '... as an epoch too';
is $m->permission_for_notebook($carol, $work), 'edit', 'carol may edit the notebook';
is $m->permission_for_note($carol, $m->note($n1->{id})), 'edit', '... and so its notes';
is $m->notebooks_for($carol)->[0]{permission}, 'edit', '... and sees it in her list';
is scalar @{ $m->notes_for_viewer($carol) }, 2, '... with its two live notes';
my $link = $m->create_share(owner => $alice, note_id => $n1->{id}, permission => 'edit');
is $link->{shared_with_email}, undef, 'a link share';
is $link->{permission}, 'read', '... is never an edit share';
my $by = $m->share_by_token($link->{token});
is $by->{note}{id}, $n1->{id}, 'found by its token, with its note';
is $by->{notebook}{id}, $work->{id}, '... and notebook';
is $m->share_by_token('0' x 64), undef, 'an unknown token finds nothing';
eval { $m->create_share(owner => $alice, note_id => $n1->{id}, shared_with_email => 'not an address') }; like $@, qr/look like an address/, 'a bad address is refused';
eval { $m->create_share(owner => $alice, note_id => $n1->{id}, notebook_id => $work->{id}) }; like $@, qr/on a note or a notebook/, 'not both';
is scalar @{ $m->shares_for_note($n1->{id}) }, 2, 'two live shares on the note';
ok $m->revoke_share($s_read->{id}), 'revoked';
is $m->permission_for_note($bob, $m->note($n1->{id})), undef, '... bob is out';
is scalar @{ $m->shares_for_note($n1->{id}) }, 1, '... one share left';
$m->note_share_access($link->{id});
is $m->share($link->{id})->{access_count}, 1, 'an access is counted';
$m->delete_note($m->note($n1->{id}));
is $m->share_by_token($link->{token}), undef, 'a link to a trashed note finds nothing';
$m->restore_note($n1->{id});

# --- deleting a notebook ----------------------------------------------------------------------
my $spare = $m->create_notebook($alice, name => 'Spare');
my $sn = $m->create_note($spare, $alice, { title => 'In spare', body => 'x' });
ok $m->delete_notebook($spare), 'notebook deleted';
ok $m->note($sn->{id})->{deleted_at}, '... its note is in the trash';
is scalar(grep { $_->{id} == $spare->{id} } @{ $m->notebooks_for($alice) }), 0, '... and it is off the list';
ok $m->restore_note($sn->{id}), 'restoring the note';
ok !$m->notebook($spare->{id})->{deleted_at}, '... brings the notebook back';

# --- prefs ---------------------------------------------------------------------------------
is $m->prefs($alice)->{default_format}, 'markdown', 'default prefs';
is $m->set_prefs($alice, last_notebook_id => $work->{id}, default_format => 'text')->{default_format}, 'text', 'prefs saved';
is $m->prefs($alice)->{last_notebook_id}, $work->{id}, '... and read back';
eval { $m->set_prefs($alice, default_format => 'rtf') }; like $@, qr/format must be/, 'a bad default format is refused';

# --- metrics ----------------------------------------------------------------------------------
my $met = $m->metrics;
ok $met->{notes} >= 3, 'metrics count notes';
ok exists $met->{'notes_by_format{format="markdown"}'}, '... by format';
ok $met->{shares} >= 1, '... shares';
ok $met->{versions} >= 1, '... versions';

cleanup();
done_testing;
