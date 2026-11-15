package Homelab::Calendar::Invite;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use Homelab::Calendar::ICS qw(masters_ics);

our @EXPORT_OK = qw(request_message cancel_message reply_notice_message event_ics when_line status_word);

# The mail about invitations (post-cutover #85), as plain data in and a
# subject, a plain-text body and (for a request or a cancel) an iCalendar
# text out. Pure, so t/invite.t can read every line; the runner adds the
# SMTP. The iCalendar part is what Gmail, Outlook and Apple Mail turn into
# their own Yes / Maybe / No buttons (METHOD:REQUEST, an ORGANIZER, the
# recipient among the ATTENDEEs); the body carries the same three choices as
# links to /i/<token> for everyone else.
#
# Every function takes:
#   event      the event row (title, description, location, all_day, timezone, uid, sequence, rrule)
#   start, end DateTime in the event's zone (the first occurrence)
#   organizer  the owner's address
#   attendee   { email, name, status, token }   (the recipient of a request/cancel)
#   attendees  [ { email, name, status } ]      (everyone, for the ATTENDEE lines)
#   base_url   https://calendar.<domain>
#   now        DateTime (optional, for the tests)

sub _clock ($dt) { my $h = $dt->hour % 12 || 12; return sprintf('%d:%02d %s', $h, $dt->minute, $dt->hour < 12 ? 'AM' : 'PM') }

# 'Friday, November 20, 2026 2:30 PM to 3:30 PM (America/Chicago)', or for an
# all-day event the day(s).
sub when_line (%a) {
    my ($s, $e) = ($a{start}, $a{end});
    my $zone = $a{zone} // $s->time_zone->name;
    if ($a{all_day}) {
        my $last = $e->clone->subtract(days => 1);
        return $last->ymd gt $s->ymd
            ? $s->strftime('%A, %B ') . $s->day . ' to ' . $last->strftime('%A, %B ') . $last->day . ', ' . $last->year . ' (all day)'
            : $s->strftime('%A, %B ') . $s->day . ', ' . $s->year . ' (all day)';
    }
    my $same = $s->ymd eq $e->ymd;
    return $s->strftime('%A, %B ') . $s->day . ', ' . $s->year . ' ' . _clock($s) . ' to ' . ($same ? '' : $e->strftime('%A, %B ') . $e->day . ', ' . $e->year . ' ') . _clock($e)
         . ' (' . ($zone =~ s/_/ /gr) . ')';
}

# The short form for a subject: 'Fri Nov 20, 2026 2:30 PM' / 'Fri Nov 20, 2026'.
sub _short_when ($s, $all_day) { return $s->strftime('%a %b ') . $s->day . ', ' . $s->year . ($all_day ? '' : ' ' . _clock($s)) }

