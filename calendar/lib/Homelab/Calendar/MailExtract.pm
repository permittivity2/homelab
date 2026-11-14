package Homelab::Calendar::MailExtract;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use DateTime;
use Homelab::Calendar::Recurrence qw(local_dt wall_string);

our @EXPORT_OK = qw(guess clean_subject);

# The plain parse: what the pre-filled event looks like WITHOUT AI, from the
# subject, the Date header and date/time phrases in the text. Best effort by
# design -- the person sees the form and corrects it; the AI proposal (phase
# 4) replaces this when they have consented.

my %MONTH = (jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6, jul => 7, aug => 8, sep => 9, sept => 9, oct => 10, nov => 11, dec => 12);
my %WDAY  = (sunday => 7, monday => 1, tuesday => 2, wednesday => 3, thursday => 4, friday => 5, saturday => 6,
             sun => 7, mon => 1, tue => 2, tues => 2, wed => 3, thu => 4, thur => 4, thurs => 4, fri => 5, sat => 6);

# "Re: Fwd: RE: Lunch" -> "Lunch"
sub clean_subject ($s) {
    my $t = $s // '';
    $t =~ s/\s+/ /g;
    1 while $t =~ s/^\s*(?:re|fwd?|fw|aw|wg|tr|sv)\s*(?:\[\d+\])?\s*:\s*//i;
    $t =~ s/^\s*\[[^\]]{1,40}\]\s*//;    # a list tag
    $t =~ s/^\s+|\s+\z//g;
    return $t;
}

# A clock phrase -> (hour, minute) in 24h, or ().
sub _clock ($h, $m, $ampm) {
    $m //= 0;
    return () if $h > 23 || $m > 59;
    if (defined $ampm) {
        my $pm = $ampm =~ /^p/i;
        return () if $h == 0 || $h > 12;
        $h = $h % 12 + ($pm ? 12 : 0);
    }
    return ($h, $m);
}

# guess(subject => ..., text => ..., date_header => ..., zone => ..., now => DateTime)
#  -> { title, all_day, start, end (wall strings), location, description, source }
sub guess (%a) {
    my $zone = $a{zone} // 'America/Chicago';
    my $now  = $a{now} // DateTime->now(time_zone => $zone);
    $now = $now->clone->set_time_zone($zone);
    my $text = ($a{subject} // '') . "\n" . ($a{text} // '');
    $text =~ s/\r//g;

    my ($y, $mo, $d, $source);
    my $hay = substr($text, 0, 20000);
    # 2026-11-20, 11/20/2026, 11/20
    if ($hay =~ /\b(20\d{2})-(\d{1,2})-(\d{1,2})\b/)                      { ($y, $mo, $d, $source) = ($1, $2, $3, 'iso date') }
    elsif ($hay =~ m{\b(\d{1,2})/(\d{1,2})(?:/(20\d{2}|\d{2}))?\b})      { ($mo, $d, $y, $source) = ($1, $2, $3, 'numeric date'); $y = defined $y ? ($y < 100 ? 2000 + $y : $y) : undef }
    # November 20(th)(, 2026) / Nov 20 / 20 November
    elsif ($hay =~ /\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(20\d{2}))?\b/i) { ($mo, $d, $y, $source) = ($MONTH{lc $1}, $2, $3, 'month name') }
    elsif ($hay =~ /\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?(?:,?\s+(20\d{2}))?\b/i) { ($d, $mo, $y, $source) = ($1, $MONTH{lc $2}, $3, 'day month') }
    # "next Friday" / "on Tuesday" / "tomorrow"
    elsif ($hay =~ /\btomorrow\b/i) { my $t = $now->clone->add(days => 1); ($y, $mo, $d, $source) = ($t->year, $t->month, $t->day, 'tomorrow') }
    elsif ($hay =~ /\b(?:next\s+|this\s+|on\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues?|wed|thur?s?|fri|sat)\b/i) {
        my $want = $WDAY{lc $1};
        my $t = $now->clone; my $n = 0;
        $t->add(days => 1), $n++ while $t->day_of_week != $want || $n == 0 && 0;
        ($y, $mo, $d, $source) = ($t->year, $t->month, $t->day, 'weekday');
    }
    my $date;
    if ($mo && $d) {
        $y //= $now->year;
        $date = eval { DateTime->new(year => $y, month => $mo, day => $d, time_zone => 'floating') };
        # A month/day with no year that is already well past: they mean next year.
        if ($date && !$a{explicit_year} && $hay !~ /\b20\d{2}\b/ && $date->clone->set_time_zone($zone) < $now->clone->subtract(days => 60)) {
            $date = eval { DateTime->new(year => $y + 1, month => $mo, day => $d, time_zone => 'floating') };
        }
    }
    $date //= $now->clone->add(days => 1)->truncate(to => 'day');
    $source //= 'default: tomorrow';

    # Times: "3pm", "3:30 PM", "15:30", "from 2 to 4 pm", "2-4pm", "at 10".
    my ($sh, $sm, $eh, $em);
    if ($hay =~ /\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\s*(?:-|–|to|until|till)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)\b/i) {
        my ($h1, $m1, $ap1, $h2, $m2, $ap2) = ($1, $2, $3, $4, $5, $6);
        $ap1 //= $ap2;
        ($sh, $sm) = _clock($h1, $m1, $ap1); ($eh, $em) = _clock($h2, $m2, $ap2);
    }
    elsif ($hay =~ /\b(?:at|@|from)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\b/i) {
        my ($h, $m, $ap) = ($1, $2, $3);
        ($sh, $sm) = _clock($h, $m, $ap);
        # "at 3" with no am/pm is an afternoon in ordinary speech; "at 10" is not.
        $sh += 12 if defined $sh && !defined $ap && $sh >= 1 && $sh <= 7;
    }
    elsif ($hay =~ /\b(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?\b/i) { ($sh, $sm) = _clock($1, $2, $3) }
    elsif ($hay =~ /\b(\d{1,2})\s*(am|pm)\b/i) { ($sh, $sm) = _clock($1, 0, $2) }
    elsif ($hay =~ /\bnoon\b/i) { ($sh, $sm) = (12, 0) }

    my ($title) = clean_subject($a{subject} // '');
    $title = 'Event from email' unless length $title;
    my %g = (title => substr($title, 0, 300), location => undef, description => undef, source => $source);
    my ($loc) = $hay =~ /\b(?:location|where|venue|address)\s*:\s*([^\n]{2,120})/i;
    $g{location} = $loc =~ s/\s+\z//r if defined $loc;
    if (defined $sh) {
        my $start = local_dt($date->year, $date->month, $date->day, $sh, $sm, 0, $zone, 1);
        my $end = defined $eh ? local_dt($date->year, $date->month, $date->day, $eh, $em, 0, $zone, 1) : $start->clone->add(hours => 1);
        $end = $start->clone->add(hours => 1) if $end <= $start;
        @g{qw(all_day start end)} = (0, wall_string($start), wall_string($end));
    }
    else {
        @g{qw(all_day start end)} = (1, $date->ymd, $date->clone->add(days => 1)->ymd);
    }
    return \%g;
}

1;
