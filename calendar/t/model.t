use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);
use lib 'lib';

# The data paths against a real PostgreSQL (post-cutover #83): calendars and
# events, a series expanded, cancelled and split, reminders (several per
# event, the queue's claim), shares and the per-recipient reminder switch,
# the trash, search, the duplicate check, the sidebar's order, mail links
# made and dismissed per account, the metrics. Needs TEST_PG_URL
# (postgres://user:pass@host:port/db) with the calendar migrations applied;
# CI's calendar-db-tests job does both. Skips otherwise.
plan skip_all => 'TEST_PG_URL not set (a PostgreSQL with the calendar schema)' unless $ENV{TEST_PG_URL};
require Mojo::Pg;
require Homelab::Calendar::Model;

my $pg = Mojo::Pg->new($ENV{TEST_PG_URL});
my $m  = Homelab::Calendar::Model->new(pg => $pg, uid_domain => 'calendar.example.test', default_zone => 'America/Chicago');
my $db = $pg->db;
my $tag = 'modeltest-' . time . "-$$";
my ($alice, $bob) = ("$tag-alice\@example.test", "$tag-bob\@example.test");
my ($tok1, $tok2) = (sha256_hex("$tag-1"), sha256_hex("$tag-2"));
sub dt (%a) { return DateTime->new(%a, time_zone => 'America/Chicago') }
sub cleanup {
    $db->query('DELETE FROM calendar.mail_links WHERE token IN (?, ?)', $tok1, $tok2);
    $db->query('DELETE FROM calendar.itip_inbox WHERE attendee_email LIKE ?', "$tag-%");
    $db->query('DELETE FROM calendar.calendars WHERE owner_email LIKE ?', "$tag-%");    # events, attendees, notices, shares cascade
    $db->query("DELETE FROM calendar.$_ WHERE user_email LIKE ?", "$tag-%") for qw(user_prefs account_settings reminder_addresses calendar_visibility);
}
END { cleanup() if $db }

# --- calendars and events ----------------------------------------------------
my $cal = $m->ensure_default_calendar($alice, 'America/Chicago');
ok $cal->{is_default}, 'a first visit makes the default calendar';
is $m->ensure_default_calendar($alice, 'America/Chicago')->{id}, $cal->{id}, '... once';
my $ev = $m->create_event($cal, $alice, { title => 'Dentist', start => '2026-11-20T14:30:00', end => '2026-11-20T15:30:00', timezone => 'America/Chicago', location => 'Delta Dental' });
ok $ev->{id}, 'an event';
like $ev->{uid}, qr/\@calendar\.example\.test\z/, '... with a UID of ours';
my $imp = $m->create_event($cal, $alice, { title => 'Imported', start => '2026-11-21', all_day => 1, uid => "$tag-foreign\@example.com" });
is $imp->{uid}, "$tag-foreign\@example.com", 'an import keeps its UID';
ok $m->uid_taken("$tag-foreign\@example.com"), '... which is then taken';
is $m->event_by_uid("$tag-foreign\@example.com")->{id}, $imp->{id}, '... and found live';
eval { $m->create_event($cal, $alice, { title => '', start => '2026-11-21T09:00:00' }) };
like $@, qr/title/, 'no title: refused with a sentence';

# --- a series: expanded, one occurrence cancelled, then split --------------
my $series = $m->create_event($cal, $alice, { title => 'Stand-up', start => '2026-11-16T09:00:00', end => '2026-11-16T09:15:00',
    timezone => 'America/Chicago', repeat => 'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=9' });
