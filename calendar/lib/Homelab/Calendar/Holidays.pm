package Homelab::Calendar::Holidays;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use Digest::SHA qw(sha256_hex);

our @EXPORT_OK = qw(holidays_for_year holidays_for_years easter_sunday unknown_national_names rules_digest $SET_ID $SET_NAME);

# Common US holidays (post-cutover #92), as RULES, not as a list of dates
# fetched from anyone. The dates move; the rules do not: Thanksgiving is the
# fourth Thursday of November, Memorial Day the last Monday of May, written
# in law (5 U.S.C. 6103). Congress changed the federal list twice in forty
# years (MLK Day 1983, Juneteenth 2021). Easter is a formula. The observed
# day off -- a fixed holiday on a Saturday is taken on the Friday, on a
# Sunday on the Monday -- is a rule too. So the calendar needs no feed to
# show a holiday; holidays_for_year($y) is pure and the model materialises
# its answer as ordinary all-day events (Model.pm, fill_holidays). The one
# outside source is Nager.Date, asked once a year whether a national public
# holiday exists that these rules do not know (unknown_national_names).
#
# The list matches what Apple's and Google's US holiday calendars show,
# minus what cannot be a rule (Passover, Ramadan, Diwali, Lunar New Year:
# lunar calendars) and minus state and regional days.

our $SET_ID   = 'us';
our $SET_NAME = 'US Holidays';

my %ABOUT = (
    federal    => 'Federal holiday',
    observed   => 'Day off for a federal holiday that falls on a weekend',
    observance => 'Observance',
    christian  => 'Christian observance',
);

# Each rule: id, title, kind, and ONE way to find the day:
#   month + day              a fixed date
#   month + weekday + nth    the nth weekday of the month (1 = Monday ... 7 =
#                            Sunday, as DateTime counts; nth -1 = the last)
#   easter                   days from Easter Sunday
#   code                     a named rule in %CODE below
# observed => 1 on a fixed federal holiday adds the day off when it lands on
# a weekend; days => N makes it span N days.
my @RULES = (
    { id => 'new-years-day',    title => "New Year's Day",             kind => 'federal', month => 1,  day => 1,  observed => 1 },
    { id => 'mlk-day',          title => 'Martin Luther King Jr. Day', kind => 'federal', month => 1,  weekday => 1, nth => 3 },
    { id => 'presidents-day',   title => "Presidents' Day",            kind => 'federal', month => 2,  weekday => 1, nth => 3 },
    { id => 'memorial-day',     title => 'Memorial Day',               kind => 'federal', month => 5,  weekday => 1, nth => -1 },
    { id => 'juneteenth',       title => 'Juneteenth',                 kind => 'federal', month => 6,  day => 19, observed => 1 },
    { id => 'independence-day', title => 'Independence Day',           kind => 'federal', month => 7,  day => 4,  observed => 1 },
    { id => 'labor-day',        title => 'Labor Day',                  kind => 'federal', month => 9,  weekday => 1, nth => 1 },
    { id => 'columbus-day',     title => "Columbus Day (Indigenous Peoples' Day)", kind => 'federal', month => 10, weekday => 1, nth => 2 },
    { id => 'veterans-day',     title => 'Veterans Day',               kind => 'federal', month => 11, day => 11, observed => 1 },
    { id => 'thanksgiving',     title => 'Thanksgiving Day',           kind => 'federal', month => 11, weekday => 4, nth => 4 },
    { id => 'christmas',        title => 'Christmas Day',              kind => 'federal', month => 12, day => 25, observed => 1 },

    { id => 'groundhog-day',    title => 'Groundhog Day',              kind => 'observance', month => 2,  day => 2 },
    { id => 'valentines-day',   title => "Valentine's Day",            kind => 'observance', month => 2,  day => 14 },
    { id => 'dst-starts',       title => 'Daylight Saving Time starts', kind => 'observance', month => 3, weekday => 7, nth => 2 },
    { id => 'st-patricks-day',  title => "St. Patrick's Day",          kind => 'observance', month => 3,  day => 17 },
    { id => 'april-fools-day',  title => "April Fools' Day",           kind => 'observance', month => 4,  day => 1 },
    { id => 'tax-day',          title => 'Tax Day',                    kind => 'observance', code => 'tax' },
    { id => 'earth-day',        title => 'Earth Day',                  kind => 'observance', month => 4,  day => 22 },
    { id => 'cinco-de-mayo',    title => 'Cinco de Mayo',              kind => 'observance', month => 5,  day => 5 },
    { id => 'mothers-day',      title => "Mother's Day",               kind => 'observance', month => 5,  weekday => 7, nth => 2 },
    { id => 'flag-day',         title => 'Flag Day',                   kind => 'observance', month => 6,  day => 14 },
    { id => 'fathers-day',      title => "Father's Day",               kind => 'observance', month => 6,  weekday => 7, nth => 3 },
    { id => 'halloween',        title => 'Halloween',                  kind => 'observance', month => 10, day => 31 },
    { id => 'election-day',     title => 'Election Day',               kind => 'observance', code => 'election' },
    { id => 'dst-ends',         title => 'Daylight Saving Time ends',  kind => 'observance', month => 11, weekday => 7, nth => 1 },
    { id => 'black-friday',     title => 'Black Friday',               kind => 'observance', code => 'black_friday' },
    { id => 'christmas-eve',    title => 'Christmas Eve',              kind => 'observance', month => 12, day => 24 },
    { id => 'kwanzaa',          title => 'Kwanzaa',                    kind => 'observance', month => 12, day => 26, days => 7 },
    { id => 'new-years-eve',    title => "New Year's Eve",             kind => 'observance', month => 12, day => 31 },

    { id => 'ash-wednesday',    title => 'Ash Wednesday',              kind => 'christian', easter => -46 },
    { id => 'palm-sunday',      title => 'Palm Sunday',                kind => 'christian', easter => -7 },
    { id => 'good-friday',      title => 'Good Friday',                kind => 'christian', easter => -2 },
    { id => 'easter',           title => 'Easter Sunday',              kind => 'christian', easter => 0 },
);

