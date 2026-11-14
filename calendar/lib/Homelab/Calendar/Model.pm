package Homelab::Calendar::Model;
use Mojo::Base -base, -signatures;
use DateTime;
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

my @EVENT_FIELDS = qw(title description location all_day starts_at ends_at start_date end_date timezone rrule recurrence_end color);

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

    my ($start, $end);
    if (defined $input->{start} && length $input->{start}) {
        $start = parse_wall($input->{start}, $zone) or die "The start must look like 2026-11-14T09:00:00.\n";
    }
    elsif ($base) {
        $start = $self->event_start($base)->set_time_zone($zone);
    }
    die "Give the event a start.\n" unless $start;
    if (defined $input->{end} && length $input->{end}) {
        $end = parse_wall($input->{end}, $zone) or die "The end must look like 2026-11-14T10:00:00.\n";
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
    my @vals = ((map { $v->{$_} } @EVENT_FIELDS), $cal->{id}, $self->new_uid, _norm($email));
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
    my $zone = $in{timezone} // $event->{timezone};
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
    my $time_changed = grep { ($v->{$_} // '') ne ($event->{$_} // '') } qw(starts_at ends_at rrule all_day);
    my @set = map { "$_ = ?" } @EVENT_FIELDS;
    my $db = $self->db;
    my $tx = $db->begin;
    my $row = $db->query('UPDATE calendar.events SET ' . join(', ', @set, 'updated_at = NOW()') . ' WHERE id = ? RETURNING *',
        (map { $v->{$_} } @EVENT_FIELDS), $event->{id})->hash;
    # Moving or re-ruling a series makes its per-occurrence edits meaningless
    # (they key on the old occurrence instants), so they go; a retitle keeps them.
    $db->query('DELETE FROM calendar.event_exceptions WHERE event_id = ?', $event->{id}) if $time_changed && $event->{rrule};
    $tx->commit;
    return $row;
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
    $self->db->query(
        'INSERT INTO calendar.event_exceptions (event_id, recurrence_id, ' . join(', ', @cols) . ') VALUES (?, ?, ' . join(', ', ('?') x @cols) . ')'
        . ' ON CONFLICT (event_id, recurrence_id) DO UPDATE SET ' . join(', ', (map { "$_ = EXCLUDED.$_" } @cols),
            # A cancel wipes an earlier move; an edit after a cancel revives it.
            ($cancelled ? () : map { "$_ = NULL" } grep { !exists $v{$_} } qw(title description location color all_day starts_at ends_at start_date end_date)),
            'updated_at = NOW()'),
        $event->{id}, $ridpg, (map { $v{$_} } @cols),
    );
    return $self->event($event->{id});
}

# The master's values with one occurrence's own start/end: the base an
# exception is validated against.
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
    my $time_changed = grep { ($v->{$_} // '') ne ($occ->{$_} // '') } qw(starts_at ends_at all_day);

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
    $tx->commit;
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
            $tx->commit;
            return 1;
        }
    }
    my $db = $self->db;
    my $tx = $db->begin;
    $db->query('UPDATE calendar.events SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?', $event->{id});
    $db->query('UPDATE calendar.shares SET revoked_at = NOW() WHERE event_id = ? AND revoked_at IS NULL', $event->{id});
    $tx->commit;
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

# -------------------------------------------------------------------- prefs

my %PREF_DEFAULTS = (timezone => undef, week_start => 0, time_format => '12h', default_view => 'month', show_shared_events => 1);

sub prefs ($self, $email) {
    my $row = $self->db->query('SELECT * FROM calendar.user_prefs WHERE user_email = ?', _norm($email))->hash // {};
    my %p = (%PREF_DEFAULTS, map { $_ => $row->{$_} } grep { defined $row->{$_} } keys %PREF_DEFAULTS);
    $p{show_shared_events} = $p{show_shared_events} ? 1 : 0;
    return \%p;
}

sub save_prefs ($self, $email, $f) {
    my %v;
    if (exists $f->{timezone}) {
        die "Unknown time zone '$f->{timezone}'.\n" if defined $f->{timezone} && length $f->{timezone} && !validate_zone($f->{timezone});
        $v{timezone} = (defined $f->{timezone} && length $f->{timezone}) ? $f->{timezone} : undef;
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
