package Homelab::Calendar::ICS;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use Data::ICal;
use Data::ICal::Entry::Event;

our @EXPORT_OK = qw(instances_ics masters_ics ics_datetime ics_date);

# iCalendar output, in two shapes:
#
#   instances_ics  every occurrence in a window as its OWN VEVENT with a UTC
#                  start and end. This is what a subscription feed serves: it
#                  needs no VTIMEZONE (there is no TZID anywhere), every phone
#                  renders UTC in its own zone, and a daily event for two years
#                  is ~700 small components. Repeating events get a derived UID
#                  per occurrence, so no client has to understand RRULE or
#                  RECURRENCE-ID to show the feed right.
#
#   masters_ics    each event once, with its RRULE, DTSTART;TZID=<zone>, EXDATE
#                  for cancelled occurrences and one RECURRENCE-ID VEVENT per
#                  moved one. This is the export a person downloads to carry a
#                  calendar somewhere else: the rule survives, as it would not
#                  in the expanded form. TZID without a VTIMEZONE component is
#                  how Google Calendar's own exports do it; strict RFC 5545
#                  wants the VTIMEZONE too, and a consumer that insists on it is
#                  the known limit of this export.
#
# Both take plain data (strings and DateTime objects), never database handles,
# so they are testable on their own and the model stays the only place that
# knows the tables.
#
# Every occurrence or event hash: uid, title, description, location, all_day,
# start (DateTime, in the event's zone), end (DateTime, exclusive),
# created (DateTime, optional), updated (DateTime, optional), url (optional).
# For masters: rrule (optional), exdates => [DateTime], overrides => [ {
# recurrence_id => DateTime, plus the occurrence's own start/end/title/... } ].

my $PRODID = '-//Silver Linings LLC//homelab-calendar//EN';

sub ics_datetime ($dt) { return $dt->clone->set_time_zone('UTC')->strftime('%Y%m%dT%H%M%SZ') }
sub ics_date     ($dt) { return $dt->strftime('%Y%m%d') }
sub _ics_wall    ($dt) { return $dt->strftime('%Y%m%dT%H%M%S') }

sub _calendar (%args) {
    my $cal = Data::ICal->new(rfc_strict => 1);
    # Data::ICal writes its own PRODID; replace it with ours.
    $cal->properties->{prodid} = [];
    $cal->add_properties(
        prodid => $PRODID,
        method => 'PUBLISH',
        ($args{name} ? ('X-WR-CALNAME' => $args{name}) : ()),
        ($args{zone} ? ('X-WR-TIMEZONE' => $args{zone}) : ()),
        ($args{description} ? ('X-WR-CALDESC' => $args{description}) : ()),
    );
    return $cal;
}

# The common VEVENT body. $when is how the dates are written: 'utc' (feed) or
# 'tzid' (export). 'busy' detail replaces the title and drops the rest.
sub _event_props ($e, $when, $detail, $now) {
    my @props = (
        uid     => $e->{uid},
        dtstamp => ics_datetime($now),
    );
    if ($e->{all_day}) {
        push @props, dtstart => [ ics_date($e->{start}), { VALUE => 'DATE' } ],
                     dtend   => [ ics_date($e->{end}),   { VALUE => 'DATE' } ];
    }
    elsif ($when eq 'utc') {
        push @props, dtstart => ics_datetime($e->{start}), dtend => ics_datetime($e->{end});
    }
    else {
        my $zone = $e->{start}->time_zone->name;
        push @props, dtstart => [ _ics_wall($e->{start}), { TZID => $zone } ],
                     dtend   => [ _ics_wall($e->{end}->clone->set_time_zone($zone)), { TZID => $zone } ];
    }
    if ($detail eq 'busy') {
        push @props, summary => 'Busy', transp => 'OPAQUE';
    }
    else {
        push @props, summary => ($e->{title} // '');
        push @props, description => $e->{description} if defined $e->{description} && length $e->{description};
        push @props, location    => $e->{location}    if defined $e->{location}    && length $e->{location};
        push @props, url         => $e->{url}         if defined $e->{url}         && length $e->{url};
    }
    push @props, created         => ics_datetime($e->{created}) if $e->{created};
    push @props, 'last-modified' => ics_datetime($e->{updated}) if $e->{updated};
    return @props;
}

# instances_ics(name => ..., zone => ..., detail => 'full'|'busy', now => DateTime,
#               instances => [ { ...occurrence, recurrence_id => DateTime|undef } ])
sub instances_ics (%args) {
    my $now = $args{now} // DateTime->now(time_zone => 'UTC');
    my $detail = $args{detail} // 'full';
    my $cal = _calendar(%args);
    for my $i (@{ $args{instances} // [] }) {
        my %e = %$i;
        # One VEVENT per occurrence, each with its own UID: the feed never
        # asks a client to expand anything.
        $e{uid} = ics_datetime($i->{recurrence_id}) . '-' . $i->{uid} if $i->{recurrence_id};
        my $ev = Data::ICal::Entry::Event->new;
        $ev->add_properties(_event_props(\%e, 'utc', $detail, $now));
        $cal->add_entry($ev);
    }
    return $cal->as_string;
}

# masters_ics(name => ..., zone => ..., now => DateTime, events => [ { ...event,
#             rrule, exdates => [DateTime], overrides => [ { recurrence_id => DateTime, ... } ] } ])
sub masters_ics (%args) {
    my $now = $args{now} // DateTime->now(time_zone => 'UTC');
    my $cal = _calendar(%args);
    for my $e (@{ $args{events} // [] }) {
        my $ev = Data::ICal::Entry::Event->new;
        my @props = _event_props($e, 'tzid', 'full', $now);
        if (defined $e->{rrule} && length $e->{rrule}) {
            push @props, rrule => $e->{rrule};
            my $zone = $e->{start}->time_zone->name;
            for my $x (@{ $e->{exdates} // [] }) {
                push @props, exdate => $e->{all_day}
                    ? [ ics_date($x), { VALUE => 'DATE' } ]
                    : [ _ics_wall($x->clone->set_time_zone($zone)), { TZID => $zone } ];
            }
        }
        $ev->add_properties(@props);
        $cal->add_entry($ev);

        # A moved or retitled occurrence: the same UID, RECURRENCE-ID naming
        # the occurrence it replaces.
        for my $o (@{ $e->{overrides} // [] }) {
            my $zone = $e->{start}->time_zone->name;
            my %x = (%$e, %$o, uid => $e->{uid});
            delete @x{qw(rrule exdates overrides recurrence_id)};
            my $ov = Data::ICal::Entry::Event->new;
            my @op = _event_props(\%x, 'tzid', 'full', $now);
            push @op, 'recurrence-id' => $e->{all_day}
                ? [ ics_date($o->{recurrence_id}), { VALUE => 'DATE' } ]
                : [ _ics_wall($o->{recurrence_id}->clone->set_time_zone($zone)), { TZID => $zone } ];
            $ov->add_properties(@op);
            $cal->add_entry($ov);
        }
    }
    return $cal->as_string;
}

1;
