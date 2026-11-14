package Homelab::Calendar::ICSImport;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use Data::ICal;
use Data::ICal::Property;
use Homelab::Calendar::Recurrence qw(validate_zone local_dt wall_string parse_rrule);

our @EXPORT_OK = qw(parse_ics);

# iCalendar in (post-cutover #82: homelab-cli calendar import). parse_ics turns
# the VEVENTs of one file into the inputs Model::create_event / update_event
# take, and says what it left out and why. Plain data in and out: the model
# stays the only place that knows the tables.
#
#   parse_ics($text, zone => $zone, max => 1000)
#     -> { events  => [ { uid, title, description, location, all_day, start, end,
#                         timezone, repeat, exdates => [wall strings], reminder_minutes } ],
#          skipped => [ { uid, reason } ],
#          error   => 'a sentence' }     # only when the text is not a calendar at all
#
# Dates: DTSTART/DTEND with a TZID keep that zone (an unknown TZID falls back
# to the account's zone); a UTC instant (...Z) is converted to the account's
# zone; a floating time is read in it; VALUE=DATE is an all-day event with
# iCalendar's exclusive end. No DTEND: DURATION, else the model's default (an
# hour; a day for all-day). RRULE is kept as written when this calendar can
# show it; EXDATEs become cancelled occurrences; a VALARM whose TRIGGER is a
# time before the start becomes the event's reminder. A component with a
# RECURRENCE-ID (one changed occurrence of a series) is skipped: the series
# itself is imported.

my $MAX_TEXT = 2_000_000;

