use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::Pg;
use DateTime;
use lib 'lib';

# The model half of CalDAV (post-cutover #84): app passwords, the change
# counter migration 009 stamps (the ETag and the sync token), the object
# listings, and a calendar by the name a client gave it. Needs TEST_PG_URL
# with the calendar migrations applied, as model.t does.
plan skip_all => 'TEST_PG_URL not set (a PostgreSQL with the calendar schema)' unless $ENV{TEST_PG_URL};

use Homelab::Calendar::Model;
use Homelab::Calendar::ICS ();
use Homelab::Calendar::Recurrence qw(parse_wall);

my $pg = Mojo::Pg->new($ENV{TEST_PG_URL});
my $m  = Homelab::Calendar::Model->new(pg => $pg, uid_domain => 'calendar.example.test', default_zone => 'America/Chicago');
my $ME = 'davm-' . int(rand 1e9) . '@example.test';
my $cal = $m->ensure_default_calendar($ME, 'America/Chicago');

# --- app passwords ---
my $d = $m->create_app_password($ME, "  Dana's   iPhone ");
is $d->{label}, "Dana's iPhone", 'the label is tidied';
like $d->{secret}, qr/\A(?:[a-km-np-z2-9]{4}-){5}[a-km-np-z2-9]{4}\z/, 'a 24-character secret in groups of four, no look-alikes';
ok $m->verify_app_password($ME, $d->{secret}), 'it opens';
ok $m->verify_app_password(uc $ME, uc($d->{secret} =~ s/-/ /gr)), '... however it is typed';
ok !$m->verify_app_password($ME, 'abcd-' x 5 . 'abcd'), 'another secret does not';
ok !$m->verify_app_password('someone-else@example.test', $d->{secret}), '... nor for another address';
ok !$m->verify_app_password($ME, ''), '... nor nothing at all';
is scalar @{ $m->app_passwords_for($ME) }, 1, 'listed';
ok !exists $m->app_passwords_for($ME)->[0]{secret_hash}, '... without the hash';
$m->touch_app_password($d->{id}, "iOS/26.1 dataaccessd\x00");
is $m->app_passwords_for($ME)->[0]{last_used_agent}, 'iOS/26.1 dataaccessd', 'last use stamped, control characters dropped';
ok !eval { $m->create_app_password($ME, ''); 1 }, 'no label: refused';
like $@, qr/Name the device/, '... and told';
my $second = $m->create_app_password($ME, 'Laptop');
isnt $second->{secret}, $d->{secret}, 'every secret is its own';
ok $m->verify_app_password($ME, $second->{secret}) && $m->verify_app_password($ME, $d->{secret}), 'both open';
ok $m->revoke_app_password($ME, $d->{id}), 'revoked';
ok !$m->verify_app_password($ME, $d->{secret}), '... and closed';
ok $m->verify_app_password($ME, $second->{secret}), '... the other still open';
ok !$m->revoke_app_password($ME, $d->{id}), 'twice: no';
ok !$m->revoke_app_password('someone-else@example.test', $second->{id}), 'another address cannot revoke mine';
is scalar @{ $m->app_passwords_for($ME) }, 1;

