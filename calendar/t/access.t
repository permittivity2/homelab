use Mojo::Base -strict, -signatures;
use Test::More;

# Who may see and change what. Pure functions; no database.

use lib 'lib';
use_ok 'Homelab::Calendar::Access', qw(share_is_live calendar_permission event_permission may_edit may_manage visible_detail);

my $cal   = { id => 7, owner_email => 'Owner@Example.test' };
my $event = { id => 42, calendar_id => 7 };
my $now   = 1_700_000_000;

# --- live shares ---
ok share_is_live({}), 'a plain share is live';
ok !share_is_live({ revoked_at => '2026-01-01' }), 'revoked: dead';
ok !share_is_live({ expires_at_epoch => $now - 1 }, $now), 'expired: dead';
ok share_is_live({ expires_at_epoch => $now + 1 }, $now), 'not yet expired: live';
ok !share_is_live(undef), 'not a row: dead';

# --- the calendar ---
is calendar_permission('owner@example.test', $cal), 'owner', 'the owner, whatever the case of the address';
is calendar_permission('someone@example.test', $cal), undef, 'a stranger: nothing';
is calendar_permission('', $cal), undef, 'nobody signed in: nothing';
is calendar_permission(undef, $cal), undef, 'undef viewer: nothing';
is calendar_permission('owner@example.test', { %$cal, deleted_at => '2026-01-01' }), undef, 'a deleted calendar: nothing, even for the owner';
is calendar_permission('owner@example.test', undef), undef, 'no calendar: nothing';

my $read = { calendar_id => 7, shared_with_email => 'Friend@Example.test', permission => 'read' };
my $edit = { calendar_id => 7, shared_with_email => 'friend@example.test', permission => 'edit' };
is calendar_permission('friend@example.test', $cal, [$read]), 'read', 'a read share';
is calendar_permission('friend@example.test', $cal, [$edit]), 'edit', 'an edit share';
is calendar_permission('friend@example.test', $cal, [$read, $edit]), 'edit', 'two shares: the higher wins';
is calendar_permission('friend@example.test', $cal, [{ %$edit, revoked_at => 'x' }, $read]), 'read', 'a revoked edit share leaves the read one';
is calendar_permission('friend@example.test', $cal, [{ %$edit, calendar_id => 8 }]), undef, 'a share of another calendar: nothing';
is calendar_permission('other@example.test', $cal, [$edit]), undef, 'someone else\'s share: nothing';
is calendar_permission('friend@example.test', $cal, [{ calendar_id => 7, shared_with_email => undef, permission => 'read' }]), undef,
    'a link share grants a signed-in viewer nothing by itself (the link page is the way in)';
is calendar_permission('owner@example.test', $cal, [$read]), 'owner', 'the owner stays owner whatever shares exist';

# --- an event ---
is event_permission('owner@example.test', $event, $cal), 'owner', 'the calendar owner owns its events';
is event_permission('friend@example.test', $event, $cal, [$read]), 'read', 'a calendar read share reads its events';
is event_permission('friend@example.test', $event, $cal, [$edit]), 'edit', 'a calendar edit share edits its events';
is event_permission('guest@example.test', $event, $cal), undef, 'a stranger: nothing';
my $ev_read = { event_id => 42, shared_with_email => 'guest@example.test', permission => 'read' };
my $ev_edit = { event_id => 42, shared_with_email => 'GUEST@example.test', permission => 'edit' };
is event_permission('guest@example.test', $event, $cal, [], [$ev_read]), 'read', 'a single event shared read';
is event_permission('guest@example.test', $event, $cal, [], [$ev_edit]), 'edit', '... or edit';
is event_permission('guest@example.test', $event, $cal, [], [{ %$ev_edit, event_id => 43 }]), undef, 'a share of another event: nothing';
is event_permission('friend@example.test', $event, $cal, [$read], [{ %$ev_edit, shared_with_email => 'friend@example.test' }]), 'edit',
    'calendar read + event edit = edit on that event';
is event_permission('friend@example.test', { %$event, deleted_at => 'x' }, $cal, [$edit]), undef, 'a deleted event: nothing';
is event_permission('guest@example.test', $event, $cal, [], [{ %$ev_read, expires_at_epoch => 1 }]), undef, 'an expired event share: nothing';

# --- what a level allows ---
ok may_edit('owner'), 'owner may edit';
ok may_edit('edit'), 'edit may edit';
ok !may_edit('read'), 'read may not edit';
ok !may_edit(undef), 'nothing may not edit';
ok may_manage('owner'), 'owner may manage';
ok !may_manage('edit'), 'edit may not manage (cannot share on, delete the calendar, change its settings)';
ok !may_manage('read'), 'read may not manage';

# --- how much a link share shows ---
is visible_detail({ shared_with_email => undef, detail => 'busy' }), 'busy', 'a busy-only link';
is visible_detail({ shared_with_email => undef, detail => 'full' }), 'full', 'a full link';
is visible_detail({ shared_with_email => undef }), 'full', 'detail defaults to full';
is visible_detail({ shared_with_email => 'x@y', detail => 'busy' }), 'full', 'a named share always shows everything';
is visible_detail(undef), 'full', 'no share row: full (the caller already checked the viewer)';

done_testing;
