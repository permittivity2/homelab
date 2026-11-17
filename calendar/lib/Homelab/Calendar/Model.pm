package Homelab::Calendar::Model;
use Mojo::Base -base, -signatures;
use DateTime;
use Mojo::JSON ();
use Mojo::Util ();
use Homelab::Calendar::Recurrence qw(
    validate_zone parse_wall wall_string occurrences recurrence_bound build_rrule parse_rrule
    rrule_until_before rrule_strip_end occurrences_before shift_rrule
);
use Homelab::Calendar::Access qw(calendar_permission event_permission share_is_live);

# Everything that touches the calendar schema. Controllers call this and
# Access.pm; nothing else runs SQL. Dates cross this boundary as DateTime
# objects (in), wall-clock strings + a zone (from the browser) or DateTime
# objects (out); Postgres rows carry their timestamps as text, which is parsed
# once here (_dt) and nowhere else.
#
# Every write that a person asked for goes through one of the explicit methods
# below, which take the row the caller has ALREADY checked permission on
# (Access.pm). This module trusts its caller about who may do what; the
# controllers are where "may this viewer" is asked, in one place per route.

has 'pg';
has uid_domain => 'calendar.example';
has default_zone => 'America/Chicago';

my @EVENT_FIELDS = qw(title description location all_day starts_at ends_at start_date end_date timezone rrule recurrence_end color pinned);

sub db ($self) { return $self->pg->db }

# ----------------------------------------------------------------- utilities