sub parse_ics ($text, %o) {
    my $zone = $o{zone} // 'UTC';
    my $max  = $o{max} // 1000;
    $text //= '';
    return { events => [], skipped => [], error => 'The file is too large (2 MB at most).' } if length $text > $MAX_TEXT;
    return { events => [], skipped => [], error => 'That is not an iCalendar file (no BEGIN:VCALENDAR in it).' } unless $text =~ /BEGIN:VCALENDAR/;
    my $cal = Data::ICal->new(data => $text);
    unless ($cal && ref $cal && eval { $cal->isa('Data::ICal') }) {
        my $why = (ref $cal && eval { $cal->can('error_message') }) ? ($cal->error_message // 'unreadable') : 'unreadable';
        $why =~ s/\s+/ /g;
        return { events => [], skipped => [], error => "The file could not be read as iCalendar ($why)." };
    }
    my (@events, @skipped);
    my $n = 0;
    for my $e (@{ $cal->entries // [] }) {
        next unless ($e->ical_entry_type // '') eq 'VEVENT';
        if (++$n > $max) { push @skipped, { uid => undef, reason => "more than $max events in the file; the rest were not read" }; last }
        my $uid = _prop($e, 'uid');
        $uid = undef unless length $uid;
        if (length _prop($e, 'recurrence-id')) {
            push @skipped, { uid => $uid, reason => 'one changed occurrence of a repeating event; the series itself was imported' };
            next;
        }
        my $ds = $e->property('dtstart') ? $e->property('dtstart')->[0] : undef;
        unless ($ds) { push @skipped, { uid => $uid, reason => 'no start (DTSTART)' }; next }
        my ($start, $all_day, $ezone) = _when($ds, $zone);
        unless ($start) { push @skipped, { uid => $uid, reason => 'the start could not be read' }; next }
        my $end;
        if (my $de = $e->property('dtend') ? $e->property('dtend')->[0] : undef) {
            ($end) = _when($de, $ezone, $all_day);
        }
        elsif (length(my $dur = _prop($e, 'duration'))) {
            my $secs = _duration_seconds($dur);
            $end = $start->clone->add(seconds => $secs) if defined $secs && $secs > 0;
        }
        my $title = _prop($e, 'summary');
        $title =~ s/\s+/ /g; $title =~ s/\A\s+|\s+\z//g;
        my $location = _prop($e, 'location');
        $location =~ s/\s+/ /g;
        my %ev = (
            uid => $uid, title => (length $title ? $title : 'Untitled event'),
            description => _nonempty(_prop($e, 'description')), location => _nonempty($location),
            all_day => $all_day, timezone => $ezone,
            start => wall_string($start, $all_day), end => ($end ? wall_string($end, $all_day) : undef),
            repeat => undef, exdates => [], reminder_minutes => undef,
        );
        my $rrule = _prop($e, 'rrule');
        if (length $rrule) {
            unless (eval { parse_rrule($rrule, $ezone) }) {
                push @skipped, { uid => $uid, reason => "a repeat rule this calendar cannot show ($rrule)" };
                next;
            }
            $ev{repeat} = $rrule;
            for my $x (@{ $e->property('exdate') // [] }) {
                # One EXDATE line may list several, comma-separated.
                for my $v (split /,/, $x->value // '') {
                    my $p = Data::ICal::Property->new('exdate', $v, $x->parameters);
                    my ($dt) = _when($p, $ezone, $all_day);
                    push @{ $ev{exdates} }, wall_string($dt, $all_day) if $dt;
                }
            }
        }
        for my $a (@{ $e->entries // [] }) {
            next unless ($a->ical_entry_type // '') eq 'VALARM';
            my $trig = _prop($a, 'trigger');
            if ($trig =~ /\A-P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/) {
                my $m = ($1 // 0) * 10080 + ($2 // 0) * 1440 + ($3 // 0) * 60 + ($4 // 0);
                $ev{reminder_minutes} = $m if $m <= 20160;
                last;
            }
        }
        push @events, \%ev;
    }
    return { events => \@events, skipped => \@skipped };
}

# A property's text, unescaped ('' when absent).
sub _prop ($e, $name) {
    my $p = $e->property($name);
    return '' unless $p && @$p;
    my $v = eval { $p->[0]->decoded_value };
    $v = $p->[0]->value unless defined $v;
    return $v // '';
}

sub _nonempty ($s) { return (defined $s && $s =~ /\S/) ? $s : undef }

# A DTSTART/DTEND/EXDATE property -> (DateTime, all_day, zone name), or ().
sub _when ($p, $zone, $force_all_day = 0) {
    my $v = $p->value // '';
    my %par = %{ $p->parameters // {} };
    my $tzid = $par{TZID} // $par{tzid};
    my $ezone = (defined $tzid && validate_zone($tzid)) ? $tzid : $zone;
    if (($par{VALUE} // $par{value} // '') eq 'DATE' || $v =~ /\A\d{8}\z/) {
        my ($y, $m, $d) = $v =~ /\A(\d{4})(\d{2})(\d{2})\z/ or return ();
        my $dt = eval { local_dt($y, $m, $d, 0, 0, 0, $ezone, 1) } or return ();
        return ($dt, 1, $ezone);
    }
    my ($y, $m, $d, $H, $M, $S, $z) = $v =~ /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z?)\z/ or return ();
    my $dt;
    if ($z) {
        $dt = eval { local_dt($y, $m, $d, $H, $M, $S // 0, 'UTC', 1) } or return ();
        $dt->set_time_zone($ezone);
    }
    else {
        $dt = eval { local_dt($y, $m, $d, $H, $M, $S // 0, $ezone, 1) } or return ();
    }
    $dt->truncate(to => 'day') if $force_all_day;
    return ($dt, $force_all_day ? 1 : 0, $ezone);
}

# PnW | PnDTnHnMnS -> seconds, or undef when unreadable.
sub _duration_seconds ($s) {
    return $1 * 7 * 86400 if $s =~ /\AP(\d+)W\z/;
    my ($d, $h, $m, $sec) = $s =~ /\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/ or return undef;
    return ($d // 0) * 86400 + ($h // 0) * 3600 + ($m // 0) * 60 + ($sec // 0);
}

1;