# --- the change counter, the sync listings ---
is $m->sync_seq($cal->{id}), 0, 'an empty calendar: token 0';
my $e = $m->create_event($cal, $ME, { title => 'One', start => '2026-12-01T09:00:00', end => '2026-12-01T10:00:00', timezone => 'America/Chicago' });
ok $e->{change_seq} > 0, 'a new event is stamped';
my $s1 = $m->sync_seq($cal->{id});
is $s1, $e->{change_seq}, 'the calendar token is the newest stamp';
my $e2 = $m->update_event($e, { title => 'One (edited)' });
ok $e2->{change_seq} > $e->{change_seq}, 'an edit stamps again';
my $r = $m->create_event($cal, $ME, { title => 'Daily', start => '2026-12-02T09:00:00', end => '2026-12-02T09:30:00', timezone => 'America/Chicago', repeat => 'FREQ=DAILY;COUNT=5' });
my $before = $m->event($r->{id})->{change_seq};
$m->_write_exception($r, parse_wall('2026-12-03T09:00:00', 'America/Chicago'), {}, 1);
ok $m->event($r->{id})->{change_seq} > $before, 'cancelling one occurrence stamps the series';
$before = $m->event($r->{id})->{change_seq};
$m->set_reminders($r->{id}, [ { minutes_before => 15, channel => 'email' } ]);
is $m->event($r->{id})->{change_seq}, $before, 'a reminder is not part of the object the way a part is (no stamp)';
my $changed = $m->events_changed_since($cal->{id}, $s1);
is_deeply [ sort { $a <=> $b } map { $_->{id} } @$changed ], [ sort { $a <=> $b } $e->{id}, $r->{id} ], 'changed since the first token: both';
my $s2 = $m->sync_seq($cal->{id});
is_deeply $m->events_changed_since($cal->{id}, $s2), [], 'nothing since the newest';
$m->delete_event($m->event($e->{id}));
my $gone = $m->events_changed_since($cal->{id}, $s2);
is scalar @$gone, 1, 'a deletion is a change';
ok $gone->[0]{deleted_at}, '... marked as one';
is_deeply [ map { $_->{id} } @{ $m->dav_events($cal->{id}) } ], [ $r->{id} ], 'dav_events lists the live ones';
my $ws = DateTime->new(year => 2026, month => 12, day => 3, time_zone => 'UTC');
my $we = $ws->clone->add(days => 1);
is scalar @{ $m->dav_events($cal->{id}, window_start => $ws, window_end => $we) }, 1, '... in a window the series reaches';
is scalar @{ $m->dav_events($cal->{id}, window_start => $ws->clone->add(years => 1), window_end => $we->clone->add(years => 1)) }, 0, '... not in one it does not';
ok $m->trashed_event_by_uid($cal->{id}, $e->{uid}), 'the deleted one is found by uid in the trash';
ok !$m->event_in_calendar_by_uid($cal->{id}, $e->{uid}), '... and not among the live';
ok $m->event_in_calendar_by_uid($cal->{id}, $r->{uid}), 'the live one is';
ok !$m->event_in_calendar_by_uid($cal->{id} + 1_000_000, $r->{uid}), '... only in its own calendar';
$m->clear_exceptions($r->{id});
is scalar @{ $m->exceptions_for($r->{id}) }, 0, 'clear_exceptions';

# --- the object as masters_ics writes it ---
my $entry = $m->masters_entry($m->event($r->{id}));
is $entry->{rrule}, 'FREQ=DAILY;COUNT=5', 'the rule';
is_deeply $entry->{alarms}, [ { minutes => 15 } ], 'reminders become alarms';
my $ics = Homelab::Calendar::ICS::masters_ics(method => 'none', zone => 'America/Chicago', events => [ $entry ]);
like $ics, qr/BEGIN:VALARM\r?\n.*?TRIGGER:-PT15M.*?END:VALARM/s, '... written as a VALARM';
unlike $ics, qr/^METHOD:/m, 'no METHOD when asked for none';
like Homelab::Calendar::ICS::masters_ics(zone => 'America/Chicago', events => [ $entry ]), qr/^METHOD:PUBLISH/m, '... and PUBLISH as before otherwise';

# --- a calendar by the name a client gave it ---
ok !$m->calendar_by_dav_name($ME, 'nope'), 'an unknown name: nothing';
ok !$m->calendar_by_dav_name($ME, '9' x 30), 'an absurd number: nothing, not an error';
is $m->calendar_by_dav_name($ME, $cal->{id})->{id}, $cal->{id}, 'by number';
is Homelab::Calendar::Model::dav_segment($cal), "$cal->{id}", '... which is its segment';
$m->set_dav_name($cal->{id}, 'ABCD-1234');
is $m->calendar_by_dav_name($ME, 'ABCD-1234')->{id}, $cal->{id}, 'by the name a client gave';
is Homelab::Calendar::Model::dav_segment($m->calendar($cal->{id})), 'ABCD-1234', '... which is now its segment';

$pg->db->query('DELETE FROM calendar.calendars WHERE lower(owner_email) = ?', $ME);
$pg->db->query('DELETE FROM calendar.app_passwords WHERE lower(user_email) = ?', $ME);
done_testing;