sub status_word ($s) {
    return { accepted => 'accepted', tentative => 'might come', declined => 'declined', 'needs-action' => 'has not answered' }->{ $s // '' } // 'has not answered';
}

# The iCalendar text of one event for an invitation (REQUEST), a cancellation
# (CANCEL) or a plain copy (PUBLISH): the series with its rule, exceptions,
# organizer and attendees. `exdates`/`overrides` as masters_ics takes them.
sub event_ics (%a) {
    my $e = $a{event};
    my $method = $a{method} // 'REQUEST';
    return masters_ics(
        name => $e->{title}, zone => $e->{timezone}, method => $method, now => $a{now},
        events => [ {
            uid => $e->{uid}, title => $e->{title}, description => $e->{description}, location => $e->{location},
            all_day => ($e->{all_day} ? 1 : 0), start => $a{start}, end => $a{end}, rrule => $e->{rrule},
            exdates => $a{exdates} // [], overrides => $a{overrides} // [],
            created => $a{created}, updated => $a{updated},
            sequence => ($a{sequence} // $e->{sequence} // 0), ($method eq 'CANCEL' ? (status => 'CANCELLED') : ()),
            organizer => { email => $a{organizer} }, attendees => $a{attendees} // [],
            url => ($a{url} // undef),
        } ],
    );
}

sub _lines_common (%a) {
    my $e = $a{event};
    my @lines = ($e->{title} // '(no title)', when_line(start => $a{start}, end => $a{end}, all_day => $e->{all_day}, zone => $e->{timezone}));
    push @lines, 'Repeats.' if $e->{rrule};
    if (defined $e->{location} && length $e->{location}) {
        push @lines, "Where: $e->{location}";
        my $q = $e->{location} =~ s/\s+/ /gr =~ s/^\s+|\s+$//gr;
        $q =~ s/([^A-Za-z0-9\-._~ ])/sprintf('%%%02X', ord $1)/ge; $q =~ tr/ /+/;
        push @lines, "Map: https://www.google.com/maps/search/?api=1&query=$q";
    }
    push @lines, "Organizer: $a{organizer}";
    push @lines, '', substr($e->{description} =~ s/\r//gr, 0, 2000) if defined $e->{description} && $e->{description} =~ /\S/;
    return @lines;
}

# Who else is asked, as one line: 'Also invited: ann@example.com (accepted), bob@example.com'.
sub _guests_line (%a) {
    my @others = grep { lc($_->{email}) ne lc($a{attendee}{email} // '') } @{ $a{attendees} // [] };
    return () unless @others;
    my @names = map { ($_->{name} // $_->{email}) . (($_->{status} // 'needs-action') ne 'needs-action' ? ' (' . status_word($_->{status}) . ')' : '') } @others[0 .. ($#others < 9 ? $#others : 9)];
    return 'Also invited: ' . join(', ', @names) . (@others > 10 ? ', and ' . (@others - 10) . ' more' : '');
}

# The invitation (new, changed, or back on). payload: reason invited|changed|restored,
# changed => [ 'time', 'place', 'details', ... ].
sub request_message (%a) {
    my $e = $a{event};
    my $p = $a{payload} // {};
    my $reason = $p->{reason} // 'invited';
    my $who = $a{organizer};
    my $short = _short_when($a{start}, $e->{all_day});
    my $subject = $reason eq 'changed'  ? "Updated invitation: $e->{title} @ $short ($who)"
                : $reason eq 'restored' ? "Invitation again: $e->{title} @ $short ($who)"
                :                         "Invitation: $e->{title} @ $short ($who)";
    my @lines;
    if ($reason eq 'changed') {
        my @c = @{ $p->{changed} // [] };
        my $what = @c ? join(' and ', map { $_ eq 'time' ? 'the time' : $_ eq 'place' ? 'the place' : $_ eq 'details' ? 'the details' : $_ } @c) : 'something';
        push @lines, "$who changed this event: $what.", (grep { /\A(?:time|place)\z/ } @c) ? 'Please answer again.' : 'Your answer stands.', '';
    }
    elsif ($reason eq 'restored') { push @lines, "$who put this event back on. Please answer again.", '' }
    else { push @lines, "$who invited you to this event.", '' }
    push @lines, _lines_common(%a);
    my $l = _guests_line(%a); push @lines, '', $l if $l;
    my $t = $a{attendee}{token};
    push @lines, '', 'Are you coming?',
        "  Yes:    $a{base_url}/i/$t?answer=accepted",
        "  Maybe:  $a{base_url}/i/$t?answer=tentative",
        "  No:     $a{base_url}/i/$t?answer=declined",
        '', "Open the invitation (and add it to your calendar): $a{base_url}/i/$t";
    push @lines, '', 'If your mail program shows Yes / Maybe / No buttons of its own, those work too.';
    return { subject => $subject, body => join("\n", @lines) . "\n" };
}

# The event is off, or this person was taken off the list.
sub cancel_message (%a) {
    my $e = $a{event};
    my $p = $a{payload} // {};
    my $who = $a{organizer};
    my $short = _short_when($a{start}, $e->{all_day});
    my $removed = ($p->{reason} // '') eq 'removed';
    my $subject = $removed ? "No longer invited: $e->{title} @ $short ($who)" : "Cancelled: $e->{title} @ $short ($who)";
    my @lines = ($removed ? "$who took you off the list for this event." : "$who cancelled this event.", '');
    push @lines, _lines_common(%a);
    push @lines, '', 'Your calendar program should remove it when it reads the attached cancellation.';
    return { subject => $subject, body => join("\n", @lines) . "\n" };
}

# To the organizer: someone answered. payload: attendee, name, status, comment, via.
sub reply_notice_message (%a) {
    my $e = $a{event};
    my $p = $a{payload} // {};
    my $name = (defined $p->{name} && length $p->{name}) ? "$p->{name} ($p->{attendee})" : ($p->{attendee} // 'Someone');
    my $word = status_word($p->{status});
    my $short = _short_when($a{start}, $e->{all_day});
    my $subject = ($p->{status} // '') eq 'tentative' ? "$name might come: $e->{title} @ $short"
                : ucfirst($word) . ": $e->{title} @ $short ($name)";
    my @lines = ("$name $word" . (($p->{status} // '') eq 'tentative' ? ' to' : '') . " \"$e->{title}\".", '');
    push @lines, "They wrote: $p->{comment}", '' if defined $p->{comment} && length $p->{comment};
    push @lines, when_line(start => $a{start}, end => $a{end}, all_day => $e->{all_day}, zone => $e->{timezone});
    if (my $c = $a{counts}) {
        push @lines, '', 'So far: ' . join(', ', map { "$c->{$_->[0]} $_->[1]" } grep { $c->{ $_->[0] } } ([accepted => 'yes'], [tentative => 'maybe'], [declined => 'no'], [waiting => 'waiting']))
            . " of $c->{total} invited.";
    }
    push @lines, '', 'Open this event: ' . ($a{url} // "$a{base_url}/");
    return { subject => $subject, body => join("\n", @lines) . "\n" };
}

1;