# Postgres timestamptz text -> DateTime (UTC). Mojo::Pg hands back text such as
# '2026-11-14 15:00:00+00' or with fractional seconds.
sub _dt ($s, $zone = 'UTC') {
    return undef unless defined $s && length $s;
    return $s->clone->set_time_zone($zone) if ref $s;
    my ($y, $m, $d, $H, $M, $S, $frac, $sign, $oh, $om) =
        $s =~ /\A(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:([+-])(\d{2})(?::?(\d{2}))?)?/
        or return undef;
    my $dt = DateTime->new(year => $y, month => $m, day => $d, hour => $H, minute => $M, second => $S, time_zone => 'UTC');
    if ($sign) {
        my $off = ($oh * 3600 + ($om // 0) * 60) * ($sign eq '-' ? -1 : 1);
        $dt->subtract(seconds => $off);
    }
    return $dt->set_time_zone($zone);
}

# Two timestamptz texts (any offsets) name the same instant.
sub _same_instant ($a, $b) {
    my ($x, $y) = (_dt($a), _dt($b));
    return 1 if !$x && !$y;
    return 0 unless $x && $y;
    return $x->epoch == $y->epoch ? 1 : 0;
}

sub _date ($s) {
    return undef unless defined $s && length $s;
    my ($y, $m, $d) = $s =~ /\A(\d{4})-(\d{2})-(\d{2})/ or return undef;
    return DateTime->new(year => $y, month => $m, day => $d, time_zone => 'floating');
}

sub _random_hex ($bytes) {
    open my $fh, '<:raw', '/dev/urandom' or die "cannot read /dev/urandom: $!\n";
    read($fh, my $buf, $bytes) == $bytes or die "short read from /dev/urandom\n";
    close $fh;
    return unpack 'H*', $buf;
}

sub new_uid ($self) { return _random_hex(16) . '@' . $self->uid_domain }
sub new_token ($self) { return _random_hex(32) }

sub _norm ($e) { return lc($e // '') }

# A share row, with its expiry as an epoch so Access.pm can compare it.
sub _share_row ($row) {
    return undef unless $row;
    my $exp = _dt($row->{expires_at});
    $row->{expires_at_epoch} = $exp ? $exp->epoch : undef;
    return $row;
}

# ---------------------------------------------------------------- calendars

sub calendar ($self, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return $self->db->query('SELECT * FROM calendar.calendars WHERE id = ? AND deleted_at IS NULL', $id)->hash;
}

# Every calendar this account may see: its own plus those shared to it, each
# with the viewer's permission and whether it is ticked in the sidebar.
sub calendars_for ($self, $email) {
    my $me = _norm($email);
    my $own = $self->db->query(
        'SELECT * FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL ORDER BY is_default DESC, position, lower(name), id', $me,
    )->hashes->to_array;
    my $shares = $self->viewer_calendar_shares($me);
    my %shared_ids = map { $_->{calendar_id} => 1 } @$shares;
    my @shared;
    if (%shared_ids) {
        my $rows = $self->db->query(
            'SELECT * FROM calendar.calendars WHERE id = ANY(?) AND deleted_at IS NULL ORDER BY lower(name), id', [ sort keys %shared_ids ],
        )->hashes->to_array;
        @shared = @$rows;
    }
    my %visible = map { $_->{calendar_id} => $_->{visible} }
        @{ $self->db->query('SELECT calendar_id, visible FROM calendar.calendar_visibility WHERE user_email = ?', $me)->hashes->to_array };
    for my $c (@$own)   { $c->{permission} = 'owner' }
    for my $c (@shared) { $c->{permission} = calendar_permission($me, $c, $shares) }
    @shared = grep { $_->{permission} } @shared;
    for my $c (@$own, @shared) { $c->{visible} = exists $visible{ $c->{id} } ? ($visible{ $c->{id} } ? 1 : 0) : 1 }
    return { own => $own, shared => \@shared };
}

# The account's default calendar, created on first visit.
sub ensure_default_calendar ($self, $email, $zone = undef) {
    my $me = _norm($email);
    my $row = $self->db->query(
        'SELECT * FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL ORDER BY is_default DESC, id LIMIT 1', $me,
    )->hash;
    return $row if $row;
    $zone = $self->default_zone unless validate_zone($zone);
    return $self->db->query(
        q{INSERT INTO calendar.calendars (owner_email, name, color, timezone, is_default) VALUES (?, 'My calendar', '#6f94b8', ?, TRUE) RETURNING *},
        $me, $zone,
    )->hash;
}

sub create_calendar ($self, $email, %f) {
    my $zone = validate_zone($f{timezone}) ? $f{timezone} : $self->default_zone;
    my $pos = $self->db->query('SELECT COALESCE(MAX(position), 0) + 1 FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL', _norm($email))->array->[0];
    return $self->db->query(
        q{INSERT INTO calendar.calendars (owner_email, name, color, description, timezone, position) VALUES (?, ?, ?, ?, ?, ?) RETURNING *},
        _norm($email), $f{name}, $f{color} // '#6f94b8', $f{description}, $zone, $pos,
    )->hash;
}

sub update_calendar ($self, $id, %f) {
    my (@set, @vals);
    for my $k (qw(name color description timezone position)) {
        next unless exists $f{$k};
        push @set, "$k = ?"; push @vals, $f{$k};
    }
    return $self->calendar($id) unless @set;
    return $self->db->query('UPDATE calendar.calendars SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? AND deleted_at IS NULL RETURNING *', @vals, $id)->hash;
}

# Soft delete; the default calendar passes its flag to the next one so an
# account always has one. Events stay (deleted with their calendar's row by
# the deleted_at test on the calendar), shares stop answering.
sub delete_calendar ($self, $cal) {
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('UPDATE calendar.calendars SET deleted_at = NOW(), is_default = FALSE, updated_at = NOW() WHERE id = ?', $cal->{id});
    $db->query('UPDATE calendar.shares SET revoked_at = NOW() WHERE calendar_id = ? AND revoked_at IS NULL', $cal->{id});
    if ($cal->{is_default}) {
        $db->query(q{UPDATE calendar.calendars SET is_default = TRUE WHERE id = (
            SELECT id FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL ORDER BY position, id LIMIT 1)}, _norm($cal->{owner_email}));
    }
    $tx->commit;
    return 1;
}

sub set_visibility ($self, $email, $cal_id, $visible) {
    $self->db->query(
        q{INSERT INTO calendar.calendar_visibility (user_email, calendar_id, visible) VALUES (?, ?, ?)
          ON CONFLICT (user_email, calendar_id) DO UPDATE SET visible = EXCLUDED.visible},
        _norm($email), $cal_id, $visible ? 1 : 0,
    );
    return 1;
}

# ------------------------------------------------------------------- access

# Live shares to this viewer, by kind. Fetched once per request and handed to
# Access.pm with the rows it is asked about.
sub viewer_calendar_shares ($self, $email) {
    my $rows = $self->db->query(
        q{SELECT * FROM calendar.shares WHERE calendar_id IS NOT NULL AND lower(shared_with_email) = ?
            AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())}, _norm($email),
    )->hashes->to_array;
    return [ map { _share_row($_) } @$rows ];
}

sub viewer_event_shares ($self, $email) {
    my $rows = $self->db->query(
        q{SELECT * FROM calendar.shares WHERE event_id IS NOT NULL AND lower(shared_with_email) = ?
            AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())}, _norm($email),
    )->hashes->to_array;
    return [ map { _share_row($_) } @$rows ];
}

sub permission_for_calendar ($self, $email, $cal) {
    return undef unless $cal;
    return 'owner' if _norm($cal->{owner_email}) eq _norm($email);
    return calendar_permission(_norm($email), $cal, $self->viewer_calendar_shares($email));
}

sub permission_for_event ($self, $email, $event, $cal = undef) {
    return undef unless $event;
    $cal //= $self->calendar($event->{calendar_id}) or return undef;
    return 'owner' if _norm($cal->{owner_email}) eq _norm($email);
    return event_permission(_norm($email), $event, $cal, $self->viewer_calendar_shares($email), $self->viewer_event_shares($email));
}

# ------------------------------------------------------------------- events

sub event ($self, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return $self->db->query('SELECT * FROM calendar.events WHERE id = ? AND deleted_at IS NULL', $id)->hash;
}

# The live event carrying an iCalendar UID (an import updates it), and
# whether a UID is in use at all (deleted events keep theirs).
sub event_by_uid ($self, $uid) {
    return undef unless defined $uid && length $uid;
    return $self->db->query('SELECT * FROM calendar.events WHERE uid = ? AND deleted_at IS NULL', $uid)->hash;
}
sub uid_taken ($self, $uid) {
    return $self->db->query('SELECT 1 FROM calendar.events WHERE uid = ?', $uid)->array ? 1 : 0;
}

sub exceptions_for ($self, $event_id) {
    return $self->db->query('SELECT * FROM calendar.event_exceptions WHERE event_id = ? ORDER BY recurrence_id', $event_id)->hashes->to_array;
}

# The event's first occurrence and its end as DateTime objects in its zone.
sub event_start ($self, $e) {
    return $e->{all_day}
        ? _date($e->{start_date})->set_time_zone($e->{timezone})
        : _dt($e->{starts_at}, $e->{timezone});
}
sub event_end ($self, $e) {
    return $e->{all_day}
        ? _date($e->{end_date})->set_time_zone($e->{timezone})
        : _dt($e->{ends_at}, $e->{timezone});
}

# Turns the editor's input into column values, or dies with a message for the
# person. Input (all optional except title/start on create):
#   title description location color all_day
#   start end        wall-clock strings ('2026-11-14T09:00:00', or dates)
#   timezone         IANA zone the wall clock is in
#   repeat           undef/'' (none) | a form for build_rrule | an RRULE string
# $base is the existing event row on an update (its values fill in the gaps).
sub _event_values ($self, $input, $base = undef, $default_zone = undef) {
    my %v;
    my $zone = $input->{timezone} // $base->{timezone} // $default_zone // $self->default_zone;
    die "Unknown time zone '$zone'.\n" unless validate_zone($zone);
    $v{timezone} = $zone;
    # 0.4.0 (#89): the zone the wall clocks given here are written in, when it
    # is not the event's own (a drag in a grid shown in another zone). The
    # event keeps its zone; only the instant moves.
    my $tz_in = $input->{times_zone} // $zone;
    die "Unknown time zone '$tz_in'.\n" unless validate_zone($tz_in);

    for my $k (qw(title description location color)) {
        $v{$k} = exists $input->{$k} ? $input->{$k} : $base->{$k};
    }
    $v{title} = defined $v{title} ? $v{title} =~ s/\A\s+|\s+\z//gr : '';
    die "Give the event a title.\n" unless length $v{title};
    die "The title is too long (300 characters at most).\n" if length $v{title} > 300;
    die "The description is too long (20000 characters at most).\n" if defined $v{description} && length $v{description} > 20000;
    die "The location is too long (500 characters at most).\n" if defined $v{location} && length $v{location} > 500;
    for my $k (qw(description location color)) { $v{$k} = undef if defined $v{$k} && !length $v{$k} }
    die "The colour must look like #1a2b3c.\n" if defined $v{color} && $v{color} !~ /\A#[0-9a-fA-F]{6}\z/;

    my $all_day = exists $input->{all_day} ? ($input->{all_day} ? 1 : 0) : ($base ? ($base->{all_day} ? 1 : 0) : 0);
    $v{all_day} = $all_day;
    # Pinned (#89): show this event in its own zone wherever the viewer is. Display only.
    $v{pinned} = exists $input->{pinned} ? ($input->{pinned} ? 1 : 0) : ($base ? ($base->{pinned} ? 1 : 0) : 0);

    my ($start, $end);
    if (defined $input->{start} && length $input->{start}) {
        $start = parse_wall($input->{start}, $tz_in) or die "The start must look like 2026-11-14T09:00:00.\n";
        $start->set_time_zone($zone) if $tz_in ne $zone;
    }
    elsif ($base) {
        $start = $self->event_start($base)->set_time_zone($zone);
    }
    die "Give the event a start.\n" unless $start;
    if (defined $input->{end} && length $input->{end}) {
        $end = parse_wall($input->{end}, $tz_in) or die "The end must look like 2026-11-14T10:00:00.\n";
        $end->set_time_zone($zone) if $tz_in ne $zone;
    }
    elsif ($base && !(defined $input->{start} && length $input->{start})) {
        $end = $self->event_end($base)->set_time_zone($zone);
    }

    if ($all_day) {
        $start->truncate(to => 'day');
        $end = $end ? $end->truncate(to => 'day') : $start->clone->add(days => 1);
        $end = $start->clone->add(days => 1) if $end <= $start;
        die "An all-day event cannot run more than 365 days.\n" if $end->delta_days($start)->in_units('days') > 365;
        $v{start_date} = $start->ymd;
        $v{end_date}   = $end->ymd;
    }
    else {
        $end //= $start->clone->add(hours => 1);
        die "The end must be after the start.\n" if $end <= $start;
        die "An event cannot run more than 31 days; make it repeat instead.\n" if $end->epoch - $start->epoch > 31 * 86400;
        $v{start_date} = undef;
        $v{end_date}   = undef;
    }
    $v{starts_at} = $start->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    $v{ends_at}   = $end->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');

    # Repetition: nothing, a form, or an RRULE string to keep as is.
    my $rrule;
    if (exists $input->{repeat}) {
        my $r = $input->{repeat};
        if (!defined $r || (!ref $r && !length $r) || (ref $r eq 'HASH' && !($r->{freq} // ''))) { $rrule = undef }
        elsif (ref $r eq 'HASH') { $rrule = build_rrule($r, $start) }
        else {
            die "That repeat rule is not one this calendar can show.\n" unless parse_rrule($r, $zone);
            $rrule = $r;
        }
    }
    else { $rrule = $base ? $base->{rrule} : undef }
    $v{rrule} = $rrule;
    $v{recurrence_end} = undef;
    if (defined $rrule) {
        my $bound = recurrence_bound($start, $rrule);
        $v{recurrence_end} = $bound ? $bound->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00') : undef;
    }
    return \%v;
}

sub create_event ($self, $cal, $email, $input) {
    my $v = $self->_event_values($input, undef, $cal->{timezone});
    my @cols = (@EVENT_FIELDS, qw(calendar_id uid created_by_email));
    # An import (#82) may bring the event's own iCalendar UID, so the same
    # file imported twice updates rather than duplicates; a UID already here
    # (live or deleted: the column is unique) gets a fresh one.
    my $uid = (defined $input->{uid} && $input->{uid} =~ /\A[A-Za-z0-9@._+:-]{1,255}\z/ && !$self->uid_taken($input->{uid}))
        ? $input->{uid} : $self->new_uid;
    my @vals = ((map { $v->{$_} } @EVENT_FIELDS), $cal->{id}, $uid, _norm($email));
    return $self->db->query(
        'INSERT INTO calendar.events (' . join(', ', @cols) . ') VALUES (' . join(', ', ('?') x @cols) . ') RETURNING *', @vals,
    )->hash;
}

# update_event($event, $input, scope => 'all'|'this'|'following', recurrence_id => DateTime)
# Returns the row that now carries the change (the master, or the new series).
sub update_event ($self, $event, $input, %o) {
    my $scope = $o{scope} // 'all';
    my $rid   = $o{recurrence_id};
    $scope = 'all' unless $event->{rrule} && $rid;

    if ($scope eq 'this') {
        return $self->_write_exception($event, $rid, $input, 0);
    }
    if ($scope eq 'following') {
        return $self->_split_series($event, $rid, $input);
    }

    # The whole event (or series). A drag of one occurrence with "all events"
    # moves the series by the same amount: the master's start shifts by the
    # difference between that occurrence and where it was dropped.
    my %in = %$input;
    my $zone = $in{times_zone} // $in{timezone} // $event->{timezone};   # the zone the dropped clock is written in
    if ($rid && defined $in{start} && length $in{start}) {
        my $new_start = parse_wall($in{start}, $zone) or die "The start must look like 2026-11-14T09:00:00.\n";
        my $old = $rid->clone->set_time_zone($zone);
        my $master_start = $self->event_start($event)->set_time_zone($zone);
        my $master_end   = $self->event_end($event)->set_time_zone($zone);
        my $days = _day_delta($old, $new_start);
        my $secs = ($new_start->hour * 3600 + $new_start->minute * 60 + $new_start->second)
                 - ($old->hour * 3600 + $old->minute * 60 + $old->second);
        my $shifted = $master_start->clone->add(days => $days);
        $shifted = $shifted->clone->add(seconds => $secs) unless $event->{all_day} && !$in{all_day};
        my $dur_days = $master_end->delta_days($master_start)->in_units('days');
        my $new_end;
        if (defined $in{end} && length $in{end}) {
            my $e = parse_wall($in{end}, $zone) or die "The end must look like 2026-11-14T10:00:00.\n";
            $new_end = $shifted->clone->add(seconds => $e->epoch - $new_start->epoch);
        }
        else {
            $new_end = $shifted->clone->add(seconds => $master_end->epoch - $master_start->epoch);
        }
        $in{start} = wall_string($shifted, $event->{all_day} && !exists $in{all_day});
        $in{end}   = wall_string($new_end,  $event->{all_day} && !exists $in{all_day});
        $in{repeat} = shift_rrule($event->{rrule}, $shifted, $days) if $event->{rrule} && !exists $in{repeat} && $days;
    }
    my $v = $self->_event_values(\%in, $event);
    # Instants are compared as instants: the row's text carries the session's
    # offset (UTC in production, but not everywhere), the new value is +00.
    my $time_changed = (grep { ($v->{$_} // '') ne ($event->{$_} // '') } qw(rrule))
                    || !_same_instant($v->{starts_at}, $event->{starts_at}) || !_same_instant($v->{ends_at}, $event->{ends_at})
                    || (($v->{all_day} ? 1 : 0) != ($event->{all_day} ? 1 : 0));
    my @set = map { "$_ = ?" } @EVENT_FIELDS;
    my $db = $self->db;
    my $tx = $db->begin;
    my $row = $db->query('UPDATE calendar.events SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? RETURNING *',
        (map { $v->{$_} } @EVENT_FIELDS), $event->{id})->hash;
    # Moving or re-ruling a series makes its per-occurrence edits meaningless
    # (they key on the old occurrence instants), so they go; a retitle keeps them.
    $db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ?', $event->{id}) if $time_changed && $event->{rrule};
    # Queued reminders key on the old times: a move drops them all (the new
    # time gets its own), a retitle only what has not gone out yet (#79).
    $self->_clear_reminder_queue($db, $event->{id}, $time_changed ? 'all' : 'pending');
    $tx->commit;
    # Invitations (#85): the people asked hear of a change; a new time or
    # place asks them to answer again (SEQUENCE+1), a retitle keeps their answers.
    my $place_changed = ($v->{location} // '') ne ($event->{location} // '');
    my $other_changed = grep { ($v->{$_} // '') ne ($event->{$_} // '') } qw(title description);
    if ($time_changed || $place_changed || $other_changed) {
        my $big = ($time_changed || $place_changed) ? 1 : 0;
        if ($self->notify_attendees($row, bump => $big, reset => $big,
                changed => [ ($time_changed ? 'time' : ()), ($place_changed ? 'place' : ()), ($other_changed ? 'details' : ()) ])) {
            $row->{sequence} = $self->_sequence_of($row->{id});     # the caller's JSON shows the bumped value (0.3.1)
        }
    }
    return $row;
}

sub _sequence_of ($self, $event_id) {
    return $self->db->query('SELECT sequence FROM calendar.events WHERE id = ?', $event_id)->array->[0];
}

sub _day_delta ($from, $to) {
    my $a = DateTime->new(year => $from->year, month => $from->month, day => $from->day, time_zone => 'floating');
    my $b = DateTime->new(year => $to->year, month => $to->month, day => $to->day, time_zone => 'floating');
    my $d = $b->delta_days($a)->in_units('days');
    return $b < $a ? -$d : $d;
}

# One occurrence changed (or cancelled): an exception row keyed by the
# occurrence's original start instant.
sub _write_exception ($self, $event, $rid, $input, $cancelled) {
    my %v = (cancelled => $cancelled ? 1 : 0);
    unless ($cancelled) {
        # Validate through the same rules as a whole event, with the
        # occurrence's own start as the base.
        my $occ = $self->_occurrence_as_event($event, $rid);
        my $vals = $self->_event_values({ %$input, repeat => undef }, $occ);
        $v{$_} = $vals->{$_} for qw(title description location color all_day starts_at ends_at start_date end_date);
        # An override equal to the event's own value is stored as NULL so a
        # later retitle of the series reaches it.
        for my $k (qw(title description location color)) {
            $v{$k} = undef if defined $v{$k} && defined $event->{$k} && $v{$k} eq $event->{$k};
            $v{$k} = undef if !defined $v{$k} && !defined $event->{$k};
        }
    }
    my @cols = sort keys %v;
    my $ridpg = $rid->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query(
        'INSERT INTO calendar.event_exceptions (event_id, recurrence_id, ' . join(', ', @cols) . ') VALUES (?, ?, ' . join(', ', ('?') x @cols) . ')'
        . ' ON CONFLICT (event_id, recurrence_id) DO UPDATE SET ' . join(', ', (map { "$_ = EXCLUDED.$_" } @cols),
            # A cancel wipes an earlier move; an edit after a cancel revives it.
            ($cancelled ? () : map { "$_ = NULL" } grep { !exists $v{$_} } qw(title description location color all_day starts_at ends_at start_date end_date)),
            'updated_at = NOW()'),
        $event->{id}, $ridpg, (map { $v{$_} } @cols),
    );
    # This occurrence moved or went: its queued reminders with it (#79).
    $db->query('DELETE FROM calendar.reminder_queue WHERE event_id = ? AND recurrence_id = ?', $event->{id}, $ridpg);
    $tx->commit;
    # One occurrence changed: the attendees get the series again, with the
    # change inside it (RECURRENCE-ID), SEQUENCE+1, answers kept (#85).
    $self->notify_attendees($self->event($event->{id}), bump => 1, reset => 0, changed => [ $cancelled ? 'one occurrence was removed' : 'one occurrence' ]);
    return $self->event($event->{id});
}

# The master's values with one occurrence's own start/end: the base an
# exception is validated against.
# An import replaces a series' cancelled dates with its file's EXDATEs (0.2.0).
sub clear_cancelled_exceptions ($self, $event_id) {
    $self->db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ? AND cancelled', $event_id);
    return 1;
}

# A series' cancelled dates and changed occurrences, in the shape
# ICS::masters_ics takes (exdates => [DateTime], overrides => [ {...} ]).
sub series_parts ($self, $event) {
    my (@ex, @ov);
    return (\@ex, \@ov) unless $event->{rrule};
    for my $x (@{ $self->exceptions_for($event->{id}) }) {
        my $rid = _dt($x->{recurrence_id}, $event->{timezone});
        if ($x->{cancelled}) { push @ex, $rid; next }
        my $i = $self->_exception_instance($event, $x, $rid);
        push @ov, { recurrence_id => $rid, start => $i->{start}, end => $i->{end}, all_day => $i->{all_day},
            title => $i->{title}, description => $i->{description}, location => $i->{location} };
    }
    return (\@ex, \@ov);
}

sub _occurrence_as_event ($self, $event, $rid) {
    my $start = $rid->clone->set_time_zone($event->{timezone});
    my $dur   = $self->event_end($event)->epoch - $self->event_start($event)->epoch;
    my %occ = %$event;
    if ($event->{all_day}) {
        my $days = int($dur / 86400) || 1;
        $occ{start_date} = $start->ymd;
        $occ{end_date}   = $start->clone->add(days => $days)->ymd;
    }
    else {
        $occ{starts_at} = $start->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
        $occ{ends_at}   = $start->clone->add(seconds => $dur)->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    }
    return \%occ;
}

# "This and following": the series ends before $rid, and a new series starts
# there with the new values. Exceptions from $rid on move to the new series
# when its time is unchanged, and are dropped when it is not.
sub _split_series ($self, $event, $rid, $input) {
    my $zone = $event->{timezone};
    my $master_start = $self->event_start($event);
    # Splitting at the first occurrence is just editing the whole thing.
    return $self->update_event($event, $input, scope => 'all') if $rid->epoch <= $master_start->epoch;

    my $occ = $self->_occurrence_as_event($event, $rid);
    my %in = %$input;
    unless (exists $in{repeat}) {
        my $rule = $event->{rrule};
        if (my $form = parse_rrule($rule, $zone)) {
            if ($form->{count}) {
                my $before = occurrences_before($master_start, $rule, $rid);
                $form->{count} = $form->{count} - $before;
                $form->{count} = 1 if $form->{count} < 1;
                $rule = build_rrule($form, $rid->clone->set_time_zone($zone));
            }
        }
        $in{repeat} = $rule;
    }
    my $v = $self->_event_values(\%in, $occ);
    my $time_changed = !_same_instant($v->{starts_at}, $occ->{starts_at}) || !_same_instant($v->{ends_at}, $occ->{ends_at})
                    || (($v->{all_day} ? 1 : 0) != ($occ->{all_day} ? 1 : 0));

    my $db = $self->db;
    my $tx = $db->begin;
    my $until_rule = rrule_until_before($event->{rrule}, $rid);
    my $bound = recurrence_bound($master_start, $until_rule);
    $db->query('UPDATE calendar.events SET rrule = ?, recurrence_end = ?, updated_at = NOW() WHERE id = ?',
        $until_rule, ($bound ? $bound->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00') : undef), $event->{id});
    my @cols = (@EVENT_FIELDS, qw(calendar_id uid created_by_email));
    my $new = $db->query(
        'INSERT INTO calendar.events (' . join(', ', @cols) . ') VALUES (' . join(', ', ('?') x @cols) . ') RETURNING *',
        (map { $v->{$_} } @EVENT_FIELDS), $event->{calendar_id}, $self->new_uid, $event->{created_by_email},
    )->hash;
    my $ridpg = $rid->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    if ($time_changed) {
        $db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ? AND recurrence_id >= ?', $event->{id}, $ridpg);
    }
    else {
        $db->query('UPDATE calendar.event_exceptions SET event_id = ? WHERE event_id = ? AND recurrence_id >= ?', $new->{id}, $event->{id}, $ridpg);
    }
    # The new series keeps the reminders; what was queued from the split on
    # belongs to occurrences that no longer exist on the old one (#79). The
    # conflict target is 0.2.0's unique index (several reminders per event);
    # t/model.t caught the old (event_id) target failing after migration 006.
    $db->query('INSERT INTO calendar.reminders (event_id, minutes_before, channel) SELECT ?, minutes_before, channel FROM calendar.reminders WHERE event_id = ? ON CONFLICT (event_id, minutes_before, channel) DO NOTHING', $new->{id}, $event->{id});
    $db->query('DELETE FROM calendar.reminder_queue WHERE event_id = ? AND recurrence_id >= ?', $event->{id}, $ridpg);
    $tx->commit;
    # The people asked (#85) are asked to the new series too, and hear that
    # the old one now ends.
    $self->copy_attendees($event->{id}, $new->{id});
    $self->notify_attendees($self->event($event->{id}), bump => 1, reset => 0, changed => ['the series now ends earlier']);
    return $new;
}

# delete_event($event, scope => ..., recurrence_id => DateTime)
sub delete_event ($self, $event, %o) {
    my $scope = $o{scope} // 'all';
    my $rid   = $o{recurrence_id};
    $scope = 'all' unless $event->{rrule} && $rid;
    if ($scope eq 'this') {
        $self->_write_exception($event, $rid, {}, 1);
        return 1;
    }
    if ($scope eq 'following') {
        my $master_start = $self->event_start($event);
        if ($rid->epoch > $master_start->epoch) {
            my $until_rule = rrule_until_before($event->{rrule}, $rid);
            my $bound = recurrence_bound($master_start, $until_rule);
            my $ridpg = $rid->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
            my $db = $self->db;
            my $tx = $db->begin;
            $db->query('UPDATE calendar.events SET rrule = ?, recurrence_end = ?, updated_at = NOW() WHERE id = ?',
                $until_rule, ($bound ? $bound->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00') : undef), $event->{id});
            $db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ? AND recurrence_id >= ?', $event->{id}, $ridpg);
            $db->query('DELETE FROM calendar.reminder_queue WHERE event_id = ? AND recurrence_id >= ?', $event->{id}, $ridpg);
            $tx->commit;
            $self->notify_attendees($self->event($event->{id}), bump => 1, reset => 0, changed => ['the series now ends earlier']);
            return 1;
        }
    }
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('UPDATE calendar.events SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?', $event->{id});
    $db->query('UPDATE calendar.shares SET revoked_at = NOW() WHERE event_id = ? AND revoked_at IS NULL', $event->{id});
    $self->_clear_reminder_queue($db, $event->{id}, 'pending');
    $tx->commit;
    # Called off: a CANCEL to everyone who was invited (#85).
    $self->cancel_attendees($event);
    return 1;
}

# -------------------------------------------------------------- expansion

# instances(calendars => [rows], window_start => DateTime, window_end => DateTime,
#           events => [rows] (optional: these instead of the calendars' events))
# -> [ { event, calendar_id, recurrence_id (DateTime|undef), start, end (DateTime,
#        in the event zone), all_day, title, description, location, color,
#        is_recurring, is_exception, uid }, ... ] sorted by start.
sub instances ($self, %a) {
    my ($ws, $we) = @a{qw(window_start window_end)};
    die "instances(): window required\n" unless $ws && $we;
    my $wspg = $ws->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    my $wepg = $we->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');

    my $events = $a{events};
    unless ($events) {
        my @ids = map { $_->{id} } @{ $a{calendars} // [] };
        return [] unless @ids;
        $events = $self->db->query(
            q{SELECT * FROM calendar.events
               WHERE calendar_id = ANY(?) AND deleted_at IS NULL AND starts_at < ?
                 AND ((rrule IS NULL AND ends_at > ?)
                   OR (rrule IS NOT NULL AND (recurrence_end IS NULL OR recurrence_end >= ?)))},
            \@ids, $wepg, $wspg, $wspg,
        )->hashes->to_array;
    }
    my @recurring_ids = map { $_->{id} } grep { $_->{rrule} } @$events;
    my %exc;
    if (@recurring_ids) {
        for my $x (@{ $self->db->query('SELECT * FROM calendar.event_exceptions WHERE event_id = ANY(?)', \@recurring_ids)->hashes->to_array }) {
            $exc{ $x->{event_id} }{ _dt($x->{recurrence_id})->epoch } = $x;
        }
    }

    my @out;
    for my $e (@$events) {
        my $zone  = $e->{timezone};
        my $start = $self->event_start($e);
        my $end   = $self->event_end($e);
        my $dur   = $end->epoch - $start->epoch;
        my $days  = $e->{all_day} ? ($end->delta_days($start)->in_units('days') || 1) : 0;

        unless ($e->{rrule}) {
            next unless $end > $ws && $start < $we;
            push @out, $self->_instance($e, undef, $start, $end);
            next;
        }
        # Start the expansion early enough to catch an occurrence that began
        # before the window and is still running inside it.
        my $occ = occurrences(dtstart => $start, rrule => $e->{rrule},
            window_start => $ws->clone->subtract(seconds => $dur + 1), window_end => $we);
        my $mine = $exc{ $e->{id} } // {};
        my %seen;
        for my $o (@$occ) {
            $seen{ $o->epoch } = 1;
            my $x = $mine->{ $o->epoch };
            if ($x) {
                next if $x->{cancelled};
                my $inst = $self->_exception_instance($e, $x, $o);
                push @out, $inst if $inst->{end} > $ws && $inst->{start} < $we;
                next;
            }
            my $oend = $e->{all_day} ? $o->clone->add(days => $days) : $o->clone->add(seconds => $dur);
            next unless $oend > $ws && $o < $we;
            push @out, $self->_instance($e, $o, $o, $oend);
        }
        # An occurrence moved INTO the window from outside it.
        for my $x (values %$mine) {
            next if $x->{cancelled};
            my $rid = _dt($x->{recurrence_id}, $zone);
            next if $seen{ $rid->epoch };
            next unless defined $x->{starts_at} || defined $x->{start_date};
            my $inst = $self->_exception_instance($e, $x, $rid);
            push @out, $inst if $inst->{end} > $ws && $inst->{start} < $we;
        }
    }
    return [ sort { $a->{start} <=> $b->{start} || $a->{title} cmp $b->{title} } @out ];
}

sub _instance ($self, $e, $rid, $start, $end) {
    return {
        event => $e, event_id => $e->{id}, calendar_id => $e->{calendar_id}, uid => $e->{uid},
        recurrence_id => $rid, start => $start, end => $end,
        all_day => $e->{all_day} ? 1 : 0, title => $e->{title}, description => $e->{description},
        location => $e->{location}, color => $e->{color}, is_recurring => $e->{rrule} ? 1 : 0, is_exception => 0,
    };
}

sub _exception_instance ($self, $e, $x, $rid) {
    my $zone = $e->{timezone};
    my $all_day = defined $x->{all_day} ? ($x->{all_day} ? 1 : 0) : ($e->{all_day} ? 1 : 0);
    my ($start, $end);
    if ($all_day) {
        $start = _date($x->{start_date} // $rid->ymd)->set_time_zone($zone);
        $end   = defined $x->{end_date} ? _date($x->{end_date})->set_time_zone($zone)
               : $start->clone->add(days => ($self->event_end($e)->delta_days($self->event_start($e))->in_units('days') || 1));
    }
    else {
        $start = defined $x->{starts_at} ? _dt($x->{starts_at}, $zone) : $rid->clone->set_time_zone($zone);
        $end   = defined $x->{ends_at}   ? _dt($x->{ends_at}, $zone)
               : $start->clone->add(seconds => $self->event_end($e)->epoch - $self->event_start($e)->epoch);
    }
    my $inst = $self->_instance($e, $rid, $start, $end);
    $inst->{all_day} = $all_day;
    $inst->{is_exception} = 1;
    for my $k (qw(title description location color)) { $inst->{$k} = $x->{$k} if defined $x->{$k} }
    return $inst;
}

# ------------------------------------------------------------- CalDAV (#84)

# App passwords: the credential a phone's or a desktop app's CalDAV account
# types. The secret is 24 characters from an alphabet of 32 without
# look-alikes (120 bits), made here and shown once; the row keeps a salted
# SHA-256 of it. Not argon2 as a password a person chose would get: a secret
# this random cannot be guessed, and every CalDAV request verifies it (a
# phone asks every few minutes), so a deliberately slow hash would only cost
# the pool CPU for nothing.
my @SECRET_ALPHABET = ('a' .. 'k', 'm', 'n', 'p' .. 'z', '2' .. '9');

sub _new_secret {
    my $out = '';
    my $n = @SECRET_ALPHABET;
    my $limit = 256 - (256 % $n);       # rejection sampling keeps every symbol equally likely
    while (length $out < 24) {
        for my $b (map { hex } (_random_hex(32) =~ /../g)) {
            next if $b >= $limit;
            $out .= $SECRET_ALPHABET[$b % $n];
            last if length $out >= 24;
        }
    }
    return $out;
}
# Typed on a phone: dashes, spaces and case do not count.
sub _norm_secret ($s) { return lc(($s // '') =~ s/[\s-]+//gr) }
sub _secret_hash ($salt, $secret) { require Digest::SHA; return Digest::SHA::sha256_hex("$salt:" . _norm_secret($secret)) }

sub app_passwords_for ($self, $email) {
    return $self->db->query(
        'SELECT id, label, created_at, last_used_at, last_used_agent FROM calendar.app_passwords WHERE lower(user_email) = ? AND revoked_at IS NULL ORDER BY created_at, id',
        _norm($email))->hashes->to_array;
}

# create_app_password($email, $label) -> the row plus `secret`, the one time it is known.
sub create_app_password ($self, $email, $label) {
    $label = (($label // '') =~ s/\s+/ /gr) =~ s/\A\s+|\s+\z//gr;
    die "Name the device (for example \"Dana's iPhone\").\n" unless length $label;
    die "The name is too long (80 characters at most).\n" if length $label > 80;
    my $n = $self->db->query('SELECT count(*) FROM calendar.app_passwords WHERE lower(user_email) = ? AND revoked_at IS NULL', _norm($email))->array->[0];
    die "That is 20 devices already; revoke one first.\n" if $n >= 20;
    my $secret = _new_secret();
    my $salt   = _random_hex(16);
    my $row = $self->db->query(
        'INSERT INTO calendar.app_passwords (user_email, label, salt, secret_hash) VALUES (?, ?, ?, ?) RETURNING id, label, created_at, last_used_at, last_used_agent',
        _norm($email), $label, $salt, _secret_hash($salt, $secret))->hash;
    $row->{secret} = join '-', ($secret =~ /.{4}/g);
    return $row;
}

sub revoke_app_password ($self, $email, $id) {
    return 0 unless defined $id && $id =~ /\A\d{1,18}\z/;
    my $r = $self->db->query('UPDATE calendar.app_passwords SET revoked_at = NOW() WHERE id = ? AND lower(user_email) = ? AND revoked_at IS NULL RETURNING id', $id, _norm($email))->hash;
    return $r ? 1 : 0;
}

# The live password the secret opens for this account, or undef. Every one of
# the account's is tried (a phone says nothing about which it holds), each
# with a constant-time comparison.
sub verify_app_password ($self, $email, $secret) {
    my $norm = _norm_secret($secret);
    return undef unless length($norm) >= 16 && length(_norm($email));
    my $hit;
    for my $r (@{ $self->db->query('SELECT * FROM calendar.app_passwords WHERE lower(user_email) = ? AND revoked_at IS NULL', _norm($email))->hashes->to_array }) {
        $hit = $r if Mojo::Util::secure_compare(_secret_hash($r->{salt}, $norm), $r->{secret_hash});
    }
    return $hit;
}

# Which device is alive: stamped at most once in five minutes per password.
sub touch_app_password ($self, $id, $agent = undef) {
    $agent = substr((($agent // '') =~ s/[\x00-\x1f\x7f]//gr), 0, 200);
    eval { $self->db->query(q{UPDATE calendar.app_passwords SET last_used_at = NOW(), last_used_agent = ? WHERE id = ? AND (last_used_at IS NULL OR last_used_at < NOW() - INTERVAL '5 minutes')}, $agent, $id) };
    return 1;
}

# The calendar's change token: the largest change_seq among its events,
# deleted ones included (migration 009 stamps it on every change to an event
# or one of its parts). 0 for a calendar with no events yet.
sub sync_seq ($self, $cal_id) {
    return $self->db->query('SELECT COALESCE(MAX(change_seq), 0) FROM calendar.events WHERE calendar_id = ?', $cal_id)->array->[0];
}

# Every event of a calendar whose change_seq is past $since, live or deleted,
# oldest change first: what a sync-collection REPORT answers.
sub events_changed_since ($self, $cal_id, $since) {
    return $self->db->query('SELECT id, uid, change_seq, deleted_at FROM calendar.events WHERE calendar_id = ? AND change_seq > ? ORDER BY change_seq', $cal_id, $since // 0)->hashes->to_array;
}

# A calendar's live events as CalDAV objects: all of them, or those that could
# have an occurrence in [window_start, window_end) (instances()' own test).
sub dav_events ($self, $cal_id, %w) {
    if ($w{window_start} && $w{window_end}) {
        my $wspg = $w{window_start}->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
        my $wepg = $w{window_end}->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
        return $self->db->query(
            q{SELECT * FROM calendar.events WHERE calendar_id = ? AND deleted_at IS NULL AND starts_at < ?
                AND ((rrule IS NULL AND ends_at > ?) OR (rrule IS NOT NULL AND (recurrence_end IS NULL OR recurrence_end >= ?))) ORDER BY starts_at, id},
            $cal_id, $wepg, $wspg, $wspg)->hashes->to_array;
    }
    return $self->db->query('SELECT * FROM calendar.events WHERE calendar_id = ? AND deleted_at IS NULL ORDER BY starts_at, id', $cal_id)->hashes->to_array;
}

sub event_in_calendar_by_uid ($self, $cal_id, $uid) {
    return undef unless defined $uid && length $uid && defined $cal_id;
    return $self->db->query('SELECT * FROM calendar.events WHERE calendar_id = ? AND uid = ? AND deleted_at IS NULL', $cal_id, $uid)->hash;
}
# The same UID in the trash (of one calendar, or of any with $cal_id undef):
# a phone putting back what was deleted.
sub trashed_event_by_uid ($self, $cal_id, $uid) {
    return undef unless defined $uid && length $uid;
    return $self->db->query('SELECT * FROM calendar.events WHERE uid = ? AND deleted_at IS NOT NULL AND (?::bigint IS NULL OR calendar_id = ?)', $uid, $cal_id, $cal_id)->hash;
}
# A phone moves an event between calendars by PUTting it into the other one
# (same UID) and deleting the old copy; here that is one row changing hands.
sub move_event_to_calendar ($self, $event_id, $cal_id) {
    $self->db->query('UPDATE calendar.events SET calendar_id = ?, updated_at = NOW() WHERE id = ?', $cal_id, $event_id);
    return 1;
}

# A PUT replaces the whole object, its changed and cancelled occurrences with
# it; the file's own come back through _write_exception afterwards.
sub clear_exceptions ($self, $event_id) {
    my $db = $self->db;
    $db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ?', $event_id);
    $self->_clear_reminder_queue($db, $event_id, 'pending');
    return 1;
}

# One event in the shape ICS::masters_ics takes: the rule, its cancelled dates
# and changed occurrences, its reminders as alarms (what the export and a
# CalDAV object share).
sub masters_entry ($self, $e) {
    my %x = (uid => $e->{uid}, title => $e->{title}, description => $e->{description}, location => $e->{location},
        all_day => $e->{all_day} ? 1 : 0, start => $self->event_start($e), end => $self->event_end($e),
        created => _dt($e->{created_at}), updated => _dt($e->{updated_at}), rrule => $e->{rrule},
        (defined $e->{sequence} ? (sequence => $e->{sequence}) : ()),
        alarms => [ map { { minutes => $_->{minutes_before} + 0 } } @{ $self->reminders_for($e->{id}) } ]);
    if ($e->{rrule}) { my ($ex, $ov) = $self->series_parts($e); $x{exdates} = $ex; $x{overrides} = $ov }
    return \%x;
}

# A calendar by the segment a CalDAV client addresses it with: the name it
# made the collection under (MKCALENDAR), else its number. The viewer's own
# calendar wins a tie between two owners' names.
sub calendar_by_dav_name ($self, $email, $seg) {
    return undef unless defined $seg && length $seg && length $seg <= 128;
    my $row = $self->db->query('SELECT * FROM calendar.calendars WHERE dav_name = ? AND deleted_at IS NULL ORDER BY (lower(owner_email) = ?) DESC, id LIMIT 1', $seg, _norm($email))->hash;
    return $row if $row;
    return ($seg =~ /\A\d{1,18}\z/) ? $self->calendar($seg) : undef;
}
sub dav_segment ($cal) { return (defined $cal->{dav_name} && length $cal->{dav_name}) ? $cal->{dav_name} : "$cal->{id}" }
sub set_dav_name ($self, $cal_id, $name) {
    $self->db->query('UPDATE calendar.calendars SET dav_name = ? WHERE id = ?', $name, $cal_id);
    return 1;
}

# ------------------------------------------------------------------- shares

sub shares_for_calendar ($self, $cal_id) {
    return $self->db->query('SELECT * FROM calendar.shares WHERE calendar_id = ? AND revoked_at IS NULL ORDER BY created_at', $cal_id)->hashes->to_array;
}
sub shares_for_event ($self, $event_id) {
    return $self->db->query('SELECT * FROM calendar.shares WHERE event_id = ? AND revoked_at IS NULL ORDER BY created_at', $event_id)->hashes->to_array;
}
sub share ($self, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return $self->db->query('SELECT * FROM calendar.shares WHERE id = ?', $id)->hash;
}

# create_share(owner => $email, calendar_id => | event_id =>, shared_with_email => undef|addr,
#              permission => read|edit, detail => full|busy, expires_days => N|undef)
sub create_share ($self, %f) {
    my $with = defined $f{shared_with_email} && length $f{shared_with_email} ? _norm($f{shared_with_email}) : undef;
    my $perm = ($f{permission} // 'read') eq 'edit' ? 'edit' : 'read';
    $perm = 'read' unless $with;    # a link is never an edit share
    my $detail = ($f{detail} // 'full') eq 'busy' ? 'busy' : 'full';
    my $days = $f{expires_days};
    $days = undef unless defined $days && $days =~ /\A\d+\z/ && $days > 0;
    return $self->db->query(
        q{INSERT INTO calendar.shares (token, owner_email, calendar_id, event_id, shared_with_email, permission, detail, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, CASE WHEN ?::int IS NULL THEN NULL ELSE NOW() + (?::int * INTERVAL '1 day') END) RETURNING *},
        $self->new_token, _norm($f{owner}), $f{calendar_id}, $f{event_id}, $with, $perm, $detail, $days, $days,
    )->hash;
}

sub revoke_share ($self, $id) {
    $self->db->query('UPDATE calendar.shares SET revoked_at = NOW() WHERE id = ? AND revoked_at IS NULL', $id);
    return 1;
}

# A link's share row if it still works, with the calendar or event it opens.
sub share_by_token ($self, $token) {
    return undef unless defined $token && $token =~ /\A[0-9a-f]{64}\z/;
    my $row = $self->db->query(
        q{SELECT * FROM calendar.shares WHERE token = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())}, $token,
    )->hash or return undef;
    if ($row->{calendar_id}) { $row->{calendar} = $self->calendar($row->{calendar_id}) or return undef }
    if ($row->{event_id}) {
        $row->{event} = $self->event($row->{event_id}) or return undef;
        $row->{calendar} = $self->calendar($row->{event}{calendar_id}) or return undef;
    }
    return _share_row($row);
}

sub note_share_access ($self, $id) {
    eval { $self->db->query('UPDATE calendar.shares SET accessed_at = NOW(), access_count = access_count + 1 WHERE id = ?', $id) };
    return 1;
}

# --------------------------------------------------- account settings, mail links

sub account_settings ($self, $email) {
    my $row = $self->db->query('SELECT * FROM calendar.account_settings WHERE user_email = ?', _norm($email))->hash // {};
    return {
        mail_links_enabled => $row->{mail_links_enabled} ? 1 : 0, mail_links_enabled_at => $row->{mail_links_enabled_at},
        ai_enabled => $row->{ai_enabled} ? 1 : 0, ai_consent_sha256 => $row->{ai_consent_sha256}, ai_consent_at => $row->{ai_consent_at},
        research_enabled => $row->{research_enabled} ? 1 : 0, research_consent_at => $row->{research_consent_at},
        research_auto => $row->{research_auto} ? 1 : 0,
        # #80: proposing as email arrives, and the research-at-arrival
        # entitlement (admin-set) with the person's own switch under it.
        auto_propose => $row->{auto_propose} ? 1 : 0, auto_propose_consent_at => $row->{auto_propose_consent_at},
        research_at_arrival_allowed => $row->{research_at_arrival_allowed} ? 1 : 0,
        research_at_arrival => ($row->{research_at_arrival_allowed} && $row->{research_at_arrival}) ? 1 : 0,
    };
}

sub set_research_at_arrival ($self, $email, $on) {
    $self->db->query(
        q{INSERT INTO calendar.account_settings (user_email, research_at_arrival) VALUES (?, ?)
          ON CONFLICT (user_email) DO UPDATE SET research_at_arrival = EXCLUDED.research_at_arrival, updated_at = NOW()},
        _norm($email), ($on ? 1 : 0),
    );
    return 1;
}

# The entitlements an administrator (later #63's billing) grants an account.
# Taking one away also turns the switch under it off.
sub set_entitlements ($self, $email, %e) {
    if (exists $e{research_at_arrival_allowed}) {
        my $on = $e{research_at_arrival_allowed} ? 1 : 0;
        $self->db->query(
            q{INSERT INTO calendar.account_settings (user_email, research_at_arrival_allowed) VALUES (?, ?)
              ON CONFLICT (user_email) DO UPDATE SET research_at_arrival_allowed = EXCLUDED.research_at_arrival_allowed,
                  research_at_arrival = CASE WHEN EXCLUDED.research_at_arrival_allowed THEN calendar.account_settings.research_at_arrival ELSE FALSE END,
                  updated_at = NOW()},
            _norm($email), $on,
        );
    }
    return $self->account_settings($email);
}

# ---------------------------------------------------------------- reminders (#79)

# Where this account's reminders go: the addresses it listed, else its own.
sub reminder_addresses ($self, $email) {
    return [ map { $_->{address} } @{ $self->db->query('SELECT address FROM calendar.reminder_addresses WHERE user_email = ? ORDER BY created_at, address', _norm($email))->hashes->to_array } ];
}

sub reminder_recipients ($self, $email) {
    my $list = $self->reminder_addresses($email);
    return @$list ? $list : [ _norm($email) ];
}

# Replaces the list. Dies with a sentence for the person on a bad address.
sub set_reminder_addresses ($self, $email, $list) {
    my (%seen, @clean);
    for my $a (@{ ref $list eq 'ARRAY' ? $list : [] }) {
        next unless defined $a && !ref $a;
        my $x = lc($a =~ s/\A\s+|\s+\z//gr);
        next unless length $x;
        die "\"$x\" does not look like an email address.\n" unless $x =~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/ && length $x <= 254;
        push @clean, $x unless $seen{$x}++;
    }
    die "At most 5 reminder addresses.\n" if @clean > 5;
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('DELETE FROM calendar.reminder_addresses WHERE user_email = ?', _norm($email));
    $db->query('INSERT INTO calendar.reminder_addresses (user_email, address) VALUES (?, ?)', _norm($email), $_) for @clean;
    $tx->commit;
    return \@clean;
}

# The event's reminders, soonest first: since 0.2.0 several per event, each
# minutes before the start, by email or to the recipient's webhook.
sub reminders_for ($self, $event_id) {
    return $self->db->query('SELECT * FROM calendar.reminders WHERE event_id = ? ORDER BY minutes_before, channel', $event_id)->hashes->to_array;
}
# The one older clients know: the soonest email reminder, or undef.
sub reminder_for ($self, $event_id) {
    return (grep { $_->{channel} eq 'email' } @{ $self->reminders_for($event_id) })[0];
}
sub reminder_by_id ($self, $id) {
    return $self->db->query('SELECT * FROM calendar.reminders WHERE id = ?', $id)->hash;
}

# Replaces the event's reminders with the list given ([ { minutes_before,
# channel } ], at most 3). A reminder that stays keeps its row and what it
# queued; a removed one takes its queued rows with it (cascade); the runner
# queues the new ones. Dies with a sentence for the person.
sub set_reminders ($self, $event_id, $list) {
    my (%want, @clean);
    for my $r (@{ ref $list eq 'ARRAY' ? $list : [] }) {
        my ($min, $ch) = ref $r eq 'HASH' ? ($r->{minutes_before}, $r->{channel} // 'email') : ($r, 'email');
        next unless defined $min && length $min;
        die "A reminder must be a number of minutes (0 to 20160).\n" unless $min =~ /\A\d+\z/ && $min <= 20160;
        die "A reminder goes by email or to your webhook.\n" unless ($ch // '') =~ /\A(?:email|webhook)\z/;
        push @clean, [ $min + 0, $ch ] unless $want{ ($min + 0) . "/$ch" }++;
    }
    die "At most 3 reminders per event.\n" if @clean > 3;
    my $db = $self->db;
    my $tx = $db->begin;
    my @have = @{ $db->query('SELECT * FROM calendar.reminders WHERE event_id = ?', $event_id)->hashes->to_array };
    my %had;
    for my $h (@have) {
        my $key = "$h->{minutes_before}/$h->{channel}";
        if ($want{$key}) { $had{$key} = 1; next }
        $db->query('DELETE FROM calendar.reminders WHERE id = ?', $h->{id});
    }
    for my $c (@clean) {
        next if $had{"$c->[0]/$c->[1]"};
        $db->query('INSERT INTO calendar.reminders (event_id, minutes_before, channel) VALUES (?, ?, ?)', $event_id, $c->[0], $c->[1]);
    }
    $tx->commit;
    return $self->reminders_for($event_id);
}

# The single-reminder form older clients send: one email reminder, or none.
sub set_reminder ($self, $event_id, $minutes) {
    $self->set_reminders($event_id, (defined $minutes && length $minutes) ? [ { minutes_before => $minutes, channel => 'email' } ] : []);
    return 1;
}

sub _clear_reminder_queue ($self, $db, $event_id, $which) {
    $db->query('DELETE FROM calendar.reminder_queue WHERE event_id = ?' . ($which eq 'pending' ? q{ AND state = 'pending'} : ''), $event_id);
    return;
}

# Every account that sees this event besides the owner: live shares of the
# calendar and of the event itself. Reminders go to them too (Gardner,
# 2026-11-14).
sub shared_with_accounts ($self, $event) {
    my $rows = $self->db->query(
        q{SELECT DISTINCT lower(shared_with_email) AS e FROM calendar.shares
           WHERE shared_with_email IS NOT NULL AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > NOW())
             AND (calendar_id = ? OR event_id = ?)}, $event->{calendar_id}, $event->{id},
    )->hashes->to_array;
    return [ map { $_->{e} } @$rows ];
}

# The events with a reminder that may have an occurrence inside the window.
sub reminder_candidates ($self, $ws, $we) {
    my $wspg = $ws->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    my $wepg = $we->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    return $self->db->query(
        q{SELECT e.*, r.id AS reminder_id, r.minutes_before, r.channel, c.owner_email AS calendar_owner
            FROM calendar.reminders r
            JOIN calendar.events e ON e.id = r.event_id
            JOIN calendar.calendars c ON c.id = e.calendar_id
           WHERE e.deleted_at IS NULL AND c.deleted_at IS NULL AND e.starts_at < ?
             AND ((e.rrule IS NULL AND e.ends_at > ?)
               OR (e.rrule IS NOT NULL AND (e.recurrence_end IS NULL OR e.recurrence_end >= ?)))},
        $wepg, $wspg, $wspg,
    )->hashes->to_array;
}

# Queue one (reminder, occurrence, account) once; a second call is a no-op.
sub queue_reminder ($self, %r) {
    $self->db->query(
        q{INSERT INTO calendar.reminder_queue (reminder_id, event_id, recurrence_id, recipient, due_at) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (reminder_id, recurrence_id, recipient) DO NOTHING},
        $r{reminder_id}, $r{event_id}, $r{recurrence_id}->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00'),
        _norm($r{recipient}), $r{due_at}->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00'),
    );
    return 1;
}

# Due rows, claimed so that no other process (there are six) sends them too.
sub claim_due_reminders ($self, $limit = 3) {
    return $self->db->query(
        q{UPDATE calendar.reminder_queue SET state = 'running', attempts = attempts + 1, claimed_at = NOW()
           WHERE id IN (SELECT id FROM calendar.reminder_queue WHERE state = 'pending' AND due_at <= NOW()
                          ORDER BY due_at LIMIT ? FOR UPDATE SKIP LOCKED)
          RETURNING *}, $limit,
    )->hashes->to_array;
}

sub reminder_sent ($self, $id) {
    $self->db->query(q{UPDATE calendar.reminder_queue SET state = 'sent', sent_at = NOW(), last_error = NULL WHERE id = ?}, $id);
    return 1;
}

# A failed send goes back to the queue a little later, three times in all.
sub reminder_failed ($self, $id, $error, $max_attempts = 3) {
    $self->db->query(
        q{UPDATE calendar.reminder_queue
             SET state = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END,
                 due_at = CASE WHEN attempts >= ? THEN due_at ELSE NOW() + INTERVAL '2 minutes' END,
                 last_error = ?
           WHERE id = ?}, $max_attempts, $max_attempts, substr($error // '', 0, 500), $id,
    );
    return 1;
}

# A process that died mid-send leaves 'running' rows; they go back after 5 min.
sub reclaim_stale_reminders ($self) {
    $self->db->query(q{UPDATE calendar.reminder_queue SET state = 'pending' WHERE state = 'running' AND claimed_at < NOW() - INTERVAL '5 minutes'});
    # Rows for occurrences long past are of no use to anyone.
    $self->db->query(q{DELETE FROM calendar.reminder_queue WHERE state IN ('sent', 'failed') AND due_at < NOW() - INTERVAL '30 days'});
    return 1;
}

# --------------------------------------------- proposals at arrival (#80)

# Links whose email arrived for an account that asked for proposals before
# any click (consent #3, current wording), not yet looked at. Claimed per
# process; a claim that never finishes is released by reclaim_stale_mail_link_jobs.
sub claim_mail_links_for_proposal ($self, $consent_sha, $limit = 1) {
    my $rows = $self->db->query(
        q{UPDATE calendar.mail_links SET job_state = 'running', job_started_at = NOW(), job_attempts = job_attempts + 1
           WHERE id IN (
             SELECT m.id FROM calendar.mail_links m
              WHERE m.proposal IS NULL AND m.job_state IS NULL AND m.event_id IS NULL
                AND m.expires_at > NOW() AND m.created_at > NOW() - INTERVAL '2 days'
                -- Only email that arrived AFTER the consent: the notice says
                -- "as it arrives", so what came before stays untouched.
                AND EXISTS (SELECT 1 FROM calendar.account_settings s
                             WHERE s.auto_propose AND s.auto_propose_consent_sha256 = ?
                               AND s.auto_propose_consent_at IS NOT NULL AND m.created_at >= s.auto_propose_consent_at
                               AND s.user_email IN (SELECT lower(a) FROM jsonb_array_elements_text(m.accounts) AS a))
              ORDER BY m.created_at LIMIT ? FOR UPDATE SKIP LOCKED)
          RETURNING *}, $consent_sha, $limit,
    )->hashes->to_array;
    for my $row (@$rows) {
        my $accts = eval { Mojo::JSON::decode_json($row->{accounts}) } // [];
        $row->{accounts} = [ map { lc } grep { defined && !ref } @$accts ];
    }
    return $rows;
}

# The accounts on this link that opted in, with their zones and whether the
# research step is theirs to have.
sub auto_propose_accounts ($self, $link, $consent_sha) {
    return [] unless @{ $link->{accounts} // [] };
    return $self->db->query(
        q{SELECT s.user_email, s.research_at_arrival_allowed AND s.research_at_arrival AND s.research_enabled AS research,
                 s.research_consent_sha256, p.timezone
            FROM calendar.account_settings s LEFT JOIN calendar.user_prefs p ON p.user_email = s.user_email
           WHERE s.auto_propose AND s.auto_propose_consent_sha256 = ? AND s.user_email = ANY(?)
           ORDER BY s.user_email}, $consent_sha, $link->{accounts},
    )->hashes->to_array;
}

sub mail_link_skipped ($self, $id) {
    $self->db->query(q{UPDATE calendar.mail_links SET job_state = 'skipped' WHERE id = ?}, $id);
    return 1;
}

sub mail_link_proposed ($self, $id, $proposal, $facts = undef) {
    $self->db->query(
        q{UPDATE calendar.mail_links SET proposal = ?::jsonb, facts = ?::jsonb, proposed_at = NOW(), job_state = 'done' WHERE id = ?},
        Mojo::JSON::encode_json($proposal), ($facts ? Mojo::JSON::encode_json($facts) : undef), $id,
    );
    return 1;
}

sub mail_link_facts ($self, $id, $facts) {
    $self->db->query(q{UPDATE calendar.mail_links SET facts = ?::jsonb WHERE id = ?}, Mojo::JSON::encode_json($facts), $id);
    return 1;
}

# A failed call frees the row for another try (three in all).
sub mail_link_job_failed ($self, $id, $max_attempts = 3) {
    $self->db->query(
        q{UPDATE calendar.mail_links SET job_state = CASE WHEN job_attempts >= ? THEN 'failed' ELSE NULL END WHERE id = ?}, $max_attempts, $id,
    );
    return 1;
}

sub reclaim_stale_mail_link_jobs ($self) {
    $self->db->query(
        q{UPDATE calendar.mail_links SET job_state = CASE WHEN job_attempts >= 3 THEN 'failed' ELSE NULL END
           WHERE job_state = 'running' AND job_started_at < NOW() - INTERVAL '10 minutes'},
    );
    return 1;
}

sub _decode_link_json ($row) {
    for my $k (qw(proposal facts)) {
        $row->{$k} = (defined $row->{$k} && !ref $row->{$k}) ? (eval { Mojo::JSON::decode_json($row->{$k}) } // undef) : $row->{$k};
    }
    return $row;
}

# The Suggestions list: links with a proposal that THIS account has not made
# an event from and has not dismissed, newest first. One link serves every
# recipient of the message, so "made" is judged per account (#81,
# mail_link_events); an event deleted since still counts as made.
sub suggestions_for ($self, $email) {
    my $me = _norm($email);
    my $rows = $self->db->query(
        q{SELECT * FROM calendar.mail_links m
           WHERE proposal IS NOT NULL AND expires_at > NOW()
             AND ? IN (SELECT lower(a) FROM jsonb_array_elements_text(accounts) AS a)
             AND NOT EXISTS (SELECT 1 FROM calendar.mail_link_events x WHERE x.link_id = m.id AND x.user_email = ?)
             AND NOT EXISTS (SELECT 1 FROM calendar.mail_link_dismissals d WHERE d.link_id = m.id AND d.user_email = ?)
           ORDER BY proposed_at DESC LIMIT 50}, $me, $me, $me,
    )->hashes->to_array;
    return [ map { _decode_link_json($_) } @$rows ];
}

sub suggestions_count ($self, $email) {
    my $me = _norm($email);
    return $self->db->query(
        q{SELECT count(*) FROM calendar.mail_links m
           WHERE proposal IS NOT NULL AND expires_at > NOW()
             AND ? IN (SELECT lower(a) FROM jsonb_array_elements_text(accounts) AS a)
             AND NOT EXISTS (SELECT 1 FROM calendar.mail_link_events x WHERE x.link_id = m.id AND x.user_email = ?)
             AND NOT EXISTS (SELECT 1 FROM calendar.mail_link_dismissals d WHERE d.link_id = m.id AND d.user_email = ?)}, $me, $me, $me,
    )->array->[0] + 0;
}

# Dismissed by THIS account (0.2.0): the other recipients of the message keep it.
sub dismiss_suggestion ($self, $id, $email) {
    $self->db->query('INSERT INTO calendar.mail_link_dismissals (link_id, user_email) VALUES (?, ?) ON CONFLICT DO NOTHING', $id, _norm($email));
    return 1;
}

# --- the trash (0.2.0): the soft-deleted events of the account's own
# calendars, newest first, for 30 days. Restoring clears deleted_at; shares
# revoked at the delete stay revoked.
sub trashed_events ($self, $email) {
    return $self->db->query(
        q{SELECT e.*, c.name AS calendar_name FROM calendar.events e JOIN calendar.calendars c ON c.id = e.calendar_id
           WHERE lower(c.owner_email) = ? AND c.deleted_at IS NULL AND e.deleted_at IS NOT NULL AND e.deleted_at > NOW() - INTERVAL '30 days'
           ORDER BY e.deleted_at DESC LIMIT 200}, _norm($email),
    )->hashes->to_array;
}
sub deleted_event ($self, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return $self->db->query('SELECT * FROM calendar.events WHERE id = ? AND deleted_at IS NOT NULL', $id)->hash;
}
sub restore_event ($self, $id) {
    my $row = $self->db->query('UPDATE calendar.events SET deleted_at = NULL, updated_at = NOW() WHERE id = ? RETURNING *', $id)->hash;
    # Back after a CANCEL: the invitation goes out again and everyone answers afresh (#85).
    $row->{sequence} = $self->_sequence_of($id) if $row && $self->notify_attendees($row, bump => 1, reset => 1, reason => 'restored', changed => ['it is back on']);
    return $row;
}

# --- search (0.2.0): events of the account's calendars whose title, place or
# notes contain the text, the ones nearest to now first.
# What an account may search (#87): its calendars, the calendars shared with
# it, and the single events shared with it (an invitation is one of those).
# Returns (\@calendar_ids, \@event_ids, \%calendar_name).
sub _search_scope ($self, $email) {
    my $cals = $self->calendars_for($email);
    my @all = (@{ $cals->{own} }, @{ $cals->{shared} });
    my %name = map { $_->{id} => $_->{name} } @all;
    my %cal_id = map { $_->{id} => 1 } @all;
    my @event_ids = sort { $a <=> $b } keys %{ { map { $_->{event_id} => 1 } @{ $self->viewer_event_shares($email) } } };
    for my $id (@event_ids) {
        my $e = $self->event($id) or next;
        next if $cal_id{ $e->{calendar_id} } || $name{ $e->{calendar_id} };
        my $c = $self->calendar($e->{calendar_id});
        $name{ $e->{calendar_id} } = $c ? $c->{name} : '';
    }
    return ([ sort { $a <=> $b } keys %cal_id ], \@event_ids, \%name);
}

# The literal search: every typed word must appear somewhere in the title,
# the place, the notes, or the name or address of someone invited ("hair cut"
# still finds "Haircut"; a person's name finds the events they were asked
# to). Nearest to now first.
sub search_events ($self, $email, $q, $limit = 50) {
    my ($cal_ids, $event_ids, $name) = $self->_search_scope($email);
    return [] unless (@$cal_ids || @$event_ids) && defined $q && $q =~ /\S/;
    my @words = grep { length } map { s/\A[[:punct:]]+|[[:punct:]]+\z//gr } split /\s+/, $q =~ s/\A\s+|\s+\z//gr;
    @words = ($q =~ s/\A\s+|\s+\z//gr) unless @words;
    my (@where, @bind);
    for my $w (@words) {
        my $like = '%' . ($w =~ s/([%_\\])/\\$1/gr) . '%';
        push @where, q{(e.title ILIKE ? OR e.location ILIKE ? OR e.description ILIKE ?
            OR EXISTS (SELECT 1 FROM calendar.event_attendees a WHERE a.event_id = e.id AND (a.email ILIKE ? OR a.name ILIKE ?)))};
        push @bind, ($like) x 5;
    }
    my $rows = $self->db->query(
        q{SELECT e.* FROM calendar.events e WHERE (e.calendar_id = ANY(?) OR e.id = ANY(?)) AND e.deleted_at IS NULL AND }
        . join(' AND ', @where) . q{ ORDER BY abs(extract(epoch FROM (e.starts_at - NOW()))) LIMIT ?},
        $cal_ids, $event_ids, @bind, $limit,
    )->hashes->to_array;
    $_->{calendar_name} = $name->{ $_->{calendar_id} } for @$rows;
    return $rows;
}

# The events the AI may be asked to rank for a search by meaning (#87): what
# the account sees from six months back to eighteen months ahead, nearest
# first, a few hundred at most, with only the fields that carry meaning.
sub search_candidates ($self, $email, $limit = 300) {
    my ($cal_ids, $event_ids, $name) = $self->_search_scope($email);
    return [] unless @$cal_ids || @$event_ids;
    my $rows = $self->db->query(
        q{SELECT e.* FROM calendar.events e WHERE (e.calendar_id = ANY(?) OR e.id = ANY(?)) AND e.deleted_at IS NULL
            AND e.starts_at > NOW() - INTERVAL '6 months' AND e.starts_at < NOW() + INTERVAL '18 months'
          ORDER BY abs(extract(epoch FROM (e.starts_at - NOW()))) LIMIT ?}, $cal_ids, $event_ids, $limit,
    )->hashes->to_array;
    $_->{calendar_name} = $name->{ $_->{calendar_id} } for @$rows;
    return $rows;
}

# --- a likely duplicate (0.2.0): the same title starting the same day in a
# calendar the account sees.
sub similar_events ($self, $email, $title, $start) {
    my $cals = $self->calendars_for($email);
    my @ids = map { $_->{id} } @{ $cals->{own} }, @{ $cals->{shared} };
    return [] unless @ids && defined $title && $title =~ /\S/ && $start;
    my $day = $start->clone->truncate(to => 'day');
    my ($a, $b) = map { $_->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00') } ($day->clone->subtract(hours => 12), $day->clone->add(hours => 36));
    return $self->db->query(
        q{SELECT * FROM calendar.events WHERE calendar_id = ANY(?) AND deleted_at IS NULL AND lower(btrim(title)) = lower(btrim(?))
           AND starts_at >= ? AND starts_at < ? ORDER BY starts_at LIMIT 5}, \@ids, $title, $a, $b,
    )->hashes->to_array;
}

# --- the sidebar's order (0.2.0): one of the account's own calendars moves
# up or down among the others (the default one stays first on screen).
sub move_calendar ($self, $email, $cal_id, $direction) {
    my $rows = $self->db->query('SELECT id FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL ORDER BY is_default DESC, position, lower(name), id', _norm($email))->hashes->to_array;
    my @ids = map { $_->{id} } @$rows;
    my ($i) = grep { $ids[$_] == $cal_id } 0 .. $#ids;
    return 0 unless defined $i;
    my $j = $direction eq 'up' ? $i - 1 : $i + 1;
    return 0 if $j < 0 || $j > $#ids;
    @ids[$i, $j] = @ids[$j, $i];
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('UPDATE calendar.calendars SET position = ? WHERE id = ?', $_ + 1, $ids[$_]) for 0 .. $#ids;
    $tx->commit;
    return 1;
}

# --- numbers for /metrics (0.2.0): the queue by state, what went out and what
# failed in the last hour, what is overdue, the mail links by job state.
sub metrics ($self) {
    my $db = $self->db;
    my %m;
    $m{"reminder_queue{state=\"$_->{state}\"}"} = $_->{n} for @{ $db->query('SELECT state, count(*) AS n FROM calendar.reminder_queue GROUP BY state')->hashes->to_array };
    $m{reminders_sent_1h}   = $db->query(q{SELECT count(*) FROM calendar.reminder_queue WHERE state = 'sent' AND sent_at > NOW() - INTERVAL '1 hour'})->array->[0];
    $m{reminders_failed_1h} = $db->query(q{SELECT count(*) FROM calendar.reminder_queue WHERE state = 'failed' AND claimed_at > NOW() - INTERVAL '1 hour'})->array->[0];
    $m{reminders_overdue}   = $db->query(q{SELECT count(*) FROM calendar.reminder_queue WHERE state = 'pending' AND due_at < NOW() - INTERVAL '10 minutes'})->array->[0];
    $m{"mail_links{job_state=\"" . ($_->{job_state} // 'untouched') . "\"}"} = $_->{n}
        for @{ $db->query('SELECT job_state, count(*) AS n FROM calendar.mail_links WHERE expires_at > NOW() GROUP BY job_state')->hashes->to_array };
    $m{events}    = $db->query('SELECT count(*) FROM calendar.events WHERE deleted_at IS NULL')->array->[0];
    $m{reminders} = $db->query('SELECT count(*) FROM calendar.reminders')->array->[0];
    return \%m;
}

sub set_research_auto ($self, $email, $on) {
    $self->db->query(
        q{INSERT INTO calendar.account_settings (user_email, research_auto) VALUES (?, ?)
          ON CONFLICT (user_email) DO UPDATE SET research_auto = EXCLUDED.research_auto, updated_at = NOW()},
        _norm($email), ($on ? 1 : 0),
    );
    return 1;
}

sub set_mail_links ($self, $email, $on) {
    $self->db->query(
        q{INSERT INTO calendar.account_settings (user_email, mail_links_enabled, mail_links_enabled_at)
          VALUES (?, ?, CASE WHEN ?::bool THEN NOW() ELSE NULL END)
          ON CONFLICT (user_email) DO UPDATE SET mail_links_enabled = EXCLUDED.mail_links_enabled,
              mail_links_enabled_at = CASE WHEN EXCLUDED.mail_links_enabled THEN NOW() ELSE NULL END, updated_at = NOW()},
        _norm($email), ($on ? 1 : 0), ($on ? 1 : 0),
    );
    return 1;
}

# The row behind a link in an email, if it still exists and has not expired.
# Expired rows are swept here, cheaply, so nothing else has to.
sub mail_link ($self, $token) {
    return undef unless defined $token && $token =~ /\A[0-9a-f]{64}\z/;
    eval { $self->db->query('DELETE FROM calendar.mail_links WHERE expires_at < NOW() - INTERVAL \'1 day\'') };
    my $row = $self->db->query('SELECT * FROM calendar.mail_links WHERE token = ? AND expires_at > NOW()', $token)->hash or return undef;
    my $accts = eval { Mojo::JSON::decode_json($row->{accounts}) } // [];
    $row->{accounts} = [ map { lc } grep { defined && !ref } @$accts ];
    return _decode_link_json($row);
}

sub mail_link_for ($self, $token, $email) {
    my $row = $self->mail_link($token) or return undef;
    my $me = _norm($email);
    return (grep { $_ eq $me } @{ $row->{accounts} }) ? $row : undef;
}

# An account made (or updated) an event from a link. The link row keeps "the
# latest event anyone made from it" (the runner's gate against proposing a
# link that became an event); the per-account record (#81) is what the link
# page and the Suggestions list judge "already added" by.
sub mail_link_used ($self, $id, $event_id, $email) {
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('UPDATE calendar.mail_links SET used_at = NOW(), event_id = ? WHERE id = ?', $event_id, $id);
    $db->query('INSERT INTO calendar.mail_link_events (link_id, user_email, event_id) VALUES (?, ?, ?) ON CONFLICT DO NOTHING',
        $id, _norm($email), $event_id);
    $tx->commit;
    return 1;
}

# The LIVE events this account made from a link, oldest first, each with
# made_at: what the "already added" sheet lists. Events are soft-deleted, so
# a deleted one simply drops out and the link behaves like a first click.
sub mail_link_events_for ($self, $link_id, $email) {
    return $self->db->query(
        q{SELECT e.*, x.created_at AS made_at FROM calendar.mail_link_events x
            JOIN calendar.events e ON e.id = x.event_id
           WHERE x.link_id = ? AND x.user_email = ? AND e.deleted_at IS NULL
           ORDER BY x.created_at}, $link_id, _norm($email),
    )->hashes->to_array;
}

# Whether this account ever made an event from the link, deleted or not.
sub mail_link_made_by ($self, $link_id, $email) {
    return $self->db->query('SELECT 1 FROM calendar.mail_link_events WHERE link_id = ? AND user_email = ? LIMIT 1', $link_id, _norm($email))->array ? 1 : 0;
}

# ------------------------------------------------------------ attendees (#85)
#
# People asked to an event. The organizer is the calendar's owner; each
# attendee has a status (needs-action until they answer), an RSVP token (the
# capability behind /i/<token>) and the SEQUENCE of the last invitation
# mailed to them. The mail itself goes through notice_queue (below), claimed
# by the runner as reminders are, so Save never waits on SMTP.

my %STATUS = map { $_ => 1 } qw(needs-action accepted tentative declined);

sub attendees_for ($self, $event_id) {
    return $self->db->query('SELECT * FROM calendar.event_attendees WHERE event_id = ? ORDER BY invited_at, id', $event_id)->hashes->to_array;
}
sub attendee ($self, $id) {
    return undef unless defined $id && $id =~ /\A\d+\z/;
    return $self->db->query('SELECT * FROM calendar.event_attendees WHERE id = ?', $id)->hash;
}
sub attendee_of ($self, $event_id, $email) {
    return $self->db->query('SELECT * FROM calendar.event_attendees WHERE event_id = ? AND lower(email) = ?', $event_id, _norm($email))->hash;
}

# The attendee row behind an RSVP link, with its event (live or cancelled:
# the page says which) and calendar. undef when the token is unknown.
sub attendee_by_token ($self, $token) {
    return undef unless defined $token && $token =~ /\A[0-9a-f]{64}\z/;
    my $att = $self->db->query('SELECT * FROM calendar.event_attendees WHERE token = ?', $token)->hash or return undef;
    $att->{event} = $self->db->query('SELECT * FROM calendar.events WHERE id = ?', $att->{event_id})->hash or return undef;
    $att->{calendar} = $self->db->query('SELECT * FROM calendar.calendars WHERE id = ?', $att->{event}{calendar_id})->hash or return undef;
    return $att;
}

# "Ann Example <ann@example.com>" or "ann@example.com" -> (email, name) in
# lower case, or () when it is not an address.
sub parse_attendee ($s) {
    return () unless defined $s && !ref $s;
    my $x = $s =~ s/\A\s+|\s+\z//gr;
    my $name;
    if ($x =~ /\A(?:"([^"]*)"|([^<>"]*?))\s*<([^<>\s]+)>\z/) { $name = $1 // $2; $x = $3 }
    $x = lc $x;
    return () unless $x =~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/ && length $x <= 254;
    $name = defined $name ? ($name =~ s/\A\s+|\s+\z//gr) : '';
    return ($x, length $name ? substr($name, 0, 200) : undef);
}

# Invite people: a list of addresses (or "Name <address>"). Dies with a
# sentence for the person. Returns { added => [rows], existing => [rows] };
# each new row has a request queued for it.
sub add_attendees ($self, $event, $list, %o) {
    my $cal = $self->calendar($event->{calendar_id}) or die "Its calendar is gone.\n";
    my (%seen, @want);
    for my $s (@{ ref $list eq 'ARRAY' ? $list : [$list] }) {
        next unless defined $s && (!ref $s || ref $s eq 'HASH');
        my ($email, $name) = ref $s ? parse_attendee(defined $s->{name} && length $s->{name} ? "$s->{name} <$s->{email}>" : $s->{email}) : parse_attendee($s);
        unless ($email) { my $shown = ref $s ? ($s->{email} // '') : $s; die "\"$shown\" does not look like an email address.\n" if length($shown // '') }
        next unless $email;
        die "You are the organizer; there is no need to invite yourself.\n" if $email eq _norm($cal->{owner_email});
        push @want, [ $email, $name ] unless $seen{$email}++;
    }
    my @have = @{ $self->attendees_for($event->{id}) };
    my %by = map { _norm($_->{email}) => $_ } @have;
    die "At most 50 people per event.\n" if @have + grep({ !$by{ $_->[0] } } @want) > 50;
    my (@added, @existing);
    my $db = $self->db;
    my $tx = $db->begin;
    for my $w (@want) {
        if (my $row = $by{ $w->[0] }) { push @existing, $row; next }
        my $row = $db->query(
            'INSERT INTO calendar.event_attendees (event_id, email, name, token) VALUES (?, ?, ?, ?) RETURNING *',
            $event->{id}, $w->[0], $w->[1], $self->new_token,
        )->hash;
        push @added, $row;
        $self->queue_notice(db => $db, event_id => $event->{id}, kind => 'request', recipient => $w->[0], payload => { reason => 'invited' });
        # Someone with an account here sees the event in their own calendar
        # at once: a read-only share (the plan's "attendees with accounts").
        # For anyone else the row is inert: nobody can sign in as them.
        $db->query(
            q{INSERT INTO calendar.shares (token, owner_email, event_id, shared_with_email, permission, detail)
              SELECT ?, ?, ?, ?, 'read', 'full'
               WHERE NOT EXISTS (SELECT 1 FROM calendar.shares WHERE event_id = ? AND lower(shared_with_email) = ? AND revoked_at IS NULL)},
            $self->new_token, _norm($cal->{owner_email}), $event->{id}, $w->[0], $event->{id}, $w->[0],
        );
    }
    $tx->commit;
    return { added => \@added, existing => \@existing };
}

# Taken off the list: the row goes; someone who got the invitation gets the
# cancellation (its payload carries what the mail needs, the row being gone).
sub remove_attendee ($self, $event, $att) {
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('DELETE FROM calendar.event_attendees WHERE id = ?', $att->{id});
    $db->query(q{DELETE FROM calendar.notice_queue WHERE event_id = ? AND lower(recipient) = ? AND kind = 'request' AND state = 'pending'}, $event->{id}, _norm($att->{email}));
    # The read-only share the invitation made goes with it (so does one the
    # owner made by hand for the same person: they are off the event now).
    $db->query(q{UPDATE calendar.shares SET revoked_at = NOW() WHERE event_id = ? AND lower(shared_with_email) = ? AND permission = 'read' AND revoked_at IS NULL}, $event->{id}, _norm($att->{email}));
    if (defined $att->{sequence_sent}) {
        my $seq = $self->bump_sequence($event->{id}, $db);
        $self->queue_notice(db => $db, event_id => $event->{id}, kind => 'cancel', recipient => $att->{email},
            payload => { reason => 'removed', sequence => $seq, name => $att->{name} });
    }
    $tx->commit;
    return 1;
}

# The editor sends the whole list: what is new is invited, what is missing is
# taken off. Returns the attendees as they now are.
sub set_attendees ($self, $event, $list) {
    my %keep;
    for my $s (@{ ref $list eq 'ARRAY' ? $list : [] }) {
        my ($email) = ref $s eq 'HASH' ? parse_attendee($s->{email}) : parse_attendee($s);
        $keep{$email} = 1 if $email;
    }
    for my $a (@{ $self->attendees_for($event->{id}) }) {
        $self->remove_attendee($event, $a) unless $keep{ _norm($a->{email}) };
    }
    $self->add_attendees($event, $list);
    return $self->attendees_for($event->{id});
}

# An answer: from the RSVP link, the web page, the CLI or a mailed REPLY. The
# organizer is told (a 'reply' notice). Dies on an unknown status.
sub set_attendee_status ($self, $att, $status, %o) {
    my $s = lc($status // '');
    my %alias = (yes => 'accepted', maybe => 'tentative', no => 'declined', 'needs_action' => 'needs-action');
    $s = $alias{$s} // $s;
    die "The answer must be accepted, tentative or declined.\n" unless $STATUS{$s};
    my $comment = defined $o{comment} && !ref $o{comment} ? substr($o{comment} =~ s/\A\s+|\s+\z//gr, 0, 500) : undef;
    $comment = undef if defined $comment && !length $comment;
    my $via = ($o{via} // 'link') =~ /\A(?:link|web|mail|cli)\z/ ? $o{via} : 'link';
    my $db = $self->db;
    my $tx = $db->begin;
    my $row = $db->query(
        'UPDATE calendar.event_attendees SET status = ?, comment = ?, responded_at = NOW(), responded_via = ? WHERE id = ? RETURNING *',
        $s, $comment, $via, $att->{id},
    )->hash or die "That invitation is gone.\n";
    my $event = $db->query('SELECT * FROM calendar.events WHERE id = ?', $row->{event_id})->hash;
    my $cal = $event ? $db->query('SELECT * FROM calendar.calendars WHERE id = ?', $event->{calendar_id})->hash : undef;
    if ($cal && !$event->{deleted_at} && !$o{quiet}) {
        $self->queue_notice(db => $db, event_id => $event->{id}, kind => 'reply', recipient => $cal->{owner_email},
            payload => { attendee => $row->{email}, name => $row->{name}, status => $s, comment => $comment, via => $via });
    }
    $tx->commit;
    return $row;
}

# How many were asked and what they said, per event, for the grid's peek.
sub attendee_counts ($self, $ids) {
    return {} unless @{ $ids // [] };
    my %out;
    for my $r (@{ $self->db->query(
        q{SELECT event_id, count(*) AS total,
                 count(*) FILTER (WHERE status = 'accepted') AS accepted, count(*) FILTER (WHERE status = 'tentative') AS tentative,
                 count(*) FILTER (WHERE status = 'declined') AS declined, count(*) FILTER (WHERE status = 'needs-action') AS waiting
            FROM calendar.event_attendees WHERE event_id = ANY(?) GROUP BY event_id}, $ids)->hashes->to_array }) {
        $out{ $r->{event_id} } = { map { $_ => $r->{$_} + 0 } qw(total accepted tentative declined waiting) };
    }
    return \%out;
}

# This account's own answers on the events given: { event_id => status }.
sub my_attendance ($self, $email, $ids) {
    return {} unless @{ $ids // [] };
    return { map { $_->{event_id} => $_->{status} }
        @{ $self->db->query('SELECT event_id, status FROM calendar.event_attendees WHERE event_id = ANY(?) AND lower(email) = ?', $ids, _norm($email))->hashes->to_array } };
}

sub bump_sequence ($self, $event_id, $db = undef) {
    return ($db // $self->db)->query('UPDATE calendar.events SET sequence = sequence + 1 WHERE id = ? RETURNING sequence', $event_id)->array->[0];
}

# The event changed: every attendee gets the invitation again. A change of
# time or place (significant) bumps SEQUENCE and asks everyone to answer
# afresh (RFC 5546); a retitle keeps their answers. `changed` names what
# changed, for the mail. Nothing happens for an event nobody was invited to.
sub notify_attendees ($self, $event, %o) {
    my $list = $self->attendees_for($event->{id});
    return 0 unless @$list;
    my $db = $self->db;
    my $tx = $db->begin;
    my $seq = $o{bump} ? $self->bump_sequence($event->{id}, $db) : $event->{sequence};
    $db->query(q{UPDATE calendar.event_attendees SET status = 'needs-action', responded_at = NULL, comment = NULL WHERE event_id = ?}, $event->{id}) if $o{reset};
    for my $a (@$list) {
        $self->queue_notice(db => $db, event_id => $event->{id}, kind => 'request', recipient => $a->{email},
            payload => { reason => ($o{reason} // 'changed'), changed => ($o{changed} // []), sequence => $seq });
    }
    $tx->commit;
    return scalar @$list;
}

# The event is called off: a CANCEL to everyone who was sent the invitation;
# a pending invitation to anyone else is simply dropped.
sub cancel_attendees ($self, $event) {
    my $list = $self->attendees_for($event->{id});
    return 0 unless @$list;
    my $db = $self->db;
    my $tx = $db->begin;
    my $seq = $self->bump_sequence($event->{id}, $db);
    $db->query(q{DELETE FROM calendar.notice_queue WHERE event_id = ? AND kind = 'request' AND state = 'pending'}, $event->{id});
    for my $a (grep { defined $_->{sequence_sent} } @$list) {
        $self->queue_notice(db => $db, event_id => $event->{id}, kind => 'cancel', recipient => $a->{email},
            payload => { reason => 'cancelled', sequence => $seq, name => $a->{name} });
    }
    $tx->commit;
    return scalar @$list;
}

# The organizer's own copy of an attendee list for a new series split off an
# old one: the same people, fresh tokens, asked again.
sub copy_attendees ($self, $from_id, $to_id) {
    my $list = $self->attendees_for($from_id);
    return 0 unless @$list;
    for my $a (@$list) {
        $self->db->query('INSERT INTO calendar.event_attendees (event_id, email, name, token) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING',
            $to_id, $a->{email}, $a->{name}, $self->new_token);
        $self->queue_notice(event_id => $to_id, kind => 'request', recipient => $a->{email}, payload => { reason => 'invited' });
    }
    return scalar @$list;
}

# --- the notice queue: the same claim pattern as reminders ---

# queue_notice(event_id, kind, recipient, payload => {}, due_at => DateTime)
# A request replaces a pending request to the same person and waits a few
# seconds, so three quick edits send one mail, rendered from the event as it
# then is. Cancels and replies go at once.
sub queue_notice ($self, %n) {
    my $db = $n{db} // $self->db;
    my $kind = $n{kind};
    my $to = _norm($n{recipient});
    if ($kind eq 'request') {
        $db->query(q{DELETE FROM calendar.notice_queue WHERE event_id = ? AND lower(recipient) = ? AND kind = 'request' AND state = 'pending'}, $n{event_id}, $to);
    }
    my $due = $n{due_at} ? $n{due_at}->clone->set_time_zone('UTC')->strftime('%Y-%m-%d %H:%M:%S+00') : undef;
    $db->query(
        q{INSERT INTO calendar.notice_queue (event_id, kind, recipient, payload, due_at)
          VALUES (?, ?, ?, ?::jsonb, COALESCE(?::timestamptz, NOW() + (?::int * INTERVAL '1 second')))},
        $n{event_id}, $kind, $to, Mojo::JSON::encode_json($n{payload} // {}), $due, ($kind eq 'request' ? 20 : 0),
    );
    return 1;
}

sub claim_due_notices ($self, $limit = 3) {
    my $rows = $self->db->query(
        q{UPDATE calendar.notice_queue SET state = 'running', attempts = attempts + 1, claimed_at = NOW()
           WHERE id IN (SELECT id FROM calendar.notice_queue WHERE state = 'pending' AND due_at <= NOW()
                          ORDER BY due_at LIMIT ? FOR UPDATE SKIP LOCKED)
          RETURNING *}, $limit,
    )->hashes->to_array;
    return [ map { _decode_payload($_) } @$rows ];
}
sub _decode_payload ($r) {
    $r->{payload} = (defined $r->{payload} && !ref $r->{payload}) ? (eval { Mojo::JSON::decode_json($r->{payload}) } // {}) : ($r->{payload} // {});
    return $r;
}
sub notice_sent ($self, $id) {
    $self->db->query(q{UPDATE calendar.notice_queue SET state = 'sent', sent_at = NOW(), last_error = NULL WHERE id = ?}, $id);
    return 1;
}
sub notice_failed ($self, $id, $error, $max_attempts = 3) {
    $self->db->query(
        q{UPDATE calendar.notice_queue
             SET state = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END,
                 due_at = CASE WHEN attempts >= ? THEN due_at ELSE NOW() + INTERVAL '2 minutes' END,
                 last_error = ?
           WHERE id = ?}, $max_attempts, $max_attempts, substr($error // '', 0, 500), $id,
    );
    return 1;
}
sub reclaim_stale_notices ($self) {
    $self->db->query(q{UPDATE calendar.notice_queue SET state = 'pending' WHERE state = 'running' AND claimed_at < NOW() - INTERVAL '5 minutes'});
    $self->db->query(q{DELETE FROM calendar.notice_queue WHERE state IN ('sent', 'failed') AND created_at < NOW() - INTERVAL '30 days'});
    return 1;
}
# The invitation went out: remember which SEQUENCE this person has.
sub attendee_mark_sent ($self, $event_id, $email, $sequence) {
    $self->db->query('UPDATE calendar.event_attendees SET sequence_sent = ? WHERE event_id = ? AND lower(email) = ?', $sequence, $event_id, _norm($email));
    return 1;
}
sub notices_for ($self, $event_id) {
    return [ map { _decode_payload($_) } @{ $self->db->query('SELECT * FROM calendar.notice_queue WHERE event_id = ? ORDER BY id', $event_id)->hashes->to_array } ];
}

# --- free/busy (Gardner, 2026-11-15: yes, for accounts here) ---
# For each address: whether it has a calendar here (known) and, if so, the
# timed occurrences on its own calendars inside the window, as bare
# intervals -- no titles, no places. All-day events count as free, as
# Google's do. At most 20 addresses and 31 days.
sub freebusy ($self, $emails, $ws, $we) {
    die "At most 20 addresses at a time.\n" if @{ $emails // [] } > 20;
    die "The window must be a start before an end, at most 31 days apart.\n" unless $ws && $we && $we > $ws && $we->epoch - $ws->epoch <= 31 * 86400;
    my (%seen, @out);
    for my $raw (@$emails) {
        my ($e) = parse_attendee($raw) or next;
        next if $seen{$e}++;
        my $cals = $self->db->query('SELECT * FROM calendar.calendars WHERE lower(owner_email) = ? AND deleted_at IS NULL', $e)->hashes->to_array;
        unless (@$cals) { push @out, { email => $e, known => 0, busy => [] }; next }
        my $inst = $self->instances(calendars => $cals, window_start => $ws, window_end => $we);
        push @out, { email => $e, known => 1, busy => [ map { { start => $_->{start}, end => $_->{end} } } grep { !$_->{all_day} } @$inst ] };
    }
    return \@out;
}

# --- answers that came by mail (phase 2): the milter's rows, applied here ---

sub claim_itip_inbox ($self, $limit = 10) {
    return $self->db->query(
        q{UPDATE calendar.itip_inbox SET processed_at = NOW(), result = 'running'
           WHERE id IN (SELECT id FROM calendar.itip_inbox WHERE processed_at IS NULL ORDER BY received_at LIMIT ? FOR UPDATE SKIP LOCKED)
          RETURNING *}, $limit,
    )->hashes->to_array;
}
sub itip_result ($self, $id, $result) {
    $self->db->query('UPDATE calendar.itip_inbox SET result = ? WHERE id = ?', substr($result // '', 0, 200), $id);
    return 1;
}
# One mailed answer: the live event by UID, the attendee by address, then
# the status (an older SEQUENCE than the one sent is ignored). The sentence
# returned is what itip_inbox.result records.
sub apply_itip_reply ($self, $row) {
    my $event = $self->event_by_uid($row->{uid}) or return 'no live event with that uid';
    my $att = $self->attendee_of($event->{id}, $row->{attendee_email}) or return 'not an attendee of that event';
    return 'an answer to an older invitation' if defined $row->{sequence} && defined $att->{sequence_sent} && $row->{sequence} < $att->{sequence_sent};
    my %p = ('NEEDS-ACTION' => 'needs-action', ACCEPTED => 'accepted', TENTATIVE => 'tentative', DECLINED => 'declined');
    my $status = $p{ uc($row->{partstat} // '') } or return "unknown PARTSTAT '$row->{partstat}'";
    return 'no answer yet' if $status eq 'needs-action';
    $self->set_attendee_status($att, $status, comment => $row->{comment}, via => 'mail');
    return "recorded: $status";
}

# -------------------------------------------------------------------- prefs

my %PREF_DEFAULTS = (timezone => undef, device_zone => undef, week_start => 0, time_format => '12h', default_view => 'month', show_shared_events => 1,
    # 0.2.0 (#83): the defaults that were hard-coded, and two reminder switches.
    default_reminder_minutes => 10, all_day_reminder_hour => 9, default_duration_minutes => 60, date_format => 'mdy',
    remind_shared => 1, webhook_url => undef);

sub prefs ($self, $email) {
    my $row = $self->db->query('SELECT * FROM calendar.user_prefs WHERE user_email = ?', _norm($email))->hash // {};
    my %p = (%PREF_DEFAULTS, map { $_ => $row->{$_} } grep { defined $row->{$_} } keys %PREF_DEFAULTS);
    $p{$_} = $p{$_} ? 1 : 0 for qw(show_shared_events remind_shared);
    $p{$_} += 0 for qw(week_start default_reminder_minutes all_day_reminder_hour default_duration_minutes);
    return \%p;
}

sub save_prefs ($self, $email, $f) {
    my %v;
    if (exists $f->{timezone}) {
        die "Unknown time zone '$f->{timezone}'.\n" if defined $f->{timezone} && length $f->{timezone} && !validate_zone($f->{timezone});
        $v{timezone} = (defined $f->{timezone} && length $f->{timezone}) ? $f->{timezone} : undef;
    }
    # The device's zone (#88): what the browser last reported, for mail written
    # while nobody is looking. Only kept when it is a real zone.
    if (exists $f->{device_zone}) {
        die "Unknown time zone '$f->{device_zone}'.\n" if defined $f->{device_zone} && length $f->{device_zone} && !validate_zone($f->{device_zone});
        $v{device_zone} = (defined $f->{device_zone} && length $f->{device_zone}) ? $f->{device_zone} : undef;
        $v{device_zone_at} = DateTime->now(time_zone => 'UTC')->strftime('%Y-%m-%d %H:%M:%S+00');
    }
    if (exists $f->{week_start}) {
        die "week_start must be 0 (Sunday), 1 (Monday) or 6 (Saturday).\n" unless defined $f->{week_start} && $f->{week_start} =~ /\A[016]\z/;
        $v{week_start} = $f->{week_start} + 0;
    }
    if (exists $f->{time_format}) {
        die "time_format must be 12h or 24h.\n" unless ($f->{time_format} // '') =~ /\A(?:12h|24h)\z/;
        $v{time_format} = $f->{time_format};
    }
    if (exists $f->{default_view}) {
        die "default_view must be month, week, day or agenda.\n" unless ($f->{default_view} // '') =~ /\A(?:month|week|day|agenda)\z/;
        $v{default_view} = $f->{default_view};
    }
    if (exists $f->{show_shared_events}) { $v{show_shared_events} = $f->{show_shared_events} ? 1 : 0 }
    if (exists $f->{remind_shared})      { $v{remind_shared} = $f->{remind_shared} ? 1 : 0 }
    if (exists $f->{default_reminder_minutes}) {
        my $x = $f->{default_reminder_minutes};
        die "The default reminder must be a number of minutes (0 to 20160).\n" unless defined $x && $x =~ /\A\d+\z/ && $x <= 20160;
        $v{default_reminder_minutes} = $x + 0;
    }
    if (exists $f->{all_day_reminder_hour}) {
        my $x = $f->{all_day_reminder_hour};
        die "The all-day reminder hour must be 0 to 23.\n" unless defined $x && $x =~ /\A\d{1,2}\z/ && $x <= 23;
        $v{all_day_reminder_hour} = $x + 0;
    }
    if (exists $f->{default_duration_minutes}) {
        my $x = $f->{default_duration_minutes};
        die "The default length must be 5 to 1440 minutes.\n" unless defined $x && $x =~ /\A\d+\z/ && $x >= 5 && $x <= 1440;
        $v{default_duration_minutes} = $x + 0;
    }
    if (exists $f->{date_format}) {
        die "date_format must be mdy, dmy or ymd.\n" unless ($f->{date_format} // '') =~ /\A(?:mdy|dmy|ymd)\z/;
        $v{date_format} = $f->{date_format};
    }
    if (exists $f->{webhook_url}) {
        my $u = defined $f->{webhook_url} && !ref $f->{webhook_url} ? ($f->{webhook_url} =~ s/\A\s+|\s+\z//gr) : '';
        die "The webhook must be an http(s) URL of at most 500 characters.\n" if length $u && ($u !~ m{\Ahttps?://\S+\z} || length $u > 500);
        $v{webhook_url} = length $u ? $u : undef;
    }
    return $self->prefs($email) unless %v;
    my @cols = sort keys %v;
    $self->db->query(
        'INSERT INTO calendar.user_prefs (user_email, ' . join(', ', @cols) . ') VALUES (?, ' . join(', ', ('?') x @cols) . ')'
        . ' ON CONFLICT (user_email) DO UPDATE SET ' . join(', ', (map { "$_ = EXCLUDED.$_" } @cols), 'updated_at = NOW()'),
        _norm($email), (map { $v{$_} } @cols),
    );
    return $self->prefs($email);
}

1;