ok $series->{rrule}, 'a weekly series';
my $w = sub { $m->instances(events => [ $m->event($series->{id}) ], window_start => dt(year => 2026, month => 11, day => 16), window_end => dt(year => 2026, month => 12, day => 7)) };
is scalar @{ $w->() }, 9, 'nine occurrences in three weeks';
$m->_write_exception($series, dt(year => 2026, month => 11, day => 18, hour => 9), {}, 1);
is scalar @{ $w->() }, 8, 'a cancelled occurrence drops out';
my $new = $m->update_event($m->event($series->{id}), { title => 'Stand-up (new room)' }, scope => 'following', recurrence_id => dt(year => 2026, month => 11, day => 27, hour => 9));
isnt $new->{id}, $series->{id}, 'a "following" change splits the series';
like $m->event($series->{id})->{rrule}, qr/UNTIL=/, '... the old one now ends';
is $new->{title}, 'Stand-up (new room)', '... the new one carries the change';
is scalar(grep { $_->{event_id} == $series->{id} } @{ $w->() }), 4, '... four occurrences stay with the old series (Nov 16, 20, 23, 25)';

# --- reminders: several per event, what stays keeps its row, the queue -----
$m->set_reminders($ev->{id}, [ { minutes_before => 10, channel => 'email' }, { minutes_before => 60, channel => 'webhook' } ]);
is scalar @{ $m->reminders_for($ev->{id}) }, 2, 'two reminders';
is $m->reminder_for($ev->{id})->{minutes_before}, 10, '... the soonest email one is "the" reminder for older clients';
my $kept = $m->reminders_for($ev->{id})->[0]{id};
$m->set_reminders($ev->{id}, [ { minutes_before => 10, channel => 'email' }, { minutes_before => 1440, channel => 'email' } ]);
is $m->reminders_for($ev->{id})->[0]{id}, $kept, 'a reminder that stays keeps its row';
is scalar @{ $m->reminders_for($ev->{id}) }, 2, '... the webhook one went, a day-before one came';
eval { $m->set_reminders($ev->{id}, [ 1, 2, 3, 4 ]) };
like $@, qr/At most 3/, 'four refused';
my $cands = $m->reminder_candidates(dt(year => 2026, month => 11, day => 19), dt(year => 2026, month => 11, day => 22));
is scalar(grep { $_->{id} == $ev->{id} } @$cands), 2, 'one candidate row per reminder of the event';
my ($r10) = grep { $_->{id} == $ev->{id} && $_->{minutes_before} == 10 } @$cands;
my $occ = dt(year => 2026, month => 11, day => 20, hour => 14, minute => 30);
$m->queue_reminder(reminder_id => $r10->{reminder_id}, event_id => $ev->{id}, recurrence_id => $occ, recipient => $alice, due_at => DateTime->now->subtract(minutes => 1)) for 1, 2;
my @mine = grep { $_->{event_id} == $ev->{id} } @{ $m->claim_due_reminders(50) };
is scalar @mine, 1, 'queued once (the unique key), claimed once';
is $mine[0]{state}, 'running', '... as running';
$m->reminder_sent($mine[0]{id});
is $db->query('SELECT state FROM calendar.reminder_queue WHERE id = ?', $mine[0]{id})->array->[0], 'sent', '... then sent';

# --- a share, and the recipient's switches -----------------------------------
$m->create_share(owner => $alice, event_id => $ev->{id}, shared_with_email => $bob, permission => 'read');
is_deeply $m->shared_with_accounts($ev), [$bob], 'Bob is a shared-with account';
is $m->prefs($bob)->{remind_shared}, 1, 'he gets shared reminders by default';
$m->save_prefs($bob, { remind_shared => 0, all_day_reminder_hour => 7, date_format => 'dmy', webhook_url => ' https://example.test/hook ' });
my $p = $m->prefs($bob);
is $p->{remind_shared}, 0, '... until he turns them off';
is $p->{all_day_reminder_hour}, 7, 'his all-day hour';
is $p->{date_format}, 'dmy', 'his date order';
is $p->{webhook_url}, 'https://example.test/hook', 'his webhook, trimmed';
eval { $m->save_prefs($bob, { all_day_reminder_hour => 24 }) };
like $@, qr/0 to 23/, 'a bad hour is refused';
is $m->permission_for_event($bob, $m->event($ev->{id})), 'read', 'Bob may see the event';