sub _d ($y, $m, $d) { return DateTime->new(year => $y, month => $m, day => $d) }

# The nth weekday of a month; -1 = the last one.
sub _nth_weekday ($y, $m, $weekday, $nth) {
    if ($nth > 0) {
        my $first = _d($y, $m, 1);
        return $first->add(days => ($weekday - $first->day_of_week) % 7 + 7 * ($nth - 1));
    }
    my $last = DateTime->last_day_of_month(year => $y, month => $m);
    return $last->subtract(days => ($last->day_of_week - $weekday) % 7);
}

# Easter Sunday in the Gregorian calendar (the anonymous algorithm given by
# Meeus; exact for every year of the Gregorian calendar).
sub easter_sunday ($y) {
    my $a = $y % 19;
    my $b = int($y / 100);
    my $c = $y % 100;
    my $d = int($b / 4);
    my $e = $b % 4;
    my $f = int(($b + 8) / 25);
    my $g = int(($b - $f + 1) / 3);
    my $h = (19 * $a + $b - $d - $g + 15) % 30;
    my $i = int($c / 4);
    my $k = $c % 4;
    my $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7;
    my $m = int(($a + 11 * $h + 22 * $l) / 451);
    my $month = int(($h + $l - 7 * $m + 114) / 31);
    my $day   = (($h + $l - 7 * $m + 114) % 31) + 1;
    return _d($y, $month, $day);
}

my %CODE = (
    # The Tuesday after the first Monday of November (3 U.S.C. 1, 2 U.S.C. 7).
    election => sub ($y) { return _nth_weekday($y, 11, 1, 1)->add(days => 1) },
    # The day after Thanksgiving.
    black_friday => sub ($y) { return _nth_weekday($y, 11, 4, 4)->add(days => 1) },
    # April 15, or the next weekday when that is a weekend or the District of
    # Columbia's Emancipation Day (April 16, itself observed on the Friday or
    # Monday when it falls on a weekend), which the IRS counts as a holiday.
    # Gives April 18 for 2016, 2017, 2022 and 2023, April 17 for 2018.
    tax => sub ($y) {
        my $em = _d($y, 4, 16);
        $em = $em->day_of_week == 6 ? $em->subtract(days => 1) : $em->day_of_week == 7 ? $em->add(days => 1) : $em;
        my $d = _d($y, 4, 15);
        $d->add(days => 1) while $d->day_of_week >= 6 || $d->ymd eq $em->ymd;
        return $d;
    },
);

