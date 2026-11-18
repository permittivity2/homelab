use Mojo::Base -strict, -signatures;
use Test::More;
use DateTime;
use Mojo::Promise;
use Mojo::UserAgent;
use Mojolicious;
use lib 'lib';
use Homelab::Calendar::Holidays qw(holidays_for_years);

# The holidays calendar against a real PostgreSQL (post-cutover #92): made
# once, filled from the rules, filled again without touching a row, the
# window moving with the years, a tampered row put right, the switch as a
# read share, the watchdog's record, and the runner's check with Nager.Date
# stood in for by a local server. Needs TEST_PG_URL with migration 010.
plan skip_all => 'TEST_PG_URL not set (a PostgreSQL with the calendar schema)' unless $ENV{TEST_PG_URL};
require Mojo::Pg;
require Homelab::Calendar::Model;
require Homelab::Calendar::Runner;

my $pg = Mojo::Pg->new($ENV{TEST_PG_URL});
my $m  = Homelab::Calendar::Model->new(pg => $pg, uid_domain => 'calendar.example.test', default_zone => 'America/Chicago');
my $db = $pg->db;
my $tag = 'holtest-' . time . "-$$";
my $me  = "$tag-me\@example.test";
sub cleanup {
    $db->query('DELETE FROM calendar.shares WHERE lower(shared_with_email) = ?', lc $me);
    $db->query('DELETE FROM calendar.calendar_visibility WHERE user_email = ?', lc $me);
    $db->query('DELETE FROM calendar.holiday_checks WHERE year >= 2900');
}
END { cleanup() if $db }
sub chi ($y, $mo, $d) { return DateTime->new(year => $y, month => $mo, day => $d, time_zone => 'America/Chicago') }
sub live ($cal_id) { return $db->query('SELECT count(*) FROM calendar.events WHERE calendar_id = ? AND deleted_at IS NULL', $cal_id)->array->[0] }
sub seq  ($cal_id) { return $db->query('SELECT COALESCE(max(change_seq), 0) FROM calendar.events WHERE calendar_id = ?', $cal_id)->array->[0] }

# --- before any fill (a fresh install's first seconds) ---------------------------
$db->query(q{DELETE FROM calendar.holiday_runs WHERE kind = 'fill'});
is $m->metrics->{holidays_through_year}, 0, 'the through-year metric is 0 before the first fill (CI found a crash here)';
is $m->holidays_state($me)->{through_year}, undef, '... and the state has no year yet';

# --- the calendar --------------------------------------------------------------
my $cal = $m->ensure_holidays_calendar;
ok $cal && $cal->{kind} eq 'holidays', 'the holidays calendar exists';
is $cal->{owner_email}, $Homelab::Calendar::Model::HOLIDAYS_OWNER, '... owned by the system address';
is $cal->{name}, 'US Holidays', '... named';
is $m->ensure_holidays_calendar->{id}, $cal->{id}, '... once';
is $m->holidays_calendar->{id}, $cal->{id}, 'and found again';

# --- the fill -----------------------------------------------------------------
my $r = $m->fill_holidays(now => chi(2026, 11, 17), years_ahead => 2, force => 1);
ok $r->{ran}, 'a forced fill runs';
is "$r->{from}-$r->{through}", '2025-2028', '... for the year before through two ahead';
my $want = scalar @{ holidays_for_years(2025, 2028) };
is live($cal->{id}), $want, "... $want rows live (every holiday of four years; whatever another window left is retired)";
ok defined $r->{removed}, '... and says how many it retired';
my $tg = $db->query('SELECT * FROM calendar.events WHERE uid = ?', 'us-thanksgiving-2026@holidays.homelab')->hash;
ok $tg, 'Thanksgiving 2026 is a row';
is $tg->{title}, 'Thanksgiving Day', '... titled';
ok $tg->{all_day}, '... all day';
is "$tg->{start_date} $tg->{end_date}", '2026-11-26 2026-11-27', '... on its day, end exclusive';
is $tg->{description}, 'Federal holiday', '... described';
is $tg->{created_by_email}, $Homelab::Calendar::Model::HOLIDAYS_OWNER, '... made by the system address';
is Homelab::Calendar::Model::_dt($tg->{starts_at}, 'America/Chicago')->strftime('%Y-%m-%d %H:%M'), '2026-11-26 00:00', '... starting at midnight in the calendar\'s zone';
my $before = seq($cal->{id});
my $again = $m->fill_holidays(now => chi(2026, 11, 17), years_ahead => 2);
is $again->{ran}, 0, 'the same window again does nothing';
is $again->{reason}, 'unchanged', '... because nothing changed';
my $forced = $m->fill_holidays(now => chi(2026, 11, 17), years_ahead => 2, force => 1);
ok $forced->{ran}, 'forced, it runs';
is $forced->{written}, 0, '... but touches no row';
is seq($cal->{id}), $before, '... so no change_seq moved (a phone\'s sync sees nothing)';

