use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;

# The two iCalendar shapes: an expanded UTC feed and an RRULE export. Each is
# parsed back with Data::ICal, so the test checks what a consumer would see.

use lib 'lib';
BEGIN {
    eval { require Data::ICal; 1 } or plan skip_all => "Data::ICal not installed: $@";
    use_ok 'Homelab::Calendar::ICS', qw(instances_ics masters_ics ics_datetime ics_date);
}

my $CHI = 'America/Chicago';
sub chi (@a) { DateTime->new(year => $a[0], month => $a[1], day => $a[2], hour => $a[3] // 0, minute => $a[4] // 0, time_zone => $CHI) }
my $now = DateTime->new(year => 2026, month => 11, day => 14, hour => 12, time_zone => 'UTC');

sub parse ($ics) {
    my $c = Data::ICal->new(data => $ics);
    die "did not parse: " . $c->error_message unless ref $c;
    return $c;
}
sub prop ($entry, $name) { my $p = $entry->property($name); return $p ? $p->[0] : undef }
sub val  ($entry, $name) { my $p = prop($entry, $name); return $p ? $p->value : undef }

is ics_datetime(chi(2026, 11, 2, 9)), '20261102T150000Z', 'a Chicago instant as UTC (CST, -6)';
is ics_datetime(chi(2026, 10, 26, 9)), '20261026T140000Z', '... and in CDT (-5)';
is ics_date(chi(2026, 11, 2)), '20261102', 'a date';

# --- the feed: expanded instances in UTC ---
my $ics = instances_ics(
    name => 'Team', zone => $CHI, now => $now,
    instances => [
        { uid => 'a1@calendar.test', title => 'Standup; daily, short', description => "Line one\nLine two", location => 'Room 4',
          all_day => 0, start => chi(2026, 10, 26, 9), end => chi(2026, 10, 26, 9, 30), recurrence_id => chi(2026, 10, 26, 9),
          created => chi(2026, 10, 1, 8), updated => chi(2026, 10, 2, 8) },
        { uid => 'a1@calendar.test', title => 'Standup; daily, short', all_day => 0,
          start => chi(2026, 11, 2, 9), end => chi(2026, 11, 2, 9, 30), recurrence_id => chi(2026, 11, 2, 9) },
        { uid => 'b2@calendar.test', title => 'Conference', all_day => 1, start => chi(2026, 11, 20), end => chi(2026, 11, 22) },
    ],
);
like $ics, qr/^BEGIN:VCALENDAR\r?\n/, 'starts a VCALENDAR';
like $ics, qr/^PRODID:-\/\/Silver Linings LLC\/\/homelab-calendar\/\/EN\r?$/m, 'our PRODID, once';
is scalar(() = $ics =~ /^PRODID:/mg), 1, '... and only once (Data::ICal\'s own replaced)';
like $ics, qr/^X-WR-CALNAME:Team\r?$/m, 'the calendar name';
like $ics, qr/^X-WR-TIMEZONE:America\/Chicago\r?$/m, 'the calendar zone, as a hint';
like $ics, qr/^METHOD:PUBLISH\r?$/m, 'METHOD:PUBLISH for a feed';
unlike $ics, qr/TZID/, 'the feed has no TZID anywhere';
unlike $ics, qr/RRULE/, '... and no rule: every occurrence is spelled out';

my $cal = parse($ics);
my @ev = grep { $_->ical_entry_type eq 'VEVENT' } @{ $cal->entries };
is scalar(@ev), 3, 'three VEVENTs';
is val($ev[0], 'dtstart'), '20261026T140000Z', 'first occurrence in UTC (CDT)';
is val($ev[1], 'dtstart'), '20261102T150000Z', 'the occurrence after the DST change: 09:00 Chicago is now 15:00Z';
is val($ev[0], 'dtend'),   '20261026T143000Z', 'the end';
is val($ev[0], 'uid'), '20261026T140000Z-a1@calendar.test', 'a repeating event\'s occurrence gets a derived UID';
is val($ev[1], 'uid'), '20261102T150000Z-a1@calendar.test', '... different per occurrence';
is val($ev[0], 'summary'), 'Standup; daily, short', 'the title, unescaped on parse';
like $ics, qr/^SUMMARY:Standup\\; daily\\, short\r?$/m, '... escaped on the wire';
is val($ev[0], 'description'), "Line one\nLine two", 'a description with a newline round-trips';
is val($ev[0], 'location'), 'Room 4', 'the location';
is val($ev[0], 'dtstamp'), '20261114T120000Z', 'DTSTAMP is the generation time';
is val($ev[0], 'created'), '20261001T130000Z', 'CREATED';
is val($ev[0], 'last-modified'), '20261002T130000Z', 'LAST-MODIFIED';
is val($ev[2], 'uid'), 'b2@calendar.test', 'a single event keeps its own UID';
is val($ev[2], 'dtstart'), '20261120', 'an all-day event starts on a date';
is_deeply prop($ev[2], 'dtstart')->parameters, { VALUE => 'DATE' }, '... marked VALUE=DATE';
is val($ev[2], 'dtend'), '20261122', '... and ends on the exclusive next date';
ok !prop($ev[1], 'description'), 'no empty DESCRIPTION line when there is none';

# --- busy-only detail ---
my $busy = instances_ics(name => 'Team', zone => $CHI, now => $now, detail => 'busy',
    instances => [ { uid => 'a1@calendar.test', title => 'Secret plans', description => 'very', location => 'here',
                     all_day => 0, start => chi(2026, 10, 26, 9), end => chi(2026, 10, 26, 10) } ]);
unlike $busy, qr/Secret|very|here/, 'busy detail leaks no title, description or location';
like $busy, qr/^SUMMARY:Busy\r?$/m, '... every event is "Busy"';
like $busy, qr/^TRANSP:OPAQUE\r?$/m, '... and marked opaque (it blocks the time)';

# --- an empty feed is still a valid calendar ---
my $empty = parse(instances_ics(name => 'Nothing', now => $now, instances => []));
is scalar(grep { $_->ical_entry_type eq 'VEVENT' } @{ $empty->entries }), 0, 'an empty feed parses with no events';

# --- the export: masters with rules ---
$ics = masters_ics(
    name => 'Team', zone => $CHI, now => $now,
    events => [
        { uid => 'a1@calendar.test', title => 'Standup', all_day => 0, start => chi(2026, 10, 26, 9), end => chi(2026, 10, 26, 9, 30),
          rrule => 'FREQ=WEEKLY;BYDAY=MO,WE', exdates => [ chi(2026, 11, 4, 9) ],
          overrides => [ { recurrence_id => chi(2026, 11, 2, 9), start => chi(2026, 11, 2, 10), end => chi(2026, 11, 2, 10, 30), title => 'Standup (moved)' } ] },
        { uid => 'b2@calendar.test', title => 'Conference', all_day => 1, start => chi(2026, 11, 20), end => chi(2026, 11, 22),
          rrule => 'FREQ=YEARLY', exdates => [ chi(2027, 11, 20) ] },
        { uid => 'c3@calendar.test', title => 'Once', all_day => 0, start => chi(2026, 12, 1, 15), end => chi(2026, 12, 1, 16) },
    ],
);
$cal = parse($ics);
@ev = grep { $_->ical_entry_type eq 'VEVENT' } @{ $cal->entries };
is scalar(@ev), 4, 'three masters plus one override';
is val($ev[0], 'dtstart'), '20261026T090000', 'the master starts at its wall-clock time';
is_deeply prop($ev[0], 'dtstart')->parameters, { TZID => 'America/Chicago' }, '... with the zone as TZID';
is val($ev[0], 'rrule'), 'FREQ=WEEKLY;BYDAY=MO,WE', 'the rule is kept';
is val($ev[0], 'exdate'), '20261104T090000', 'a cancelled occurrence is an EXDATE in the zone';
is_deeply prop($ev[0], 'exdate')->parameters, { TZID => 'America/Chicago' }, '... with TZID';
is val($ev[1], 'uid'), 'a1@calendar.test', 'the override shares the master\'s UID';
is val($ev[1], 'recurrence-id'), '20261102T090000', '... and names the occurrence it replaces';
is val($ev[1], 'dtstart'), '20261102T100000', '... with its own start';
is val($ev[1], 'summary'), 'Standup (moved)', '... and its own title';
ok !prop($ev[1], 'rrule'), '... and no rule of its own';
is val($ev[2], 'rrule'), 'FREQ=YEARLY', 'an all-day yearly event';
is val($ev[2], 'exdate'), '20271120', '... its EXDATE is a date';
is_deeply prop($ev[2], 'exdate')->parameters, { VALUE => 'DATE' }, '... marked so';
ok !prop($ev[3], 'rrule'), 'a single event has no rule';
is scalar(() = $ics =~ /^PRODID:/mg), 1, 'one PRODID in the export too';

done_testing;
