use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';

# The holiday rules (post-cutover #92): known dates for known years, the
# observed days off, Easter, the IRS's Tax Day rule, the shape of a row and
# the Nager.Date watchdog's comparison. Pure: no database, no network.
use_ok 'Homelab::Calendar::Holidays';
Homelab::Calendar::Holidays->import(qw(holidays_for_year holidays_for_years easter_sunday unknown_national_names rules_digest));

sub on ($rows, $id) { my ($r) = grep { $_->{id} eq $id } @$rows; return $r ? $r->{start} : undef }

# --- Easter ---------------------------------------------------------------
my %easter = (2024 => '2024-03-31', 2025 => '2025-04-20', 2026 => '2026-04-05', 2027 => '2027-03-28',
              2028 => '2028-04-16', 2029 => '2029-04-01', 2030 => '2030-04-21', 2000 => '2000-04-23', 2038 => '2038-04-25');
is easter_sunday($_)->ymd, $easter{$_}, "Easter $_" for sort keys %easter;

# --- 2026 -----------------------------------------------------------------
my $y26 = holidays_for_year(2026);
is on($y26, 'new-years-day'), '2026-01-01', "New Year's Day";
is on($y26, 'mlk-day'), '2026-01-19', 'MLK Day: the third Monday of January';
is on($y26, 'presidents-day'), '2026-02-16', "Presidents' Day: the third Monday of February";
is on($y26, 'memorial-day'), '2026-05-25', 'Memorial Day: the last Monday of May';
is on($y26, 'juneteenth'), '2026-06-19', 'Juneteenth (a Friday: no observed day)';
is on($y26, 'independence-day'), '2026-07-04', 'Independence Day stays on the Fourth';
is on($y26, 'independence-day-observed'), '2026-07-03', '... and the Saturday is taken on the Friday';
is on($y26, 'labor-day'), '2026-09-07', 'Labor Day: the first Monday of September';
is on($y26, 'columbus-day'), '2026-10-12', 'Columbus Day: the second Monday of October';
is on($y26, 'veterans-day'), '2026-11-11', 'Veterans Day';
is on($y26, 'thanksgiving'), '2026-11-26', 'Thanksgiving: the fourth Thursday of November';
is on($y26, 'black-friday'), '2026-11-27', '... Black Friday the day after';
is on($y26, 'christmas'), '2026-12-25', 'Christmas';
is on($y26, 'election-day'), '2026-11-03', 'Election Day: the Tuesday after the first Monday of November';
is on($y26, 'dst-starts'), '2026-03-08', 'clocks forward: the second Sunday of March';
is on($y26, 'dst-ends'), '2026-11-01', 'clocks back: the first Sunday of November';
is on($y26, 'mothers-day'), '2026-05-10', "Mother's Day: the second Sunday of May";
is on($y26, 'fathers-day'), '2026-06-21', "Father's Day: the third Sunday of June";
is on($y26, 'easter'), '2026-04-05', 'Easter Sunday';
is on($y26, 'good-friday'), '2026-04-03', 'Good Friday';
is on($y26, 'palm-sunday'), '2026-03-29', 'Palm Sunday';
is on($y26, 'ash-wednesday'), '2026-02-18', 'Ash Wednesday';
is on($y26, 'tax-day'), '2026-04-15', 'Tax Day on a plain Wednesday';
my ($kw) = grep { $_->{id} eq 'kwanzaa' } @$y26;
is "$kw->{start} $kw->{end}", '2026-12-26 2027-01-02', 'Kwanzaa spans its seven days (end exclusive)';
is scalar(@$y26), 34, '33 rows every year plus the one observed day of 2026';
is scalar(grep { $_->{kind} eq 'federal' } @$y26), 11, 'eleven federal holidays';

# --- the observed day off, other years --------------------------------------
my $y27 = holidays_for_year(2027);
is on($y27, 'juneteenth-observed'), '2027-06-18', 'Juneteenth 2027 (a Saturday) is taken on the Friday';
is on($y27, 'independence-day-observed'), '2027-07-05', 'Independence Day 2027 (a Sunday) on the Monday';
is on($y27, 'christmas-observed'), '2027-12-24', 'Christmas 2027 (a Saturday) on the Friday';
is on($y27, 'election-day'), '2027-11-02', 'Election Day 2027';
is on($y27, 'dst-starts'), '2027-03-14', 'clocks forward 2027';
is on($y27, 'dst-ends'), '2027-11-07', 'clocks back 2027';
is on($y27, 'thanksgiving'), '2027-11-25', 'Thanksgiving 2027';
my $y28 = holidays_for_year(2028);
is on($y28, 'new-years-day-observed'), '2027-12-31', "New Year's Day 2028 (a Saturday) is taken on December 31, 2027: a row of 2028 in 2027";
is on($y28, 'veterans-day-observed'), '2028-11-10', 'Veterans Day 2028 (a Saturday) on the Friday';
is on($y28, 'election-day'), '2028-11-07', 'Election Day 2028';
ok !defined on($y26, 'christmas-observed'), 'no observed row when the day is a weekday';

# --- Tax Day: the IRS weekend and Emancipation Day rule --------------------
my %tax = (2016 => '2016-04-18', 2017 => '2017-04-18', 2018 => '2018-04-17', 2022 => '2022-04-18', 2023 => '2023-04-18',
           2024 => '2024-04-15', 2025 => '2025-04-15', 2027 => '2027-04-15', 2028 => '2028-04-18');