# --- the trash ---------------------------------------------------------------
$m->delete_event($m->event($ev->{id}), scope => 'all');
is $m->event($ev->{id}), undef, 'deleted: not an event any more';
is scalar(grep { $_->{id} == $ev->{id} } @{ $m->trashed_events($alice) }), 1, '... but in the trash';
ok $m->deleted_event($ev->{id}), '... found as deleted';
$m->restore_event($ev->{id});
ok $m->event($ev->{id}), 'restored';
is scalar(grep { $_->{id} == $ev->{id} } @{ $m->trashed_events($alice) }), 0, '... and out of the trash';
is scalar @{ $m->reminders_for($ev->{id}) }, 2, '... with its reminders';

# --- search, the duplicate check, the sidebar's order -----------------------
is $m->search_events($alice, 'dent')->[0]{id}, $ev->{id}, 'search finds the dentist by title';
is $m->search_events($alice, 'delta')->[0]{id}, $ev->{id}, '... and by place';
is scalar @{ $m->search_events($alice, 'nothing-like-this') }, 0, '... and nothing else';
is $m->similar_events($alice, ' dentist ', dt(year => 2026, month => 11, day => 20, hour => 9))->[0]{id}, $ev->{id}, 'a likely duplicate: same title, same day';
is scalar @{ $m->similar_events($alice, 'Dentist', dt(year => 2026, month => 11, day => 25)) }, 0, '... not another day';
my $cal2 = $m->create_calendar($alice, name => 'Second');
my $cal3 = $m->create_calendar($alice, name => 'Third');
ok $m->move_calendar($alice, $cal3->{id}, 'up'), 'the third moves up';
is_deeply [ map { $_->{id} } @{ $m->calendars_for($alice)->{own} } ], [ $cal->{id}, $cal3->{id}, $cal2->{id} ], '... above the second; the default stays first';
ok !$m->move_calendar($alice, $cal->{id}, 'up'), 'the first cannot move up';

# --- mail links: made and dismissed per account ------------------------------
for my $t ($tok1, $tok2) {
    $db->query(q{INSERT INTO calendar.mail_links (token, accounts, subject, from_addr, text_excerpt, expires_at, proposal, proposed_at, job_state)
                 VALUES (?, ?::jsonb, 'Dentist moved', 'office@example.test', 'the text', NOW() + INTERVAL '10 days', ?::jsonb, NOW(), 'done')},
        $t, encode_json([ $alice, $bob ]), encode_json({ title => 'Dentist', start => '2026-11-23T14:30:00', end => '2026-11-23T15:30:00', all_day => 0, confidence => 'high' }));
}
my $link = $m->mail_link_for($tok1, $alice);
ok $link, 'a link row for both accounts';
is scalar @{ $m->suggestions_for($alice) }, 2, 'Alice has both suggestions';
is scalar @{ $m->suggestions_for($bob) }, 2, '... so does Bob';
$m->mail_link_used($link->{id}, $ev->{id}, $alice);
is scalar @{ $m->mail_link_events_for($link->{id}, $alice) }, 1, 'Alice made an event from the first';
is scalar @{ $m->mail_link_events_for($link->{id}, $bob) }, 0, '... Bob did not';
ok $m->mail_link_made_by($link->{id}, $alice), 'made by Alice';
ok !$m->mail_link_made_by($link->{id}, $bob), '... not by Bob';
is scalar @{ $m->suggestions_for($alice) }, 1, 'her suggestion is consumed';
is scalar @{ $m->suggestions_for($bob) }, 2, '... his are not';
$m->dismiss_suggestion($link->{id}, $bob);
is scalar @{ $m->suggestions_for($bob) }, 1, 'Bob dismissed his copy';
is $m->suggestions_count($bob), 1, '... the count agrees';
is scalar @{ $m->suggestions_for($alice) }, 1, '... and Alice still has her other one';
$m->delete_event($m->event($ev->{id}), scope => 'all');
is scalar @{ $m->mail_link_events_for($link->{id}, $alice) }, 0, 'a deleted event drops out of the link\'s live list';
ok $m->mail_link_made_by($link->{id}, $alice), '... but the suggestion stays consumed';

# --- metrics -----------------------------------------------------------------
my $met = $m->metrics;
ok defined $met->{events} && defined $met->{reminders_overdue} && defined $met->{reminders}, 'the metrics have their numbers';

