package Homelab::Calendar::Recurrence;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use DateTime::TimeZone;
use DateTime::Span;
use DateTime::Format::ICal;

our @EXPORT_OK = qw(
    build_rrule parse_rrule validate_zone
    local_dt floating_dt wall_string parse_wall
    occurrences recurrence_bound
    rrule_until_before rrule_strip_end occurrences_before shift_rrule
);

# Repeating events, done in ONE place so the browser, the ICS feed and the
# editor can never disagree about when something happens.
#
# THE MODEL. A repeating event is stored as its first occurrence (wall-clock
# time + an IANA zone) plus an RFC 5545 RRULE string. Occurrences are expanded
# HERE, on the server, in the event's zone, in wall-clock time: "every Monday
# at 09:00 Chicago" stays 09:00 across the DST change (the instant moves by an
# hour, the wall clock does not), which is what every calendar a person has
# ever used does. The browser only draws what the server hands it.
#
# WHY WALL-CLOCK (floating) EXPANSION, THEN THE ZONE: DateTime::Event::ICal
# works in floating time. Expanding the rule in the event's zone and then
# attaching the zone to each occurrence is exactly RFC 5545's rule for a
# DTSTART with a TZID. A wall-clock time that does not exist on one day
# (02:30 on the spring-forward night) is pushed forward to the next valid
# minute rather than lost.
#
# WHY A SUBSET OF RFC 5545: the editor builds the rule from a form (frequency,
# interval, weekdays, a monthly pattern, an end), so the rules in the database
# are always ones the editor can show again. parse_rrule() is the inverse, and
# refuses anything it could not have written. Full RRULE import (BYSETPOS,
# BYYEARDAY, WKST, ...) is a later item, with .ics import.

my %FREQ = map { $_ => 1 } qw(DAILY WEEKLY MONTHLY YEARLY);
my @WEEKDAYS = qw(SU MO TU WE TH FR SA);
my %WEEKDAY  = map { $WEEKDAYS[$_] => $_ } 0 .. $#WEEKDAYS;

# How far ahead an open-ended rule is ever expanded, and how many occurrences
# one request may produce. The UI asks for one view at a time (a month, a
# week), so these only bite on a feed asking for years of a daily event.
our $MAX_OCCURRENCES = 2000;

sub validate_zone ($zone) {
    return 0 unless defined $zone && length $zone;
    return 0 if $zone eq 'floating';
    return DateTime::TimeZone->is_valid_name($zone) ? 1 : 0;
}