# a tampered row (a title changed, a holiday put in the trash) is put right, and only it
$db->query('UPDATE calendar.events SET title = ? WHERE uid = ?', 'Turkey Day', 'us-thanksgiving-2026@holidays.homelab');
$db->query('UPDATE calendar.events SET deleted_at = NOW() WHERE uid = ?', 'us-labor-day-2027@holidays.homelab');
my $fix = $m->fill_holidays(now => chi(2026, 11, 17), years_ahead => 2, force => 1);
is $fix->{written}, 2, 'a changed title and a trashed row are the two rows written';
is $db->query('SELECT title FROM calendar.events WHERE uid = ?', 'us-thanksgiving-2026@holidays.homelab')->array->[0], 'Thanksgiving Day', '... the title is back';
ok !defined $db->query('SELECT deleted_at FROM calendar.events WHERE uid = ?', 'us-labor-day-2027@holidays.homelab')->array->[0], '... the trashed row is back';
is live($cal->{id}), $want, '... and the count is as before';

# the window moves with the years: the oldest year is retired, a new one added
my $moved = $m->fill_holidays(now => chi(2027, 1, 1), years_ahead => 2);
ok $moved->{ran}, 'a new year runs the fill';
is "$moved->{from}-$moved->{through}", '2026-2029', '... one year on';
is $moved->{removed}, scalar(@{ holidays_for_years(2025, 2025) }), '... 2025 retired';
is $moved->{written}, scalar(@{ holidays_for_years(2029, 2029) }), '... 2029 written';
is live($cal->{id}), scalar(@{ holidays_for_years(2026, 2029) }), '... four years live again';
my $old = $db->query('SELECT deleted_at, change_seq FROM calendar.events WHERE uid = ?', 'us-thanksgiving-2025@holidays.homelab')->hash;
ok $old->{deleted_at}, 'a retired row is in the trash (a sync token sees it go)';
ok $old->{change_seq} > $before, '... with a new change_seq';
my $run = $db->query(q{SELECT * FROM calendar.holiday_runs WHERE kind = 'fill'})->hash;
is "$run->{from_year}-$run->{through_year}", '2026-2029', 'the run is on record';
like $run->{digest}, qr/\A[0-9a-f]{64}\z/, '... with its digest';

# --- the switch ---------------------------------------------------------------
my $s = $m->holidays_state($me);
is $s->{on}, 0, 'off to begin with';
is $s->{name}, 'US Holidays', '... the state names the calendar';
is $s->{events}, live($cal->{id}), '... and counts its days';
is $s->{through_year}, 2029, '... through the last year filled';
ok !grep({ $_->{id} == $cal->{id} } @{ $m->calendars_for($me)->{shared} }), 'not among my calendars while off';
$s = $m->set_holidays($me, 1);
is $s->{on}, 1, 'switched on';
my ($mine) = grep { $_->{id} == $cal->{id} } @{ $m->calendars_for($me)->{shared} };
ok $mine, 'now among the calendars shared to me';
is $mine->{permission}, 'read', '... read-only';
is $mine->{kind}, 'holidays', '... and marked as the built-in one';
is $mine->{visible}, 1, '... ticked in the sidebar';
is $m->permission_for_calendar($me, $cal), 'read', 'the access rule agrees';
$m->set_holidays($me, 1);
is scalar(grep { $_->{calendar_id} == $cal->{id} } @{ $m->viewer_calendar_shares($me) }), 1, 'switching on twice makes one share';
$m->set_visibility($me, $cal->{id}, 0);
$m->set_holidays($me, 0);
is $m->holidays_state($me)->{on}, 0, 'switched off';
ok !grep({ $_->{id} == $cal->{id} } @{ $m->calendars_for($me)->{shared} }), '... and gone from my calendars';
$m->set_holidays($me, 1);
($mine) = grep { $_->{id} == $cal->{id} } @{ $m->calendars_for($me)->{shared} };
is $mine->{visible}, 1, 'on again brings the sidebar tick back';
$m->set_holidays($me, 0);