# --- invitations (#85): attendees, the notice queue, answers, free/busy, mailed replies ---
my ($carol, $dave) = ("$tag-carol\@example.test", "$tag-dave\@example.test");
my $lunch = $m->create_event($cal, $alice, { title => 'Lunch', start => '2026-11-20T12:30:00', end => '2026-11-20T13:30:00', timezone => 'America/Chicago', location => 'Cafe' });
my $notices = sub ($kind = undef) { [ grep { !$kind || $_->{kind} eq $kind } @{ $m->notices_for($lunch->{id}) } ] };
my $r = $m->add_attendees($lunch, [ "Bob <$bob>", $carol, " $carol ", 'not-an-address' x 0 ]);
is scalar @{ $r->{added} }, 2, 'two people invited (one twice counts once)';
is $r->{added}[0]{name}, 'Bob', '... a name is kept';
is $r->{added}[0]{email}, $bob, '... the address lower-cased';
like $r->{added}[0]{token}, qr/\A[0-9a-f]{64}\z/, '... each with an RSVP token';
is $r->{added}[0]{status}, 'needs-action', '... waiting';
is scalar @{ $notices->('request') }, 2, 'a request is queued for each';
ok $notices->('request')->[0]{due_at} gt $notices->('request')->[0]{created_at}, '... a few seconds out, so quick edits send one mail';
is scalar @{ $m->viewer_event_shares($bob) }, 1, 'an invited account sees the event in its own calendar (a read-only share)';
is $m->permission_for_event($bob, $m->event($lunch->{id})), 'read', '... read-only';
$r = $m->add_attendees($lunch, [ $bob ]);
is scalar @{ $r->{existing} }, 1, 'inviting someone again: already there';
is scalar @{ $r->{added} }, 0, '... nothing new';
eval { $m->add_attendees($lunch, [ $alice ]) };
like $@, qr/organizer/, 'the organizer cannot invite herself';
eval { $m->add_attendees($lunch, [ 'nobody' ]) };
like $@, qr/does not look like an email address/, 'a bad address is refused with a sentence';
is_deeply $m->attendee_counts([ $lunch->{id} ])->{ $lunch->{id} }, { total => 2, accepted => 0, tentative => 0, declined => 0, waiting => 2 }, 'the counts';
is_deeply $m->my_attendance($bob, [ $lunch->{id} ]), { $lunch->{id} => 'needs-action' }, 'Bob\'s own answer so far';

# the queue: claim, send, mark
my $pending = $m->claim_due_notices(10);
is scalar @$pending, 0, 'nothing due yet (the grace period)';
$db->query('UPDATE calendar.notice_queue SET due_at = NOW() WHERE event_id = ?', $lunch->{id});
$pending = $m->claim_due_notices(10);
is scalar @$pending, 2, 'both due now and claimed';
is $pending->[0]{state}, 'running', '... running';
is ref $pending->[0]{payload}, 'HASH', '... the payload decoded';
is $pending->[0]{payload}{reason}, 'invited', '... an invitation';
is scalar @{ $m->claim_due_notices(10) }, 0, 'a second claim gets nothing: no double send';
$m->notice_sent($pending->[0]{id});
$m->attendee_mark_sent($lunch->{id}, $pending->[0]{recipient}, 0);
ok defined $m->attendee_of($lunch->{id}, $pending->[0]{recipient})->{sequence_sent}, 'the attendee remembers the sequence sent';
$m->notice_failed($pending->[1]{id}, 'SMTP down');
is((grep { $_->{id} == $pending->[1]{id} } @{ $notices->() })[0]{state}, 'pending', 'a failed send goes back to the queue');
$db->query('UPDATE calendar.notice_queue SET attempts = 3 WHERE id = ?', $pending->[1]{id});
$m->notice_failed($pending->[1]{id}, 'SMTP down');
is((grep { $_->{id} == $pending->[1]{id} } @{ $notices->() })[0]{state}, 'failed', '... and fails for good on the third try');