sub _row ($rule, $start, $y, %over) {
    my $days = $rule->{days} // 1;
    my %r = (
        id => $rule->{id}, title => $rule->{title}, kind => $rule->{kind}, about => $ABOUT{ $rule->{kind} },
        year => $y, start => $start->ymd, end => $start->clone->add(days => $days)->ymd, %over,
    );
    $r{about} = $ABOUT{ $r{kind} };
    $r{uid} = "$SET_ID-$r{id}-$y\@holidays.homelab";
    return \%r;
}

# holidays_for_year($year) -> [ { id, title, kind, about, year, start, end, uid } ]
# sorted by date; end is exclusive, as the calendar's all-day events are.
# An observed day off is its own row (id "<id>-observed"); it can fall in the
# year before (New Year's Day on a Saturday is taken on December 31).
sub holidays_for_year ($y) {
    die "holidays_for_year: a year is a number\n" unless defined $y && $y =~ /\A\d{4}\z/;
    my @rows;
    for my $rule (@RULES) {
        my $day = defined $rule->{day}     ? _d($y, $rule->{month}, $rule->{day})
                : defined $rule->{nth}     ? _nth_weekday($y, $rule->{month}, $rule->{weekday}, $rule->{nth})
                : defined $rule->{easter}  ? easter_sunday($y)->add(days => $rule->{easter})
                : defined $rule->{code}    ? $CODE{ $rule->{code} }->($y)
                : die "holidays: rule $rule->{id} has no way to find its day\n";
        push @rows, _row($rule, $day, $y);
        next unless $rule->{observed};
        my $dow = $day->day_of_week;
        next unless $dow >= 6;
        my $off = $dow == 6 ? $day->clone->subtract(days => 1) : $day->clone->add(days => 1);
        push @rows, _row({ %$rule, id => "$rule->{id}-observed", title => "$rule->{title} (observed)", kind => 'observed', days => 1 }, $off, $y);
    }
    return [ sort { $a->{start} cmp $b->{start} || $a->{id} cmp $b->{id} } @rows ];
}

sub holidays_for_years ($from, $to) {
    return [ map { @{ holidays_for_year($_) } } $from .. $to ];
}

# One string that changes when any row of the given list would: the model
# stores it with the fill and skips the work while it is the same.
sub rules_digest ($rows) {
    return sha256_hex(join "\n", map { join '|', @{$_}{qw(uid title start end kind)} } @$rows);
}

# The watchdog (Nager.Date, https://date.nager.at/api/v3/PublicHolidays/<year>/US).
# Given its rows for a year, the national public holidays whose names match
# none of the federal holidays above. Nager writes the observed day in place
# of the real one and "Labour Day", so only NAMES are compared, loosely.
# A row is national when it is marked global or names no counties, and
# counts only when it is a public holiday (not a school or bank day).
my @FEDERAL_PATTERNS = (
    qr/new year/i, qr/martin luther king/i, qr/washington|presidents?/i, qr/memorial day/i, qr/juneteenth/i,
    qr/independence day/i, qr/labou?r day/i, qr/columbus|indigenous/i, qr/veterans/i, qr/thanksgiving/i, qr/christmas/i,
);
sub unknown_national_names ($rows) {
    my %seen;
    my @unknown;
    for my $r (@{ $rows // [] }) {
        next unless ref $r eq 'HASH';
        my $types = ref $r->{types} eq 'ARRAY' ? $r->{types} : [];
        next unless grep { lc($_ // '') eq 'public' } @$types;
        my $national = $r->{global} || !(ref $r->{counties} eq 'ARRAY' && @{ $r->{counties} });
        next unless $national;
        my @names = grep { defined && /\S/ } ($r->{localName}, $r->{name});
        next unless @names;
        next if grep { my $n = $_; grep { $n =~ $_ } @FEDERAL_PATTERNS } @names;
        my $shown = $names[0] =~ s/\s+/ /gr;
        push @unknown, $shown unless $seen{ lc $shown }++;
    }
    return [ sort @unknown ];
}

1;
