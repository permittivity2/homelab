use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;
use lib 'lib';

# The invitation mail (post-cutover #85) as plain data: the subject and
# body of a request (new, changed, back on), a cancellation, the note to the
# organizer, the when-line, and the iCalendar text with METHOD, ORGANIZER,
# ATTENDEE and SEQUENCE. Pure functions; the runner adds the SMTP.
use Homelab::Calendar::Invite qw(request_message cancel_message reply_notice_message event_ics when_line status_word);

my $CHI = 'America/Chicago';
sub chi (@a) { return DateTime->new(year => $a[0], month => $a[1], day => $a[2], hour => $a[3] // 0, minute => $a[4] // 0, time_zone => $CHI) }
my $event = { id => 7, uid => 'abc@calendar.example.test', title => 'Lunch', description => "Tacos.\nBring cash.", location => '123 Main St, Austin',
    all_day => 0, timezone => $CHI, rrule => undef, sequence => 0 };
my ($start, $end) = (chi(2026, 11, 20, 12, 30), chi(2026, 11, 20, 13, 30));
my @attendees = ({ email => 'ann@example.com', name => 'Ann', status => 'accepted', token => 'a' x 64 },
                 { email => 'bob@example.com', name => undef, status => 'needs-action', token => 'b' x 64 });
my %common = (event => $event, start => $start, end => $end, organizer => 'owner@example.org', base_url => 'https://calendar.example.test',
    attendees => \@attendees, now => DateTime->new(year => 2026, month => 11, day => 15, hour => 12, time_zone => 'UTC'));

# --- the when-line ---
is when_line(start => $start, end => $end, all_day => 0, zone => $CHI), 'Friday, November 20, 2026 12:30 PM to 1:30 PM (America/Chicago)', 'a timed event on one day';
is when_line(start => $start, end => chi(2026, 11, 21, 9), all_day => 0, zone => $CHI), 'Friday, November 20, 2026 12:30 PM to Saturday, November 21, 2026 9:00 AM (America/Chicago)', '... across midnight names the end day';
is when_line(start => chi(2026, 11, 20), end => chi(2026, 11, 21), all_day => 1), 'Friday, November 20, 2026 (all day)', 'one all-day';
is when_line(start => chi(2026, 11, 20), end => chi(2026, 11, 23), all_day => 1), 'Friday, November 20 to Sunday, November 22, 2026 (all day)', 'several days, the end exclusive';
is status_word('tentative'), 'might come', 'the word for maybe';
is status_word(undef), 'has not answered', '... and for nothing yet';

# --- a new invitation ---
my $m = request_message(%common, attendee => $attendees[1], payload => { reason => 'invited' });
is $m->{subject}, 'Invitation: Lunch @ Fri Nov 20, 2026 12:30 PM (owner@example.org)', 'the subject: what, when, who';
like $m->{body}, qr/^owner\@example\.org invited you to this event\.\n/, 'the first line says who asks';
like $m->{body}, qr/\nLunch\nFriday, November 20, 2026 12:30 PM to 1:30 PM \(America\/Chicago\)\n/, 'title and when';
like $m->{body}, qr/\nWhere: 123 Main St, Austin\nMap: https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=123\+Main\+St%2C\+Austin\n/, 'where, with a map link';
like $m->{body}, qr/\nOrganizer: owner\@example\.org\n/, 'the organizer';
like $m->{body}, qr/\nTacos\.\nBring cash\.\n/, 'the description';
like $m->{body}, qr/\nAlso invited: Ann \(accepted\)\n/, 'the others, with their answers, not the recipient';
like $m->{body}, qr{\n  Yes:    https://calendar\.example\.test/i/b{64}\?answer=accepted\n  Maybe:  \S+\?answer=tentative\n  No:     \S+\?answer=declined\n}, 'three one-tap links with this person\'s token';
like $m->{body}, qr{Open the invitation \(and add it to your calendar\): https://calendar\.example\.test/i/b{64}\n}, 'and the page itself';
unlike $m->{body}, qr/a{64}/, 'never another person\'s token';

# --- changed, and back on ---
$m = request_message(%common, attendee => $attendees[0], payload => { reason => 'changed', changed => ['time', 'place'] });
is $m->{subject}, 'Updated invitation: Lunch @ Fri Nov 20, 2026 12:30 PM (owner@example.org)', 'a change is an updated invitation';
like $m->{body}, qr/^owner\@example\.org changed this event: the time and the place\.\nPlease answer again\.\n/, '... says what changed and asks again';
$m = request_message(%common, attendee => $attendees[0], payload => { reason => 'changed', changed => ['details'] });
like $m->{body}, qr/changed this event: the details\.\nYour answer stands\.\n/, 'a detail change keeps the answer';
$m = request_message(%common, attendee => $attendees[0], payload => { reason => 'restored' });
is $m->{subject}, 'Invitation again: Lunch @ Fri Nov 20, 2026 12:30 PM (owner@example.org)', 'back from the trash';
like $m->{body}, qr/put this event back on\. Please answer again\./, '... and says so';

# --- all-day, repeating ---
my $allday = { %$event, all_day => 1, rrule => 'FREQ=WEEKLY', location => undef, description => undef };
$m = request_message(%common, event => $allday, start => chi(2026, 11, 20), end => chi(2026, 11, 21), attendee => $attendees[1], payload => {});
is $m->{subject}, 'Invitation: Lunch @ Fri Nov 20, 2026 (owner@example.org)', 'an all-day subject has no clock';
like $m->{body}, qr/\nFriday, November 20, 2026 \(all day\)\nRepeats\.\n/, 'all day, repeats';
unlike $m->{body}, qr/Where:|Map:/, 'no place, no map';

# --- a cancellation ---
$m = cancel_message(%common, attendee => $attendees[0], payload => { reason => 'cancelled', sequence => 2 });
is $m->{subject}, 'Cancelled: Lunch @ Fri Nov 20, 2026 12:30 PM (owner@example.org)', 'cancelled';
like $m->{body}, qr/^owner\@example\.org cancelled this event\.\n/, '... first line';
$m = cancel_message(%common, attendee => $attendees[0], payload => { reason => 'removed', sequence => 2 });
is $m->{subject}, 'No longer invited: Lunch @ Fri Nov 20, 2026 12:30 PM (owner@example.org)', 'taken off the list';
like $m->{body}, qr/took you off the list/, '... first line';

# --- the note to the organizer ---
$m = reply_notice_message(%common, payload => { attendee => 'ann@example.com', name => 'Ann', status => 'accepted', comment => 'See you there' },
    counts => { total => 2, accepted => 1, tentative => 0, declined => 0, waiting => 1 }, url => 'https://calendar.example.test/?date=2026-11-20&event=7');
is $m->{subject}, 'Accepted: Lunch @ Fri Nov 20, 2026 12:30 PM (Ann (ann@example.com))', 'who accepted what';
like $m->{body}, qr/^Ann \(ann\@example\.com\) accepted "Lunch"\.\n\nThey wrote: See you there\n/, 'the answer and the note';
like $m->{body}, qr/\nSo far: 1 yes, 1 waiting of 2 invited\.\n/, 'the tally';
like $m->{body}, qr/\nOpen this event: https:\/\/calendar\.example\.test\/\?date=2026-11-20&event=7\n/, 'the deep link';
$m = reply_notice_message(%common, payload => { attendee => 'bob@example.com', status => 'tentative' });
is $m->{subject}, 'bob@example.com might come: Lunch @ Fri Nov 20, 2026 12:30 PM', 'maybe';
like $m->{body}, qr/^bob\@example\.com might come to "Lunch"\./, '... reads as a sentence';
$m = reply_notice_message(%common, payload => { attendee => 'bob@example.com', status => 'declined' });
like $m->{subject}, qr/^Declined: Lunch/, 'no';

# --- the iCalendar text (unfolded: RFC 5545 wraps lines at 75 octets) ---
sub flat ($s) { return $s =~ s/\r?\n[ \t]//gr }
my $ics = flat(event_ics(%common, method => 'REQUEST', sequence => 3, url => 'https://calendar.example.test/i/' . ('b' x 64)));
like $ics, qr/^METHOD:REQUEST\r?$/m, 'METHOD:REQUEST';
like $ics, qr/^UID:abc\@calendar\.example\.test\r?$/m, 'the event\'s UID';
like $ics, qr/^SEQUENCE:3\r?$/m, 'the sequence given';
like $ics, qr/^ORGANIZER:mailto:owner\@example\.org\r?$/m, 'the organizer';
like $ics, qr/^ATTENDEE;[^\r\n]*CN=Ann[^\r\n]*:mailto:ann\@example\.com\r?$/m, 'an attendee with a name';
like $ics, qr/^ATTENDEE;[^\r\n]*PARTSTAT=ACCEPTED[^\r\n]*:mailto:ann\@example\.com\r?$/m, '... and her answer';
like $ics, qr/^ATTENDEE;[^\r\n]*PARTSTAT=NEEDS-ACTION[^\r\n]*RSVP=TRUE[^\r\n]*:mailto:bob\@example\.com\r?$/m, 'one still asked, RSVP wanted';
like $ics, qr/^DTSTART;TZID=America\/Chicago:20261120T123000\r?$/m, 'the wall clock in the event zone';
like $ics, qr/^URL:https:\/\/calendar\.example\.test\/i\/b{64}\r?$/m, 'the RSVP page as the URL';
unlike $ics, qr/^STATUS:/m, 'no STATUS on a live event';
my $cancel = flat(event_ics(%common, method => 'CANCEL', sequence => 4));
like $cancel, qr/^METHOD:CANCEL\r?$/m, 'a CANCEL';
like $cancel, qr/^STATUS:CANCELLED\r?$/m, '... with STATUS:CANCELLED';
like $cancel, qr/^SEQUENCE:4\r?$/m, '... and the bumped sequence';
my $pub = flat(event_ics(%common, method => 'PUBLISH'));
like $pub, qr/^METHOD:PUBLISH\r?$/m, 'a plain copy for a calendar program';
like $pub, qr/^SEQUENCE:0\r?$/m, '... carries the event\'s own sequence';

done_testing;
