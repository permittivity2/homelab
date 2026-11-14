use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Homelab::Calendar::ICSImport qw(parse_ics);

# iCalendar in (#82): what one file's VEVENTs become, and what is left out.

my $ics = join "\r\n",
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//test//EN',
    'BEGIN:VEVENT', 'UID:dentist@example.com', 'DTSTART;TZID=America/Chicago:20261120T143000', 'DTEND;TZID=America/Chicago:20261120T153000',
    'SUMMARY:Dentist\, soon', 'LOCATION:Delta Dental', 'DESCRIPTION:Line one\nLine two', 'RRULE:FREQ=WEEKLY;COUNT=4',
    'EXDATE;TZID=America/Chicago:20261127T143000', 'BEGIN:VALARM', 'TRIGGER:-PT15M', 'ACTION:DISPLAY', 'END:VALARM', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:fair', 'DTSTART;VALUE=DATE:20261201', 'DTEND;VALUE=DATE:20261203', 'SUMMARY:Fair', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:utc', 'DTSTART:20261120T200000Z', 'DURATION:PT1H30M', 'SUMMARY:Call', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:floating', 'DTSTART:20261121T090000', 'SUMMARY:', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:dentist@example.com', 'RECURRENCE-ID;TZID=America/Chicago:20261204T143000',
    'DTSTART;TZID=America/Chicago:20261204T160000', 'SUMMARY:Dentist (moved)', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:nostart', 'SUMMARY:No start', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:badrule', 'DTSTART:20261121T090000', 'RRULE:FREQ=SECONDLY', 'SUMMARY:Odd', 'END:VEVENT',
    'END:VCALENDAR', '';

my $r = parse_ics($ics, zone => 'America/Chicago');
ok(!$r->{error}, 'the file parses') or diag $r->{error};
my %by = map { ($_->{uid} // 'none') => $_ } @{ $r->{events} };
is(scalar @{ $r->{events} }, 4, 'four events come in');
is($by{'dentist@example.com'}{title}, 'Dentist, soon', 'an escaped comma is unescaped');
is($by{'dentist@example.com'}{start}, '2026-11-20T14:30:00', 'a TZID wall clock is kept');
is($by{'dentist@example.com'}{end}, '2026-11-20T15:30:00', '... and its end');
is($by{'dentist@example.com'}{timezone}, 'America/Chicago', 'the TZID is the event zone');
is($by{'dentist@example.com'}{repeat}, 'FREQ=WEEKLY;COUNT=4', 'the RRULE is kept as written');
is_deeply($by{'dentist@example.com'}{exdates}, ['2026-11-27T14:30:00'], 'an EXDATE as a wall clock');
is($by{'dentist@example.com'}{reminder_minutes}, 15, 'the VALARM trigger is the reminder');
is($by{'dentist@example.com'}{description}, "Line one\nLine two", 'the description keeps its lines');
is($by{'dentist@example.com'}{location}, 'Delta Dental', 'the location');
ok($by{fair}{all_day}, 'VALUE=DATE is all-day');
is($by{fair}{start}, '2026-12-01', 'all-day start');
is($by{fair}{end}, '2026-12-03', 'all-day end stays exclusive');
is($by{utc}{start}, '2026-11-20T14:00:00', 'a UTC instant lands in the account zone');
is($by{utc}{end}, '2026-11-20T15:30:00', 'DURATION gives the end');
is($by{utc}{timezone}, 'America/Chicago', '... in the account zone');
is($by{floating}{start}, '2026-11-21T09:00:00', 'a floating time is read in the account zone');
is($by{floating}{title}, 'Untitled event', 'an empty SUMMARY gets a title');
is($by{floating}{end}, undef, 'no end: the model adds its default');
is($by{floating}{reminder_minutes}, undef, 'no alarm, no reminder');
my %skip = map { ($_->{uid} // 'none') => $_->{reason} } @{ $r->{skipped} };
like($skip{'dentist@example.com'}, qr/changed occurrence/, 'a RECURRENCE-ID component is skipped, with the reason');
like($skip{nostart}, qr/no start/, 'no DTSTART: skipped');
like($skip{badrule}, qr/repeat rule/, 'a rule the calendar cannot show: skipped');
is(scalar @{ $r->{skipped} }, 3, 'three skipped in all');

my $bad = parse_ics('hello there', zone => 'UTC');
like($bad->{error}, qr/not an iCalendar/, 'not a calendar at all');
is_deeply($bad->{events}, [], '... and no events');
my $big = parse_ics('BEGIN:VCALENDAR' . ('x' x 2_000_001), zone => 'UTC');
like($big->{error}, qr/too large/, 'a huge file is refused before parsing');
my $none = parse_ics("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//t//EN\r\nEND:VCALENDAR\r\n", zone => 'UTC');
ok(!$none->{error} && !@{ $none->{events} }, 'an empty calendar is fine: nothing in, no error');
my $junk = parse_ics("BEGIN:VCALENDAR\r\nthis is not a property line\r\n", zone => 'UTC');
ok(ref $junk eq 'HASH' && ref $junk->{events} eq 'ARRAY', 'a broken file still answers in shape') or diag explain $junk;

done_testing;