# --- the watchdog's record -------------------------------------------------------
ok $m->claim_holiday_check(2900), 'a year is claimed';
ok !$m->claim_holiday_check(2900), '... once';
$m->holiday_check_failed(2900, "HTTP 503 from somewhere\n");
ok !$m->claim_holiday_check(2900), 'a failed check is not retried within the day';
$db->query(q{UPDATE calendar.holiday_checks SET started_at = NOW() - INTERVAL '2 days' WHERE year = 2900});
ok $m->claim_holiday_check(2900), '... but is a day later';
is $m->holiday_check(2900)->{note}, 'retry', '... and says so';
$m->holiday_check_done(2900, ['Constitution Day'], '18 rows from example.test');
my $chk = $m->holiday_check(2900);
ok $chk->{ok}, 'a finished check is ok';
is_deeply $chk->{unknown}, ['Constitution Day'], '... with the names the rules do not know';
is $chk->{note}, '18 rows from example.test', '... and its note';
$db->query(q{UPDATE calendar.holiday_checks SET started_at = NOW() - INTERVAL '2 days' WHERE year = 2900});
ok !$m->claim_holiday_check(2900), 'a year checked fine is never asked about again';
is $m->latest_holiday_check->{year}, 2900, 'the latest check is the one Settings shows';
is $m->metrics->{holidays_unknown}, 1, 'the metric counts the unknown name';
ok $m->metrics->{holidays_events} >= live($cal->{id}), 'the metric counts the rows';
my $refilled = $m->fill_holidays(now => chi(2027, 1, 1), years_ahead => 3);
ok $refilled->{ran}, 'a fill that runs (new rules, a new year)';
ok !$m->holiday_check(2900), '... drops the checks that found unknown names, so they are asked again';
$db->query('DELETE FROM calendar.holiday_checks WHERE year >= 2900');

# --- the runner's check, with Nager.Date stood in for ---------------------------------
my $app = Mojolicious->new;
$app->log->level('fatal');
$app->routes->get('/nager/:year' => sub ($c) {
    my $y = $c->param('year');
    $c->render(json => [
        { date => "$y-11-26", localName => 'Thanksgiving Day', name => 'Thanksgiving Day', global => \1, counties => undef, types => ['Public', 'Bank'] },
        { date => "$y-03-02", localName => 'Texas Independence Day', name => 'Texas Independence Day', global => \0, counties => ['US-TX'], types => ['Public'] },
        ($y == 2902 ? { date => "$y-09-17", localName => 'Constitution Day', name => 'Constitution Day', global => \1, counties => undef, types => ['Public'] } : ()),
    ]);
});
$app->routes->get('/down/:year' => sub ($c) { $c->render(text => 'nope', status => 503) });
my $ua = Mojo::UserAgent->new;
$ua->server->app($app);
my $base = $ua->server->nb_url;
my $runner = Homelab::Calendar::Runner->new(model => $m, ua => $ua, default_zone => 'America/Chicago', holidays => { check_url => $base . 'nager/%d' });
my $p = $runner->check_holidays(2901);
is scalar(@$p), 2, 'this year and the next are asked about';
Mojo::Promise->all(@$p)->wait;
$chk = $m->holiday_check(2901);
ok $chk->{ok}, '2901 checked';
is_deeply $chk->{unknown}, [], '... nothing unknown';
like $chk->{note}, qr/\A2 rows from 127\.0\.0\.1\z/, '... the note says what came back and from where';
is_deeply $m->holiday_check(2902)->{unknown}, ['Constitution Day'], '2902: the made-up national holiday is named; the state day is not';
is scalar(@{ $runner->check_holidays(2901) }), 0, 'asked again: nothing to do';
$runner->holidays({ check_url => $base . 'down/%d' });
$p = $runner->check_holidays(2903);
Mojo::Promise->all(@$p)->wait;
$chk = $m->holiday_check(2903);
ok defined $chk->{ok} && !$chk->{ok}, 'a server that fails leaves a failed check';
like $chk->{note}, qr/HTTP 503/, '... saying why';
$runner->holidays({ check_url => '0' });
is scalar(@{ $runner->check_holidays(2905) }), 0, 'check_url 0 turns the watchdog off';
ok !$m->holiday_check(2905), '... and claims nothing';
$runner->holidays({ enabled => 0 });
$runner->run_holidays;
is $runner->_holidays_next, 0, 'holidays.enabled 0 keeps the runner from looking at all';
$runner->holidays({ check_url => '0', years_ahead => 1 });
$runner->run_holidays;
ok $runner->_holidays_next > time, 'run_holidays looks, then waits its hour';

done_testing;