# build_rrule(\%form) -> 'FREQ=...;...' or dies with a one-line reason the UI
# can show. The form is what the editor sends:
#   freq        daily | weekly | monthly | yearly
#   interval    1.. (default 1)
#   byday       [ 'MO', 'WE', ... ]            weekly only
#   monthly_by  'monthday' | 'weekday'          monthly only (default monthday)
#   until       'YYYY-MM-DD'  (inclusive, in the event's zone)   -- or --
#   count       1..
# dtstart (a DateTime in the event's zone) is needed for the monthly weekday
# pattern ("the 2nd Tuesday") and for the UNTIL instant.
sub build_rrule ($form, $dtstart) {
    my $freq = uc($form->{freq} // '');
    die "Choose how often the event repeats.\n" unless $FREQ{$freq};
    my $interval = $form->{interval} // 1;
    die "The interval must be a whole number from 1 to 999.\n"
        unless $interval =~ /\A\d{1,3}\z/ && $interval >= 1;

    my @parts = ("FREQ=$freq");
    push @parts, "INTERVAL=$interval" if $interval != 1;

    if ($freq eq 'WEEKLY') {
        my @days = map { uc } grep { defined && length } @{ $form->{byday} // [] };
        for (@days) { die "Unknown weekday '$_'.\n" unless exists $WEEKDAY{$_} }
        my %seen; @days = sort { $WEEKDAY{$a} <=> $WEEKDAY{$b} } grep { !$seen{$_}++ } @days;
        # No weekday ticked means the weekday the event starts on.
        @days = ($WEEKDAYS[ $dtstart->day_of_week % 7 ]) unless @days;
        push @parts, 'BYDAY=' . join(',', @days);
    }
    elsif ($freq eq 'MONTHLY') {
        my $by = $form->{monthly_by} // 'monthday';
        if ($by eq 'weekday') {
            # "the 2nd Tuesday of the month". A 5th weekday is written as -1
            # ("the last Friday"), since no month has a 5th one every time; a
            # 4th stays the 4th even when it happens to be the last this month.
            my $nth = int(($dtstart->day - 1) / 7) + 1;
            $nth = -1 if $nth == 5;
            push @parts, 'BYDAY=' . $nth . $WEEKDAYS[ $dtstart->day_of_week % 7 ];
        }
        elsif ($by eq 'monthday') {
            push @parts, 'BYMONTHDAY=' . $dtstart->day;
        }
        else { die "Unknown monthly pattern '$by'.\n" }
    }

    if (defined $form->{count} && length $form->{count}) {
        die "The number of occurrences must be a whole number from 1 to 9999.\n"
            unless $form->{count} =~ /\A\d{1,4}\z/ && $form->{count} >= 1;
        die "Give either an end date or a number of occurrences, not both.\n"
            if defined $form->{until} && length $form->{until};
        push @parts, 'COUNT=' . int($form->{count});
    }
    elsif (defined $form->{until} && length $form->{until}) {
        my ($y, $m, $d) = $form->{until} =~ /\A(\d{4})-(\d{2})-(\d{2})\z/
            or die "The end date must look like 2026-12-31.\n";
        my $until = eval { DateTime->new(year => $y, month => $m, day => $d, hour => 23, minute => 59, second => 59,
                                         time_zone => $dtstart->time_zone) }
            or die "That end date does not exist.\n";
        die "The end date is before the event starts.\n" if $until < $dtstart;
        # RFC 5545: UNTIL is a UTC instant when DTSTART carries a zone. Stored
        # as the last second of that day in the event's zone, so the day itself
        # is included, as the form promises.
        push @parts, 'UNTIL=' . $until->clone->set_time_zone('UTC')->strftime('%Y%m%dT%H%M%SZ');
    }
    return join ';', @parts;
}

# parse_rrule($rrule) -> \%form (the inverse of build_rrule), or undef for a
# rule this editor cannot show. The until date comes back as 'YYYY-MM-DD' in
# the zone given.
sub parse_rrule ($rrule, $zone = 'UTC') {
    return undef unless defined $rrule && length $rrule;
    my %p;
    for my $kv (split /;/, $rrule) {
        my ($k, $v) = split /=/, $kv, 2;
        return undef unless defined $v;
        $p{ uc $k } = $v;
    }
    my $freq = $p{FREQ} // return undef;
    return undef unless $FREQ{$freq};
    my %form = (freq => lc $freq, interval => ($p{INTERVAL} // 1) + 0);
    for my $k (keys %p) {
        return undef unless grep { $k eq $_ } qw(FREQ INTERVAL BYDAY BYMONTHDAY COUNT UNTIL);
    }
    if ($freq eq 'WEEKLY') {
        $form{byday} = [ split /,/, ($p{BYDAY} // '') ];
        return undef if grep { !exists $WEEKDAY{$_} } @{ $form{byday} };
    }
    elsif ($freq eq 'MONTHLY') {
        if ($p{BYDAY})        { return undef unless $p{BYDAY} =~ /\A-?[1-5](?:SU|MO|TU|WE|TH|FR|SA)\z/; $form{monthly_by} = 'weekday' }
        elsif ($p{BYMONTHDAY}) { return undef unless $p{BYMONTHDAY} =~ /\A\d{1,2}\z/; $form{monthly_by} = 'monthday' }
        else { $form{monthly_by} = 'monthday' }
    }
    if (defined $p{COUNT}) { return undef unless $p{COUNT} =~ /\A\d+\z/; $form{count} = $p{COUNT} + 0 }
    if (defined $p{UNTIL}) {
        my ($y, $m, $d, $H, $M, $S, $z) = $p{UNTIL} =~ /\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?\z/ or return undef;
        my $dt = eval { DateTime->new(year => $y, month => $m, day => $d, hour => $H // 0, minute => $M // 0, second => $S // 0,
                                      time_zone => ($z ? 'UTC' : $zone)) } or return undef;
        $dt->set_time_zone($zone) if validate_zone($zone);
        $form{until} = $dt->ymd;
    }
    return \%form;
}

# A DateTime at a wall-clock time in a zone. Dies on a time that does not
# exist there (the spring-forward gap) unless $forgiving, which then moves
# forward to the first minute that does.
sub local_dt ($y, $m, $d, $H = 0, $M = 0, $S = 0, $zone = 'UTC', $forgiving = 1) {
    my %args = (year => $y, month => $m, day => $d, hour => $H, minute => $M, second => $S, time_zone => $zone);
    my $dt = eval { DateTime->new(%args) };
    return $dt if $dt;
    die $@ unless $forgiving && $@ =~ /Invalid local time/;
    # Walk forward in 15-minute steps (the gap is an hour on every real zone,
    # 30 minutes on Lord Howe Island) until the clock exists again.
    for my $step (1 .. 8) {
        my $try = DateTime->new(%args, time_zone => 'floating')->add(minutes => 15 * $step);
        my $ok = eval { DateTime->new(year => $try->year, month => $try->month, day => $try->day, hour => $try->hour,
                                      minute => $try->minute, second => $try->second, time_zone => $zone) };
        return $ok if $ok;
    }
    die $@;
}

# The same wall clock as $dt, as a floating DateTime (what the RRULE engine
# wants), and the inverse: a floating wall clock placed into a zone.
sub floating_dt ($dt) {
    return DateTime->new(year => $dt->year, month => $dt->month, day => $dt->day, hour => $dt->hour,
                         minute => $dt->minute, second => $dt->second, time_zone => 'floating');
}

sub _zoned ($floating, $zone) {
    return local_dt($floating->year, $floating->month, $floating->day, $floating->hour, $floating->minute,
                    $floating->second, $zone, 1);
}

# 'YYYY-MM-DDTHH:MM:SS' -- the form the browser and the API speak: a wall
# clock with NO offset, always paired with a zone name. For all-day values,
# 'YYYY-MM-DD'.
sub wall_string ($dt, $all_day = 0) {
    return $all_day ? $dt->ymd : $dt->strftime('%Y-%m-%dT%H:%M:%S');
}

# parse_wall($string, $zone) -> DateTime in $zone, or undef. Accepts the
# wall-clock form above, a date alone (midnight), and -- because the browser
# library hands wall clocks back as if they were UTC ('...Z') -- an ISO string
# whose offset is simply dropped.
sub parse_wall ($s, $zone) {
    return undef unless defined $s;
    my ($y, $m, $d, $H, $M, $S) = $s =~ /\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(?:Z|[+-]\d{2}:?\d{2})?\z/
        or return undef;
    return eval { local_dt($y, $m, $d, $H // 0, $M // 0, $S // 0, $zone, 1) };
}

# recurrence_bound($dtstart, $rrule) -> the instant after which the rule
# produces nothing (a DateTime), or undef for an open-ended rule. Stored on the
# event so the window query can skip rules that ended years ago without
# expanding them.
sub recurrence_bound ($dtstart, $rrule) {
    my $form = parse_rrule($rrule, $dtstart->time_zone->name) or return undef;
    if ($form->{until}) {
        my ($y, $m, $d) = split /-/, $form->{until};
        return local_dt($y, $m, $d, 23, 59, 59, $dtstart->time_zone->name, 1);
    }
    if ($form->{count}) {
        my $set = _set($dtstart, $rrule) or return undef;
        my $last;
        my $it = $set->iterator;
        my $n = 0;
        while (my $d = $it->next) { $last = $d; last if ++$n > 10000 }
        return $last ? _zoned($last, $dtstart->time_zone->name) : undef;
    }
    return undef;
}

sub _set ($dtstart, $rrule) {
    my $set = eval { DateTime::Format::ICal->parse_recurrence(recurrence => $rrule, dtstart => floating_dt($dtstart)) };
    return $set;
}

# occurrences(%args) -> [ DateTime (in the event's zone), ... ] of the rule's
# occurrences that START inside [window_start, window_end), in order. With no
# rrule: the start itself, if it falls in the window.
#   dtstart       DateTime in the event's zone (the first occurrence)
#   rrule         string or undef
#   window_start  DateTime (any zone)
#   window_end    DateTime (any zone), exclusive
#   limit         optional, default $MAX_OCCURRENCES
# An occurrence is identified afterwards by its start instant (the
# RECURRENCE-ID), which is what event_exceptions rows key on.
sub occurrences (%args) {
    my $dtstart = $args{dtstart} or die "occurrences(): dtstart required\n";
    my $zone    = $dtstart->time_zone->name;
    my ($ws, $we) = @args{qw(window_start window_end)};
    die "occurrences(): window_start and window_end required\n" unless $ws && $we;
    my $limit = $args{limit} // $MAX_OCCURRENCES;

    unless (defined $args{rrule} && length $args{rrule}) {
        return [ ($dtstart >= $ws && $dtstart < $we) ? $dtstart : () ];
    }
    my $set = _set($dtstart, $args{rrule}) or return [];

    # The window, as the event's wall clock, since the set is floating. A
    # window edge that falls in a DST gap is nudged like any other wall time.
    my $fs = floating_dt($ws->clone->set_time_zone($zone));
    my $fe = floating_dt($we->clone->set_time_zone($zone));
    # DTSTART is always the first occurrence, even when the rule's own pattern
    # would not include it (RFC 5545 says so, and so does every calendar).
    my $first = floating_dt($dtstart);
    my @out;
    push @out, $first if $first >= $fs && $first < $fe;

    my $span = DateTime::Span->from_datetimes(start => $fs, before => $fe);
    my $it = $set->intersection($span)->iterator;
    while (my $d = $it->next) {
        next if $d == $first;
        push @out, $d;
        last if @out >= $limit;
    }
    return [ map { _zoned($_, $zone) } @out ];
}

# --- helpers for editing a series ("this and following") -------------------

# The rule, ending just before $instant (a DateTime): COUNT or UNTIL replaced
# by UNTIL one second earlier, as UTC. What the original series keeps when a
# series is split at an occurrence.
sub rrule_until_before ($rrule, $instant) {
    my @keep = grep { !/^(?:COUNT|UNTIL)=/i } split /;/, $rrule;
    my $until = $instant->clone->set_time_zone('UTC')->subtract(seconds => 1);
    return join ';', @keep, 'UNTIL=' . $until->strftime('%Y%m%dT%H%M%SZ');
}

# The rule with no end at all (COUNT and UNTIL removed).
sub rrule_strip_end ($rrule) {
    return join ';', grep { !/^(?:COUNT|UNTIL)=/i } split /;/, $rrule;
}

# How many occurrences the rule produces strictly before $instant -- what a
# COUNT has to be reduced by when a series is split there.
sub occurrences_before ($dtstart, $rrule, $instant) {
    my $set = _set($dtstart, $rrule) or return 0;
    my $zone = $dtstart->time_zone->name;
    my $fe = floating_dt($instant->clone->set_time_zone($zone));
    my $first = floating_dt($dtstart);
    my $n = $first < $fe ? 1 : 0;
    my $span = DateTime::Span->from_datetimes(start => $first, before => $fe);
    my $it = $set->intersection($span)->iterator;
    while (my $d = $it->next) {
        next if $d == $first;
        $n++;
        last if $n > 10000;
    }
    return $n;
}

# A whole series moved by a drag: the start moved $days days (and some
# seconds, handled by the caller), so a weekly rule's weekdays rotate with it
# and a monthly rule follows the new start day. Returns the new rule.
sub shift_rrule ($rrule, $new_dtstart, $days) {
    my $form = parse_rrule($rrule, $new_dtstart->time_zone->name) or return $rrule;
    if ($form->{freq} eq 'weekly' && $days % 7) {
        my @rot = map { $WEEKDAYS[ ($WEEKDAY{$_} + $days) % 7 ] } @{ $form->{byday} // [] };
        $form->{byday} = \@rot;
    }
    # build_rrule recomputes BYMONTHDAY / the "2nd Tuesday" from the new start.
    return eval { build_rrule($form, $new_dtstart) } // $rrule;
}

1;
