use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;

# The recurrence engine, which the browser, the editor and the ICS feed all
# rely on. Pure functions: no database, no network.

use lib 'lib';
BEGIN {
    eval { require DateTime::Format::ICal; require DateTime::Event::ICal; 1 }
        or plan skip_all => "DateTime::Format::ICal / DateTime::Event::ICal not installed: $@";
    use_ok 'Homelab::Calendar::Recurrence', qw(
        build_rrule parse_rrule validate_zone local_dt floating_dt wall_string parse_wall occurrences recurrence_bound
    );
}

my $CHI = 'America/Chicago';
sub chi (@a) { DateTime->new(year => $a[0], month => $a[1], day => $a[2], hour => $a[3] // 0, minute => $a[4] // 0, time_zone => $CHI) }
sub window ($s, $e) { (window_start => $s, window_end => $e) }
sub ymdhms ($dt) { $dt->strftime('%Y-%m-%d %H:%M') }

# --- zones ---
ok validate_zone('America/Chicago'), 'a real zone';
ok validate_zone('UTC'), 'UTC';
ok !validate_zone('Mars/Olympus'), 'not a zone';
ok !validate_zone('floating'), 'floating is not a zone a person can choose';
ok !validate_zone(''), 'empty';
ok !validate_zone(undef), 'undef';

# --- building rules from the form ---
my $mon = chi(2026, 10, 26, 9);    # a Monday, the week before DST ends (2026-11-01)
is build_rrule({ freq => 'daily' }, $mon), 'FREQ=DAILY', 'daily';
is build_rrule({ freq => 'daily', interval => 2 }, $mon), 'FREQ=DAILY;INTERVAL=2', 'every other day';
is build_rrule({ freq => 'weekly' }, $mon), 'FREQ=WEEKLY;BYDAY=MO', 'weekly with no days ticked: the start day';
is build_rrule({ freq => 'weekly', byday => ['we', 'MO', 'MO'] }, $mon), 'FREQ=WEEKLY;BYDAY=MO,WE', 'weekdays sorted, deduplicated, upcased';
is build_rrule({ freq => 'monthly' }, $mon), 'FREQ=MONTHLY;BYMONTHDAY=26', 'monthly by day of month';
is build_rrule({ freq => 'monthly', monthly_by => 'weekday' }, $mon), 'FREQ=MONTHLY;BYDAY=4MO', 'monthly by weekday: the 4th Monday';
is build_rrule({ freq => 'monthly', monthly_by => 'weekday' }, chi(2026, 10, 30, 9)), 'FREQ=MONTHLY;BYDAY=-1FR', 'the 5th Friday is "the last Friday"';
is build_rrule({ freq => 'monthly', monthly_by => 'weekday' }, chi(2026, 11, 24, 9)), 'FREQ=MONTHLY;BYDAY=4TU', 'a 4th Tuesday stays the 4th even when the month has no 5th';
is build_rrule({ freq => 'monthly', monthly_by => 'weekday' }, chi(2026, 11, 10, 9)), 'FREQ=MONTHLY;BYDAY=2TU', 'the 2nd Tuesday stays the 2nd';
is build_rrule({ freq => 'yearly' }, $mon), 'FREQ=YEARLY', 'yearly';
is build_rrule({ freq => 'daily', count => 10 }, $mon), 'FREQ=DAILY;COUNT=10', 'count';
is build_rrule({ freq => 'weekly', until => '2026-12-31' }, $mon), 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T055959Z',
    'until is the last second of that day in the event zone, as UTC (Chicago is -6 in winter)';

for my $bad (
    [{ freq => 'hourly' },                            qr/how often/,         'unknown frequency'],
    [{ freq => 'daily', interval => 0 },              qr/interval/,          'interval 0'],
    [{ freq => 'daily', interval => 'x' },            qr/interval/,          'interval not a number'],
    [{ freq => 'weekly', byday => ['XX'] },           qr/Unknown weekday/,   'bad weekday'],
    [{ freq => 'monthly', monthly_by => 'phase' },    qr/monthly pattern/,   'bad monthly pattern'],
    [{ freq => 'daily', count => 0 },                 qr/occurrences/,       'count 0'],
    [{ freq => 'daily', count => 3, until => '2027-01-01' }, qr/not both/,   'count and until together'],
    [{ freq => 'daily', until => '31/12/2026' },      qr/look like/,         'until in the wrong shape'],
    [{ freq => 'daily', until => '2026-02-30' },      qr/does not exist/,    'until on a day that does not exist'],
    [{ freq => 'daily', until => '2026-10-01' },      qr/before the event/,  'until before the start'],
) {
    my ($form, $re, $name) = @$bad;
    my $r = eval { build_rrule($form, $mon) };
    ok !defined $r, "refused: $name";
    like $@, $re, "... saying why";
}

# --- parsing them back (the inverse) ---
is_deeply parse_rrule('FREQ=WEEKLY;BYDAY=MO,WE', $CHI), { freq => 'weekly', interval => 1, byday => ['MO', 'WE'] }, 'weekly parses back';
is_deeply parse_rrule('FREQ=MONTHLY;BYDAY=2TU;INTERVAL=3', $CHI), { freq => 'monthly', interval => 3, monthly_by => 'weekday' }, 'monthly weekday';
is_deeply parse_rrule('FREQ=MONTHLY;BYMONTHDAY=26', $CHI), { freq => 'monthly', interval => 1, monthly_by => 'monthday' }, 'monthly monthday';
is_deeply parse_rrule('FREQ=DAILY;COUNT=10', $CHI), { freq => 'daily', interval => 1, count => 10 }, 'count';
is_deeply parse_rrule('FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T055959Z', $CHI), { freq => 'weekly', interval => 1, byday => ['MO'], until => '2026-12-31' },
    'until comes back as the day in the event zone (round trip)';
is parse_rrule('FREQ=WEEKLY;BYSETPOS=1;BYDAY=MO', $CHI), undef, 'a rule the editor cannot show: undef';
is parse_rrule('FREQ=SECONDLY', $CHI), undef, 'an unsupported frequency: undef';
is parse_rrule('garbage', $CHI), undef, 'garbage: undef';
is parse_rrule('', $CHI), undef, 'empty: undef';
is parse_rrule(undef, $CHI), undef, 'undef: undef';

for my $rule ('FREQ=DAILY;INTERVAL=2', 'FREQ=WEEKLY;BYDAY=MO,WE,FR', 'FREQ=MONTHLY;BYDAY=-1FR', 'FREQ=YEARLY;COUNT=5', 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T055959Z') {
    my $form = parse_rrule($rule, $CHI);
    is build_rrule($form, $rule =~ /-1FR/ ? chi(2026, 10, 30, 9) : $mon), $rule, "round trip: $rule";
}

# --- wall clocks ---
is wall_string(chi(2026, 11, 14, 9, 5)), '2026-11-14T09:05:00', 'wall string has no offset';
is wall_string(chi(2026, 11, 14, 9, 5), 1), '2026-11-14', 'all-day wall string is the date';
is ymdhms(parse_wall('2026-11-14T09:05:00', $CHI)), '2026-11-14 09:05', 'parse a wall clock';
is parse_wall('2026-11-14T09:05:00', $CHI)->time_zone->name, $CHI, '... into the zone';
is ymdhms(parse_wall('2026-11-14T09:05:00.000Z', $CHI)), '2026-11-14 09:05', 'a browser "Z" string: the offset is ignored, the wall clock kept';
is ymdhms(parse_wall('2026-11-14T09:05:00-06:00', $CHI)), '2026-11-14 09:05', '... same for an explicit offset';
is ymdhms(parse_wall('2026-11-14', $CHI)), '2026-11-14 00:00', 'a date alone is midnight';
is parse_wall('14/11/2026', $CHI), undef, 'the wrong shape: undef';
is parse_wall('2026-13-01', $CHI), undef, 'an impossible date: undef';
is parse_wall(undef, $CHI), undef, 'undef: undef';
# 2026-03-08 02:30 does not exist in Chicago (spring forward at 02:00).
my $gap = parse_wall('2026-03-08T02:30:00', $CHI);
is ymdhms($gap), '2026-03-08 03:00', 'a time in the DST gap moves forward to the first minute that exists';
is $gap->offset, -5 * 3600, '... on daylight time';
is floating_dt(chi(2026, 11, 14, 9))->time_zone->name, 'floating', 'floating_dt';

# --- expansion: weekly across the DST change keeps the wall clock ---
my $occ = occurrences(dtstart => $mon, rrule => 'FREQ=WEEKLY;BYDAY=MO,WE', window(chi(2026, 10, 26), chi(2026, 11, 12)));
is_deeply [ map { ymdhms($_) } @$occ ],
    ['2026-10-26 09:00', '2026-10-28 09:00', '2026-11-02 09:00', '2026-11-04 09:00', '2026-11-09 09:00', '2026-11-11 09:00'],
    'Monday and Wednesday at 09:00 across the fall-back night, all still 09:00';
is $occ->[1]->offset, -5 * 3600, 'before the change: CDT';
is $occ->[2]->offset, -6 * 3600, 'after the change: CST (the instant moved, the clock did not)';
is $occ->[0]->time_zone->name, $CHI, 'occurrences carry the event zone';

# --- the window is half-open and the first occurrence is always DTSTART ---
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=DAILY', window(chi(2026, 10, 27), chi(2026, 10, 29)));
is_deeply [ map { $_->ymd } @$occ ], ['2026-10-27', '2026-10-28'], 'a window [start, end) excludes its end';
$occ = occurrences(dtstart => chi(2026, 10, 27, 9), rrule => 'FREQ=WEEKLY;BYDAY=MO', window(chi(2026, 10, 26), chi(2026, 11, 10)));
is_deeply [ map { $_->ymd } @$occ ], ['2026-10-27', '2026-11-02', '2026-11-09'], 'DTSTART (a Tuesday) is an occurrence even though the rule says Mondays';
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=WEEKLY;BYDAY=MO', window(chi(2026, 1, 1), chi(2026, 10, 1)));
is_deeply $occ, [], 'nothing before the start';

# --- a window that is not in the event zone ---
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=DAILY',
    window(DateTime->new(year => 2026, month => 11, day => 3, hour => 14, time_zone => 'UTC'),
           DateTime->new(year => 2026, month => 11, day => 4, hour => 16, time_zone => 'UTC')));
is_deeply [ map { ymdhms($_) } @$occ ], ['2026-11-03 09:00', '2026-11-04 09:00'],
    'a UTC window is converted to the event zone (09:00 CST = 15:00Z, so both days fall inside)';

# --- counts, until, monthly patterns ---
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=DAILY;COUNT=3', window(chi(2026, 1, 1), chi(2027, 1, 1)));
is scalar(@$occ), 3, 'COUNT stops the rule';
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20261110T055959Z', window(chi(2026, 1, 1), chi(2027, 1, 1)));
is_deeply [ map { $_->ymd } @$occ ], ['2026-10-26', '2026-11-02', '2026-11-09'], 'UNTIL (the end of 2026-11-09 Chicago) includes that day';
$occ = occurrences(dtstart => chi(2026, 11, 10, 14), rrule => 'FREQ=MONTHLY;BYDAY=2TU', window(chi(2026, 11, 1), chi(2027, 3, 1)));
is_deeply [ map { $_->ymd } @$occ ], ['2026-11-10', '2026-12-08', '2027-01-12', '2027-02-09'], 'the second Tuesday of every month';
$occ = occurrences(dtstart => chi(2026, 1, 31, 10), rrule => 'FREQ=MONTHLY;BYMONTHDAY=31', window(chi(2026, 1, 1), chi(2026, 6, 1)));
is_deeply [ map { $_->ymd } @$occ ], ['2026-01-31', '2026-03-31', '2026-05-31'], 'the 31st skips months without one';
$occ = occurrences(dtstart => chi(2024, 2, 29, 10), rrule => 'FREQ=YEARLY', window(chi(2024, 1, 1), chi(2029, 1, 1)));
is_deeply [ map { $_->ymd } @$occ ], ['2024-02-29', '2028-02-29'], 'a yearly event on Feb 29 happens in leap years only';

# --- all-day events: dates, no clock ---
my $day = DateTime->new(year => 2026, month => 11, day => 14, time_zone => $CHI);
$occ = occurrences(dtstart => $day, rrule => 'FREQ=WEEKLY;BYDAY=SA', window(chi(2026, 11, 1), chi(2026, 12, 1)));
is_deeply [ map { wall_string($_, 1) } @$occ ], ['2026-11-14', '2026-11-21', '2026-11-28'], 'an all-day weekly event, as dates';

# --- no rule: the start itself, if in the window ---
$occ = occurrences(dtstart => $mon, rrule => undef, window(chi(2026, 10, 26), chi(2026, 10, 27)));
is_deeply [ map { ymdhms($_) } @$occ ], ['2026-10-26 09:00'], 'a single event inside the window';
$occ = occurrences(dtstart => $mon, rrule => '', window(chi(2026, 10, 27), chi(2026, 10, 28)));
is_deeply $occ, [], 'a single event outside the window';

# --- an old open-ended daily rule viewed years later is still quick ---
my $t0 = time;
$occ = occurrences(dtstart => chi(2000, 1, 1, 8), rrule => 'FREQ=DAILY', window(chi(2026, 11, 1), chi(2026, 11, 8)));
is scalar(@$occ), 7, 'a daily event since 2000: seven in a week of 2026';
cmp_ok time - $t0, '<', 5, '... without expanding 26 years first';

# --- the occurrence limit ---
{
    local $Homelab::Calendar::Recurrence::MAX_OCCURRENCES = 5;
    $occ = occurrences(dtstart => $mon, rrule => 'FREQ=DAILY', window(chi(2026, 10, 26), chi(2027, 10, 26)));
    is scalar(@$occ), 5, 'the occurrence limit caps a huge expansion';
}
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=DAILY', window(chi(2026, 10, 26), chi(2026, 10, 30)), limit => 2);
is scalar(@$occ), 2, '... and a per-call limit does too';

# --- a rule the library rejects is simply empty ---
$occ = occurrences(dtstart => $mon, rrule => 'FREQ=BOGUS', window(chi(2026, 1, 1), chi(2027, 1, 1)));
is_deeply $occ, [], 'a broken rule expands to nothing rather than dying';

# --- the last occurrence, for the window query's index ---
is recurrence_bound($mon, 'FREQ=DAILY'), undef, 'open-ended: no bound';
is ymdhms(recurrence_bound($mon, 'FREQ=DAILY;COUNT=3')), '2026-10-28 09:00', 'COUNT: the last occurrence';
is ymdhms(recurrence_bound($mon, 'FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T055959Z')), '2026-12-31 23:59', 'UNTIL: the end of that day';
is recurrence_bound($mon, 'FREQ=BOGUS'), undef, 'a broken rule: no bound';

# --- the gap night itself: a 02:30 daily event on 2026-03-08 ---
$occ = occurrences(dtstart => chi(2026, 3, 6, 2, 30), rrule => 'FREQ=DAILY', window(chi(2026, 3, 6), chi(2026, 3, 10)));
is_deeply [ map { ymdhms($_) } @$occ ], ['2026-03-06 02:30', '2026-03-07 02:30', '2026-03-08 03:00', '2026-03-09 02:30'],
    'the occurrence on the spring-forward night moves to 03:00 instead of vanishing';

done_testing;