# an answer, and the note to the organizer
my $bobrow = $m->attendee_of($lunch->{id}, $bob);
my $ans = $m->set_attendee_status($bobrow, 'yes', comment => '  Bringing dessert ', via => 'link');
is $ans->{status}, 'accepted', 'yes means accepted';
is $ans->{comment}, 'Bringing dessert', '... the note trimmed';
is $ans->{responded_via}, 'link', '... how';
ok $ans->{responded_at}, '... when';
my @reply = @{ $notices->('reply') };
is scalar @reply, 1, 'the organizer is told';
is $reply[0]{recipient}, $alice, '... at her address';
is_deeply $m->attendee_counts([ $lunch->{id} ])->{ $lunch->{id} }, { total => 2, accepted => 1, tentative => 0, declined => 0, waiting => 1 }, 'the counts follow';
eval { $m->set_attendee_status($bobrow, 'perhaps') };
like $@, qr/accepted, tentative or declined/, 'an unknown answer is refused';
my $by_token = $m->attendee_by_token($bobrow->{token});
is $by_token->{event}{id}, $lunch->{id}, 'the token finds the attendee, event and calendar';
is $by_token->{calendar}{owner_email}, $alice, '... (the organizer)';
ok !$m->attendee_by_token('0' x 64), 'an unknown token finds nothing';

# a change: a retitle keeps the answers, a new time asks again with SEQUENCE+1.
# (Found here 2026-11-15: with the database session in America/Chicago, as
# production's is, the old string compare of starts_at saw every edit as a
# time change; _same_instant compares instants.)
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
$m->_write_exception($series, dt(year => 2026, month => 11, day => 20, hour => 9), { title => 'Stand-up (moved)', start => '2026-11-20T10:00:00', end => '2026-11-20T10:15:00' }, 0);
$m->update_event($m->event($series->{id}), { description => 'a retitle-sized change' });
is scalar @{ $m->exceptions_for($series->{id}) }, 2, 'a retitle of a series keeps its moved and cancelled occurrences';
$m->update_event($m->event($lunch->{id}), { title => 'Lunch (tacos)' });
is scalar @{ $notices->('request') }, 2, 'a retitle: everyone hears';
is $m->attendee_of($lunch->{id}, $bob)->{status}, 'accepted', '... Bob\'s yes stands';
is $m->event($lunch->{id})->{sequence}, 0, '... the sequence is unchanged';
is $notices->('request')->[0]{payload}{changed}[0], 'details', '... the mail says the details changed';
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
my $moved = $m->update_event($m->event($lunch->{id}), { start => '2026-11-20T13:00:00', end => '2026-11-20T14:00:00', timezone => 'America/Chicago' });
is $m->event($lunch->{id})->{sequence}, 1, 'a new time bumps the sequence';
is $moved->{sequence}, 1, '... and the row handed back carries the bumped value (seen stale live, 0.3.1)';
is $m->attendee_of($lunch->{id}, $bob)->{status}, 'needs-action', '... and asks Bob again';
is $notices->('request')->[0]{payload}{changed}[0], 'time', '... the mail says the time changed';
is $notices->('request')->[0]{payload}{sequence}, 1, '... and carries the new sequence';
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
$m->update_event($m->event($lunch->{id}), { description => 'the same' });
$m->update_event($m->event($lunch->{id}), { description => 'the same again' });
is scalar @{ $notices->('request') }, 2, 'two quick edits: one pending request per person, not two';

# the whole list from the editor: one off, one on
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
my $list = $m->set_attendees($m->event($lunch->{id}), [ $carol, $dave ]);
is_deeply [ sort map { $_->{email} } @$list ], [ sort $carol, $dave ], 'Bob is off, Dave is on';
is scalar @{ $notices->('cancel') }, 1, 'Bob, who had the invitation, gets a cancel';
is $notices->('cancel')->[0]{recipient}, $bob, '... addressed to him';
is $notices->('cancel')->[0]{payload}{name}, 'Bob', '... with his name (his row is gone)';
is scalar @{ $m->viewer_event_shares($bob) }, 0, '... and his share is revoked';
is scalar @{ $notices->('request') }, 1, 'Dave gets an invitation';
is $notices->('request')->[0]{recipient}, $dave, '... addressed to him';