is on(holidays_for_year($_), 'tax-day'), $tax{$_}, "Tax Day $_" for sort keys %tax;

# --- the shape ---------------------------------------------------------------
my ($tg) = grep { $_->{id} eq 'thanksgiving' } @$y26;
is_deeply $tg, { id => 'thanksgiving', title => 'Thanksgiving Day', kind => 'federal', about => 'Federal holiday', year => 2026,
                 start => '2026-11-26', end => '2026-11-27', uid => 'us-thanksgiving-2026@holidays.homelab' }, 'a row has everything the model needs';
my ($ob) = grep { $_->{id} eq 'independence-day-observed' } @$y26;
is $ob->{title}, 'Independence Day (observed)', 'the observed row says so';
is $ob->{about}, 'Day off for a federal holiday that falls on a weekend', '... and explains itself';
is_deeply [ map { $_->{start} } @$y26 ], [ sort map { $_->{start} } @$y26 ], 'rows come sorted by date';
my %uid; $uid{ $_->{uid} }++ for @{ holidays_for_years(2025, 2036) };
is scalar(grep { $_ > 1 } values %uid), 0, 'UIDs are unique across twelve years';
ok((!grep { $_->{end} le $_->{start} } @{ holidays_for_years(2025, 2036) }), 'every row ends after it starts');
for my $y (2025 .. 2036) {
    my $rows = holidays_for_year($y);
    ok((!grep { $_->{kind} ne 'observed' && $_->{start} !~ /\A$y-/ } @$rows), "$y: every row but an observed day is in its year");
}
eval { holidays_for_year('soon') };
like $@, qr/a year is a number/, 'a bad year dies plainly';

# --- the digest ---------------------------------------------------------------
my $d1 = rules_digest(holidays_for_years(2025, 2036));
is $d1, rules_digest(holidays_for_years(2025, 2036)), 'the same window gives the same digest';
isnt $d1, rules_digest(holidays_for_years(2025, 2037)), 'another window another digest';
like $d1, qr/\A[0-9a-f]{64}\z/, 'a sha256';

# --- the Nager.Date watchdog ---------------------------------------------------
# Nager's real rows for 2026 (2026-11-17), trimmed to what the comparison reads.
my @nager = (
    { date => '2026-01-01', localName => "New Year's Day", name => "New Year's Day", global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-01-19', localName => 'Martin Luther King, Jr. Day', name => 'Martin Luther King, Jr. Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-02-12', localName => "Lincoln's Birthday", name => "Lincoln's Birthday", global => 0, counties => ['US-CT', 'US-IL'], types => ['Observance'] },
    { date => '2026-02-16', localName => "Washington's Birthday", name => 'Presidents Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-04-03', localName => 'Good Friday', name => 'Good Friday', global => 0, counties => ['US-CT'], types => ['Public'] },
    { date => '2026-05-08', localName => 'Truman Day', name => 'Truman Day', global => 0, counties => ['US-MO'], types => ['School', 'Authorities'] },
    { date => '2026-05-25', localName => 'Memorial Day', name => 'Memorial Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-06-19', localName => 'Juneteenth National Independence Day', name => 'Juneteenth National Independence Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-07-03', localName => 'Independence Day', name => 'Independence Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-09-07', localName => 'Labor Day', name => 'Labour Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-10-12', localName => 'Columbus Day', name => 'Columbus Day', global => 0, counties => ['US-AL'], types => ['Public'] },
    { date => '2026-10-12', localName => 'Columbus Day', name => 'Columbus Day', global => 1, counties => undef, types => ['Bank'] },
    { date => '2026-10-12', localName => "Indigenous Peoples' Day", name => "Indigenous Peoples' Day", global => 0, counties => ['US-AK'], types => ['Public'] },
    { date => '2026-11-11', localName => 'Veterans Day', name => 'Veterans Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-11-26', localName => 'Thanksgiving Day', name => 'Thanksgiving Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
    { date => '2026-12-25', localName => 'Christmas Day', name => 'Christmas Day', global => 1, counties => undef, types => ['Public', 'Bank'] },
);
is_deeply unknown_national_names(\@nager), [], 'the real 2026 list raises nothing';
push @nager, { date => '2026-09-17', localName => 'Constitution Day', name => 'Constitution Day', global => 1, counties => undef, types => ['Public'] };
push @nager, { date => '2026-09-18', localName => 'State Fair Day', name => 'State Fair Day', global => 0, counties => ['US-MN'], types => ['Public'] };
push @nager, { date => '2026-09-19', localName => 'Talk Like a Pirate Day', name => 'Talk Like a Pirate Day', global => 1, counties => undef, types => ['Observance'] };
is_deeply unknown_national_names(\@nager), ['Constitution Day'], 'a new national public holiday is named; a state day and an observance are not';
is_deeply unknown_national_names([ { localName => 'Constitution Day', global => 1, types => ['Public'] }, { localName => 'Constitution  Day', global => 1, types => ['Public'] } ]),
    ['Constitution Day'], 'the same name twice is one';
is_deeply unknown_national_names([ 'not a row', {}, { global => 1, types => ['Public'] } ]), [], 'junk rows are skipped';
is_deeply unknown_national_names(undef), [], 'nothing in, nothing out';

done_testing;
