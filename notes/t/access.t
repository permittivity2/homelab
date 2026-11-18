use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Homelab::Notes::Access qw(share_is_live notebook_permission note_permission may_edit may_manage);

# Who may do what, as pure functions over rows (no database).

my $nb   = { id => 1, owner_email => 'Alice@Example.test' };
my $note = { id => 10, notebook_id => 1 };
my $gone = { id => 2, owner_email => 'alice@example.test', deleted_at => '2026-11-18 01:00:00+00' };

is notebook_permission('alice@example.test', $nb), 'owner', 'the owner owns it, whatever the case of the address';
is notebook_permission('bob@example.test', $nb), undef, 'a stranger has nothing';
is notebook_permission('', $nb), undef, 'nobody signed in has nothing';
is notebook_permission('alice@example.test', $gone), undef, 'a deleted notebook grants nothing, even to its owner';
is notebook_permission('alice@example.test', undef), undef, 'no row, no level';

my $read = { notebook_id => 1, shared_with_email => 'BOB@example.test', permission => 'read' };
my $edit = { notebook_id => 1, shared_with_email => 'bob@example.test', permission => 'edit' };
my $other = { notebook_id => 7, shared_with_email => 'bob@example.test', permission => 'edit' };
is notebook_permission('bob@example.test', $nb, [$read]), 'read', 'a read share reads';
is notebook_permission('bob@example.test', $nb, [$read, $edit]), 'edit', 'the best share wins';
is notebook_permission('bob@example.test', $nb, [$other]), undef, 'a share of another notebook does not count';
is notebook_permission('carol@example.test', $nb, [$edit]), undef, "someone else's share does not count";
is notebook_permission('bob@example.test', $nb, [{ %$edit, revoked_at => 'x' }]), undef, 'a revoked share is dead';
is notebook_permission('bob@example.test', $nb, [{ %$edit, expires_at_epoch => time - 1 }]), undef, 'an expired share is dead';
is notebook_permission('bob@example.test', $nb, [{ %$edit, expires_at_epoch => time + 3600 }]), 'edit', 'a share with time left lives';

ok share_is_live({}), 'a plain row lives';
ok !share_is_live(undef), 'nothing is not live';
ok !share_is_live({ revoked_at => '2026-01-01' }), 'revoked';
ok !share_is_live({ expires_at_epoch => 5 }, 10), 'expired at the given now';
ok share_is_live({ expires_at_epoch => 15 }, 10), '... not yet';

is note_permission('alice@example.test', $note, $nb), 'owner', "the notebook's owner owns the note";
is note_permission('bob@example.test', $note, $nb), undef, 'no share, no note';
is note_permission('bob@example.test', $note, $nb, [$read]), 'read', "the notebook's share reaches the note";
my $nread = { note_id => 10, shared_with_email => 'bob@example.test', permission => 'read' };
my $nedit = { note_id => 10, shared_with_email => 'bob@example.test', permission => 'edit' };
is note_permission('bob@example.test', $note, $nb, [], [$nread]), 'read', 'a share of the note itself';
is note_permission('bob@example.test', $note, $nb, [$read], [$nedit]), 'edit', 'the note share adds to the notebook share';
is note_permission('bob@example.test', $note, $nb, [], [{ %$nedit, note_id => 11 }]), undef, 'a share of another note does not count';
is note_permission('bob@example.test', { %$note, deleted_at => 'x' }, $nb, [], [$nedit]), undef, 'a deleted note grants nothing';
is note_permission('alice@example.test', $note, $gone), undef, 'a note in a deleted notebook grants nothing';

ok may_edit('edit') && may_edit('owner') && !may_edit('read') && !may_edit(undef), 'may_edit';
ok may_manage('owner') && !may_manage('edit') && !may_manage('read'), 'may_manage';

done_testing;
