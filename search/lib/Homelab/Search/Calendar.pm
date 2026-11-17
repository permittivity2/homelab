package Homelab::Search::Calendar;
use Mojo::Base -base, -signatures;

# The calendar as a source of the site search (post-cutover #90).
#
# NOT INDEXED. Events are asked for live, on the person's own behalf, through
# the gateway: GET /api/v1/calendar/search with the bearer token the session
# already holds. That keeps ONE copy of the calendar's rules -- whose events,
# which shares, which account has AI on for "related by meaning" -- and no
# copy of the rows in the search schema. A failure here costs the page its
# Calendar section and nothing else: the mail and file results render as
# they always have.
#
# Two calls, because they cost differently. The literal part is one indexed
# query on the calendar's side and the page waits for it. The related part is
# one model call, so the page asks for it AFTER it has rendered (see
# /calendar/related in App.pm), and homelab-cli asks for both at once.

use Mojo::UserAgent;
use Mojo::URL;
use Time::Local qw(timegm);

has 'api_base';
has 'log';
has ua => sub { Mojo::UserAgent->new->connect_timeout(3)->inactivity_timeout(30) };
has literal_timeout => 5;
has related_timeout => 25;

sub ready ($self) { return length($self->api_base // '') ? 1 : 0 }

# search($jwt, $q, related => 0|1) ->
#   { ok => 1, events => [hit...], related => [hit...], related_note => text|undef,
#     ai => { available => 0|1, enabled => 0|1 } }
#   { ok => 1, events => [], related => [], skipped => 1 }   -- under two characters
#   { ok => 0, error => 'denied' | 'unavailable' | 'error', status => N }
sub search ($self, $jwt, $q, %o) {
    $q = ($q // '') =~ s/\A\s+|\s+\z//gr;
    return { ok => 1, events => [], related => [], skipped => 1 } if length $q < 2;
    return { ok => 0, error => 'unavailable', status => 0 } unless $self->ready && length($jwt // '');

    my $url = Mojo::URL->new($self->api_base . '/api/v1/calendar/search')
        ->query(q => $q, ($o{related} ? (related => 1) : ()));
    my $tx = eval {
        $self->ua->request_timeout($o{related} ? $self->related_timeout : $self->literal_timeout)
            ->get($url, { Authorization => "Bearer $jwt", Accept => 'application/json' });
    };
    my $code = ($tx && $tx->res) ? ($tx->res->code // 0) : 0;
    if (!$code) {
        my $err = ($tx && $tx->error) ? ($tx->error->{message} // 'no response') : ($@ || 'no response');
        $self->_warn("calendar: search unreachable: $err");
        return { ok => 0, error => 'unavailable', status => 0 };
    }
    return { ok => 0, error => 'denied', status => $code } if $code == 401 || $code == 403;
    unless ($code == 200) {
        $self->_warn("calendar: search answered $code");
        return { ok => 0, error => ($code >= 500 ? 'unavailable' : 'error'), status => $code };
    }
    my $j = eval { $tx->res->json };
    unless (ref $j eq 'HASH' && ref($j->{events} // []) eq 'ARRAY') {
        $self->_warn('calendar: search answered something that is not a result');
        return { ok => 0, error => 'error', status => $code };
    }
    my $ai = ref $j->{ai} eq 'HASH' ? $j->{ai} : {};
    return {
        ok      => 1,
        events  => [ map { _hit($_) } grep { ref eq 'HASH' } @{ $j->{events} // [] } ],
        related => [ map { _hit($_) } grep { ref eq 'HASH' } @{ ref $j->{related} eq 'ARRAY' ? $j->{related} : [] } ],
        related_note => (defined $j->{related_note} && length $j->{related_note}) ? "$j->{related_note}" : undef,
        ai => { available => ($ai->{available} ? 1 : 0), enabled => ($ai->{enabled} ? 1 : 0) },
    };
}

sub _warn ($self, $msg) { $self->log->warn($msg) if $self->log; return }

# WHICH SOURCES a search covers, as one table. Ticks from the page's form
# win; without any, the wire's words. Returns ($source, $calendar) where
# $source is the mail/files part in the words the wire has always used --
# both | mail | drive -- plus one new word, `calendar`, meaning neither, and
# $calendar is 0 or 1.
#
#   ticks                          source     calendar
#   none                           both       1        everything
#   mail / drive / mail+drive      that       0        narrowed stays narrowed
#   calendar                       calendar   1        events only
#   mail+calendar, drive+calendar  that       1
#   all three                      both       1
#
#   wire `source`  both (default) -> mail and files, calendar on unless calendar=0
#                  mail | drive   -> that one, calendar off unless calendar=1
#                  calendar       -> events only
#                  all            -> both with the calendar on (a plainer word)
sub sources ($ticks, $source, $calendar) {
    my %t = map { $_ => 1 } grep { defined && /\A(?:mail|drive|calendar)\z/ } @{ $ticks // [] };
    if (keys %t) {
        my ($m, $d, $cal) = @t{qw(mail drive calendar)};
        my $src = ($m && $d) ? 'both' : $m ? 'mail' : $d ? 'drive' : 'calendar';
        return ($src, ($cal || !($m || $d)) ? 1 : 0);
    }
    $source = 'both' unless defined $source && $source =~ /\A(?:both|mail|drive|calendar|all)\z/;
    my $default = ($source eq 'mail' || $source eq 'drive') ? 0 : 1;
    $source = 'both' if $source eq 'all';
    my $cal = (defined $calendar && $calendar =~ /\A[01]\z/) ? $calendar + 0 : $default;
    $cal = 1 if $source eq 'calendar';
    return ($source, $cal);
}

# One event as the page and the CLI see it: the calendar's own fields, the
# link into the calendar (kept only when it is a web address), and `when`,
# the day and time as a person reads them.
sub _hit ($e) {
    my %h = (
        id           => ($e->{id} // 0) + 0,
        title        => "" . ($e->{title} // ''),
        location     => "" . ($e->{location} // ''),
        start        => "" . ($e->{start} // ''),
        end          => "" . ($e->{end} // ''),
        all_day      => ($e->{all_day} ? 1 : 0),
        is_recurring => ($e->{is_recurring} ? 1 : 0),
        calendar     => (ref $e->{calendar} eq 'HASH') ? "" . ($e->{calendar}{name} // '') : '',
        url          => "" . ($e->{url} // ''),
    );
    $h{url} = '' unless $h{url} =~ m{\Ahttps?://}i;
    $h{why} = "$e->{why}" if defined $e->{why} && length $e->{why};
    $h{when} = when_text($h{start}, $h{end}, $h{all_day});
    return \%h;
}

my @DOW = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MON = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# '2026-11-16T13:30:00' or '2026-11-16' -> [Y, M, D, h, m] or undef.
sub _parts ($s) {
    return undef unless defined $s && $s =~ /\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/;
    return [ $1 + 0, $2 + 0, $3 + 0, (defined $4 ? $4 + 0 : undef), (defined $5 ? $5 + 0 : undef) ];
}

sub _day_label ($p, $this_year) {
    my $epoch = eval { timegm(0, 0, 12, $p->[2], $p->[1] - 1, $p->[0]) };
    my $dow   = defined $epoch ? $DOW[ (gmtime $epoch)[6] ] . ', ' : '';
    my $label = $dow . $MON[ $p->[1] - 1 ] . ' ' . $p->[2];
    $label .= ', ' . $p->[0] if $p->[0] != $this_year;
    return $label;
}

sub _clock ($p) {
    my ($h, $m) = ($p->[3], $p->[4]);
    my $ampm = $h >= 12 ? 'PM' : 'AM';
    my $h12  = $h % 12 || 12;
    return (sprintf('%d:%02d', $h12, $m), $ampm);
}

# The calendar sends wall clocks in the viewer's own zone; the end of an
# all-day event is the day AFTER its last day, as calendars store it.
sub when_text ($start, $end, $all_day = 0, $this_year = (localtime)[5] + 1900) {
    my $s = _parts($start) or return '';
    my $e = _parts($end);
    if ($all_day || !defined $s->[3]) {
        my $last = $e ? _parts(_days_before($e)) : undef;
        return _day_label($s, $this_year) . ' (all day)'
            if !$last || join('-', @$last[0 .. 2]) le join('-', @$s[0 .. 2]);
        return _day_label($s, $this_year) . ' – ' . _day_label($last, $this_year) . ' (all day)';
    }
    my ($sc, $sa) = _clock($s);
    return _day_label($s, $this_year) . " · $sc $sa" unless $e && defined $e->[3];
    my ($ec, $ea) = _clock($e);
    if (join('-', @$e[0 .. 2]) eq join('-', @$s[0 .. 2])) {
        return _day_label($s, $this_year) . ($sa eq $ea ? " · $sc – $ec $ea" : " · $sc $sa – $ec $ea");
    }
    return _day_label($s, $this_year) . ", $sc $sa – " . _day_label($e, $this_year) . ", $ec $ea";
}

# 'YYYY-MM-DD' of the day before the one given (as parts).
sub _days_before ($p) {
    my $epoch = eval { timegm(0, 0, 12, $p->[2], $p->[1] - 1, $p->[0]) };
    return '' unless defined $epoch;
    my @t = gmtime($epoch - 86400);
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

1;
