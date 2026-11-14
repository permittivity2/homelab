use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;

# The runner's pure parts (#79, #80): the plain-parse gate that decides which
# arriving email is sent to the AI at all, when a reminder is due, and the
# reminder message itself. The queue and the sends need the database and the
# submission VIP; they are proven on the live pool (README.md).

use lib 'lib';
use_ok 'Homelab::Calendar::Runner';
Homelab::Calendar::Runner->import(qw(looks_like_event reminder_message));

my $now = DateTime->new(year => 2026, month => 11, day => 14, hour => 10, time_zone => 'America/Chicago');

# --- the gate -------------------------------------------------------------
ok looks_like_event('Dentist', "Your appointment is on November 20 at 3:30 PM.\nSee you then.", zone => 'America/Chicago', now => $now), 'a date and a time: an event';
ok looks_like_event('Game day', 'Delta State plays Valdosta State 11/22 at McCool Field', zone => 'America/Chicago', now => $now), 'a numeric date: an event';
ok looks_like_event('Lunch?', 'Lunch tomorrow?', zone => 'America/Chicago', now => $now), '"tomorrow": an event';
ok looks_like_event('Team meeting', 'Moving the meeting to Thursday, same room.', zone => 'America/Chicago', now => $now), 'a weekday with an event word';
ok looks_like_event('Re: coffee', 'Does 2pm work?', zone => 'America/Chicago', now => $now), 'a clock time alone';
ok !looks_like_event('Hello', 'Just saying hi, hope Monday was good.', zone => 'America/Chicago', now => $now), 'a weekday without an event word: not an event';
ok !looks_like_event('Your order has shipped', 'Track your package. Meeting the carrier on Tuesday is not needed.', zone => 'America/Chicago', now => $now), 'transactional noise is skipped even with event words';
ok !looks_like_event('Weekly newsletter', 'This week in tech: 10 things.', zone => 'America/Chicago', now => $now), 'a newsletter is skipped';
ok !looks_like_event('Thanks', 'Thanks for everything!', zone => 'America/Chicago', now => $now), 'nothing date-like at all';
ok !looks_like_event('', '', zone => 'America/Chicago', now => $now), 'empty is not an event';

# --- when a reminder is due ------------------------------------------------
my $s = DateTime->new(year => 2026, month => 11, day => 20, hour => 15, minute => 30, time_zone => 'America/Chicago');
my $timed = { all_day => 0, start => $s, end => $s->clone->add(hours => 1), title => 'Dentist', location => '12 Main St, Cleveland, MS', description => "Bring the card.\r\nAsk about X." };
is Homelab::Calendar::Runner::due_at($timed, 10)->strftime('%H:%M'), '15:20', '10 minutes before a timed occurrence';
is Homelab::Calendar::Runner::due_at($timed, 0)->strftime('%H:%M'), '15:30', '0 = at the time';
my $d = DateTime->new(year => 2026, month => 11, day => 20, time_zone => 'America/Chicago');
my $allday = { all_day => 1, start => $d, end => $d->clone->add(days => 1), title => 'Conference', location => undef, description => undef };
is Homelab::Calendar::Runner::due_at($allday, 10)->strftime('%Y-%m-%d %H:%M'), '2026-11-20 08:50', 'an all-day event is reminded relative to 9 AM, not midnight';
is Homelab::Calendar::Runner::due_at($allday, 1440)->strftime('%Y-%m-%d %H:%M'), '2026-11-19 09:00', '... a day before = 9 AM the day before';
is Homelab::Calendar::Runner::due_at($allday, 10, 7)->strftime('%H:%M'), '06:50', 'the account may choose the all-day hour (0.2.0)';
is Homelab::Calendar::Runner::due_at($allday, 0, 'nonsense')->strftime('%H:%M'), '09:00', '... a bad hour falls back to 9';

# --- the message -------------------------------------------------------------
my $m = reminder_message(inst => $timed, zone => 'America/Chicago', minutes => 10, owner => 'me@example.test', recipient => 'me@example.test',
    base_url => 'https://calendar.example.test', now => $s->clone->subtract(minutes => 10));
is $m->{subject}, 'Reminder: Dentist at 3:30 PM today', 'subject names the time and the day';
like $m->{body}, qr/^Dentist\nFriday, November 20, 2026 3:30 PM to 4:30 PM \(America\/Chicago\)\n/, 'body opens with the title and the span';
like $m->{body}, qr/^Where: 12 Main St, Cleveland, MS$/m, 'the place';
like $m->{body}, qr{^Map: https://www\.google\.com/maps/search/\?api=1&query=12\+Main\+St%2C\+Cleveland%2C\+MS$}m, 'a Google Maps link, URL-encoded';
like $m->{body}, qr/Bring the card\.\nAsk about X\./, 'the description, CRs removed';
like $m->{body}, qr/You set a reminder on this event \(10 minutes before\)\./, 'the owner is told it is their own reminder';
like $m->{body}, qr{Where reminders go, and turning them off: https://calendar\.example\.test/settings}, 'and where to change it';
unlike $m->{body}, qr/\r/, 'no CR anywhere in the body';

my $m2 = reminder_message(inst => $timed, zone => 'America/New_York', minutes => 60, owner => 'me@example.test', recipient => 'friend@example.test',
    base_url => 'https://calendar.example.test', now => $s->clone->subtract(days => 1));
is $m2->{subject}, 'Reminder: Dentist at 4:30 PM tomorrow', 'the recipient\'s own zone, and "tomorrow"';
like $m2->{body}, qr/me\@example\.test shared this event with you; its reminder \(1 hour before\) reaches you too\./, 'a shared-with person is told whose event it is';

my $m3 = reminder_message(inst => $allday, zone => 'America/Chicago', minutes => 1440, owner => 'me@example.test', recipient => 'me@example.test',
    base_url => 'https://calendar.example.test', now => $d->clone->subtract(days => 4));
is $m3->{subject}, 'Reminder: Conference Fri, Nov 20', 'an all-day subject carries the day, no clock';
like $m3->{body}, qr/Friday, November 20, 2026 \(all day\)/, '... and says all day';
like $m3->{body}, qr/\(1 day before\)/, 'the lead in days';
unlike $m3->{body}, qr/Where:/, 'no place line without a place';

my $m4 = reminder_message(inst => { %$allday, end => $d->clone->add(days => 3) }, zone => 'America/Chicago', minutes => 0, owner => 'a@x.test', recipient => 'a@x.test',
    base_url => 'https://c.test', now => $d);
like $m4->{body}, qr/Friday, November 20 to Sunday, November 22, 2026/, 'a multi-day all-day span names its last day';
like $m4->{body}, qr/\(at the time it starts\)/, 'a 0-minute lead reads as "at the time"';

done_testing;