# free/busy for accounts here
my $fb = $m->freebusy([ $alice, $bob, 'stranger@example.net' ], dt(year => 2026, month => 11, day => 20, hour => 13), dt(year => 2026, month => 11, day => 20, hour => 14));
is scalar @$fb, 3, 'three people asked about';
my %fb = map { $_->{email} => $_ } @$fb;
ok $fb{$alice}{known}, 'Alice has a calendar here';
is scalar @{ $fb{$alice}{busy} }, 1, '... and is busy: the lunch';
ok $fb{$bob}{known} || !@{ $fb{$bob}{busy} }, 'Bob: known or free, never busy from someone else\'s event';
ok !$fb{'stranger@example.net'}{known}, 'a stranger is not known';
is scalar @{ $m->freebusy([ $alice ], dt(year => 2026, month => 11, day => 20, hour => 15), dt(year => 2026, month => 11, day => 20, hour => 16))->[0]{busy} }, 0, 'Alice is free at three';
eval { $m->freebusy([ ($alice) x 21 ], dt(year => 2026, month => 11, day => 20), dt(year => 2026, month => 11, day => 21)) };
like $@, qr/At most 20/, 'too many addresses: refused';

# an answer that came by mail (the milter's inbox row)
$db->query('INSERT INTO calendar.itip_inbox (uid, attendee_email, partstat, sequence) VALUES (?, ?, ?, ?)', $m->event($lunch->{id})->{uid}, uc $dave, 'TENTATIVE', 1);
$db->query('INSERT INTO calendar.itip_inbox (uid, attendee_email, partstat, sequence) VALUES (?, ?, ?, ?)', 'nothing@calendar.example.test', $dave, 'ACCEPTED', 1);
$db->query('INSERT INTO calendar.itip_inbox (uid, attendee_email, partstat, sequence) VALUES (?, ?, ?, ?)', $m->event($lunch->{id})->{uid}, $bob, 'ACCEPTED', 1);
my $inbox = $m->claim_itip_inbox(10);
is scalar @$inbox, 3, 'three mailed answers claimed';
is scalar @{ $m->claim_itip_inbox(10) }, 0, '... once';
my %res = map { $_->{attendee_email} . '/' . $_->{uid} => $m->apply_itip_reply($_) } @$inbox;
is $res{ uc($dave) . '/' . $m->event($lunch->{id})->{uid} }, 'recorded: tentative', 'Dave\'s maybe is recorded (address case ignored)';
is $m->attendee_of($lunch->{id}, $dave)->{status}, 'tentative', '... on his row';
is $m->attendee_of($lunch->{id}, $dave)->{responded_via}, 'mail', '... as having come by mail';
like $res{"$dave/nothing\@calendar.example.test"}, qr/no live event/, 'an unknown UID is noted, not applied';
like $res{ "$bob/" . $m->event($lunch->{id})->{uid} }, qr/not an attendee/, 'someone no longer invited is noted, not applied';

# cancelled: a CANCEL to everyone who had the invitation
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
$m->attendee_mark_sent($lunch->{id}, $dave, 1);
my $seq0 = $m->event($lunch->{id})->{sequence};
$m->delete_event($m->event($lunch->{id}), scope => 'all');
is scalar @{ $notices->('cancel') }, 1, 'the delete sends one cancel: to Dave, who had the invitation';
is $notices->('cancel')->[0]{recipient}, $dave, '... Carol never got hers, so gets no cancel';
is $m->deleted_event($lunch->{id})->{sequence}, $seq0 + 1, '... with the sequence bumped';
$db->query('DELETE FROM calendar.notice_queue WHERE event_id = ?', $lunch->{id});
$m->restore_event($lunch->{id});
is scalar @{ $notices->('request') }, 2, 'restored: both are asked again';
is $m->event($lunch->{id})->{sequence}, $seq0 + 2, '... with the sequence bumped once more';
is $notices->('request')->[0]{payload}{reason}, 'restored', '... as "back on"';

cleanup();
done_testing;
