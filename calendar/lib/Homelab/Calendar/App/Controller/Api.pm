package Homelab::Calendar::App::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime;
use Mojo::Util qw(url_escape);
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::Calendar::Recurrence qw(validate_zone parse_wall wall_string parse_rrule);
use Homelab::Calendar::Access qw(may_edit may_manage);
use Homelab::Calendar::ICS qw(masters_ics);

# The JSON the page talks to. Every route: signed in (require_login), and for
# a write, the page's CSRF token (csrf_ok). Permission is asked here, once
# per route, through the model's Access-backed helpers; the model trusts us.
#
# Dates on the wire: wall-clock strings with no offset plus a zone name
# ('2026-11-14T09:00:00', timezone 'America/Chicago'; all-day: '2026-11-14'),
# because FullCalendar in a named zone works in wall-clock time and ignores
# offsets (see templates/calendar.js.ep). A repeating event's occurrence is
# named by its recurrence_id, the ORIGINAL start instant as UTC
# ('2026-11-02T15:00:00Z').

sub _model ($c) { return $c->app->model }

sub _fail ($c, $status, $msg) { return $c->render(json => { error => $msg }, status => $status) }

sub _body ($c) {
    my $b = $c->req->json;
    return (ref $b eq 'HASH') ? $b : {};
}

# A model die()s with a one-line reason meant for the person.
sub _try ($c, $code) {
    my $r = eval { $code->() };
    return $r unless $@;
    my $err = $@;
    $c->app->log->error("calendar: $err") if $err =~ /\bat .+ line \d+/;    # a real bug, not a validation message
    $err =~ s/ at \S+ line \d+.*//s;
    _fail($c, 400, $err =~ /\S/ ? $err : 'That did not work.');
    return undef;
}

sub _audit ($c, %a) {
    my $me = $c->session_email;
    eval {
        enqueue($c->app->pg->db,
            actor_email => $me, affected_user => $a{affected_user} // $me, jti => $c->stash('calendar.session_jti'),
            action => $a{action}, resource_type => $a{resource_type}, resource_id => "$a{resource_id}",
            source_service => 'homelab-calendar', ip_address => $c->tx->remote_address,
            user_agent => $c->req->headers->user_agent, detail => $a{detail} // {},
        );
        1;
    } or $c->app->log->warn("calendar: audit enqueue failed ($a{action}): $@");
    return;
}

sub _rid ($s) {
    return undef unless defined $s && length $s;
    my ($y, $m, $d, $H, $M, $S) = $s =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z\z/ or return undef;
    return eval { DateTime->new(year => $y, month => $m, day => $d, hour => $H, minute => $M, second => $S, time_zone => 'UTC') };
}
sub _rid_str ($dt) { return $dt ? $dt->clone->set_time_zone('UTC')->strftime('%Y-%m-%dT%H:%M:%SZ') : undef }

sub _calendar_json ($cal) {
    return {
        id => $cal->{id} + 0, name => $cal->{name}, color => $cal->{color}, description => $cal->{description},
        timezone => $cal->{timezone}, is_default => ($cal->{is_default} ? \1 : \0), permission => $cal->{permission},
        visible => ($cal->{visible} ? \1 : \0), owner_email => $cal->{owner_email},
    };
}

# One occurrence as the event object FullCalendar wants.
sub _fc_event ($inst, $zone, $permission, $detail = 'full') {
    my $all_day = $inst->{all_day};
    my $start = $all_day ? $inst->{start}->ymd : wall_string($inst->{start}->clone->set_time_zone($zone));
    my $end   = $all_day ? $inst->{end}->ymd   : wall_string($inst->{end}->clone->set_time_zone($zone));
    my $rid   = _rid_str($inst->{recurrence_id});
    my $busy  = $detail eq 'busy';
    my $color = $inst->{color} // $inst->{calendar_color};
    return {
        id => $inst->{event_id} . ($rid ? ':' . ($rid =~ tr/-://dr) : ''),
        title => $busy ? 'Busy' : $inst->{title},
        start => $start, end => $end, allDay => ($all_day ? \1 : \0),
        ($color ? (backgroundColor => $color, borderColor => $color) : ()),
        editable => (may_edit($permission) ? \1 : \0),
        extendedProps => {
            event_id => $inst->{event_id} + 0, recurrence_id => $rid, calendar_id => $inst->{calendar_id} + 0,
            permission => $permission, is_recurring => ($inst->{is_recurring} ? \1 : \0),
            is_exception => ($inst->{is_exception} ? \1 : \0),
            ($busy ? () : (description => $inst->{description}, location => $inst->{location})),
            uid => $inst->{uid}, timezone => $inst->{event}{timezone},
        },
    };
}

# The window a view asks for: offset-less wall clocks in timeZone, from
# FullCalendar; also accepts ISO with an offset (ignored, as FullCalendar
# itself does). At most three years, so a feed cannot ask for a century.
sub _window ($c, $zone) {
    my $ws = parse_wall($c->param('start'), $zone);
    my $we = parse_wall($c->param('end'), $zone);
    unless ($ws && $we) {
        my $now = DateTime->now(time_zone => $zone)->truncate(to => 'month');
        $ws //= $now->clone->subtract(months => 1);
        $we //= $now->clone->add(months => 2);
    }
    return () unless $we > $ws;
    return () if $we->epoch - $ws->epoch > 3 * 366 * 86400;
    return ($ws, $we);
}

# --- calendars -------------------------------------------------------------

sub calendars ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $prefs = $m->prefs($me);
    $m->ensure_default_calendar($me, $c->viewer_zone($prefs));
    my $cals = $m->calendars_for($me);
    return $c->render(json => {
        me => $me, prefs => $prefs, account_zone => $c->stash('calendar.account_zone'),
        own    => [ map { _calendar_json($_) } @{ $cals->{own} } ],
        shared => [ map { _calendar_json($_) } @{ $cals->{shared} } ],
    });
}

sub create_calendar ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $b = _body($c);
    my $name = ($b->{name} // '') =~ s/\A\s+|\s+\z//gr;
    return _fail($c, 400, 'Give the calendar a name.') unless length $name;
    return _fail($c, 400, 'The name is too long (100 characters at most).') if length $name > 100;
    return _fail($c, 400, 'The colour must look like #1a2b3c.') if defined $b->{color} && $b->{color} !~ /\A#[0-9a-fA-F]{6}\z/;
    return _fail($c, 400, "Unknown time zone.") if defined $b->{timezone} && length $b->{timezone} && !validate_zone($b->{timezone});
    my $cal = _model($c)->create_calendar($me, name => $name, color => $b->{color}, description => $b->{description},
        timezone => (length($b->{timezone} // '') ? $b->{timezone} : $c->viewer_zone));
    $cal->{permission} = 'owner'; $cal->{visible} = 1;
    return $c->render(json => _calendar_json($cal), status => 201);
}

sub _owned_calendar ($c, $me) {
    my $cal = _model($c)->calendar($c->stash('id'));
    return (_fail($c, 404, 'No such calendar.'), undef) unless $cal;
    my $perm = _model($c)->permission_for_calendar($me, $cal);
    return (_fail($c, 404, 'No such calendar.'), undef) unless $perm;
    return (_fail($c, 403, 'Only the owner can change this calendar.'), undef) unless may_manage($perm);
    $cal->{permission} = $perm;
    return (undef, $cal);
}

sub update_calendar ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $cal) = _owned_calendar($c, $me); return $err if $err;
    my $b = _body($c);
    my %f;
    if (exists $b->{name}) {
        my $name = ($b->{name} // '') =~ s/\A\s+|\s+\z//gr;
        return _fail($c, 400, 'Give the calendar a name.') unless length $name;
        return _fail($c, 400, 'The name is too long (100 characters at most).') if length $name > 100;
        $f{name} = $name;
    }
    if (exists $b->{color}) {
        return _fail($c, 400, 'The colour must look like #1a2b3c.') unless ($b->{color} // '') =~ /\A#[0-9a-fA-F]{6}\z/;
        $f{color} = $b->{color};
    }
    if (exists $b->{timezone}) {
        return _fail($c, 400, 'Unknown time zone.') unless validate_zone($b->{timezone});
        $f{timezone} = $b->{timezone};
    }
    $f{description} = $b->{description} if exists $b->{description};
    $f{position} = $b->{position} + 0 if defined $b->{position} && $b->{position} =~ /\A\d+\z/;
    my $row = _model($c)->update_calendar($cal->{id}, %f);
    $row->{permission} = 'owner'; $row->{visible} = 1;
    return $c->render(json => _calendar_json($row));
}

sub delete_calendar ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $cal) = _owned_calendar($c, $me); return $err if $err;
    _model($c)->delete_calendar($cal);
    _audit($c, action => 'calendar.calendar_delete', resource_type => 'calendar', resource_id => $cal->{id}, detail => { name => $cal->{name} });
    return $c->render(json => { ok => \1 });
}

sub set_visible ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $cal = _model($c)->calendar($c->stash('id')) or return _fail($c, 404, 'No such calendar.');
    _model($c)->permission_for_calendar($me, $cal) or return _fail($c, 404, 'No such calendar.');
    _model($c)->set_visibility($me, $cal->{id}, _body($c)->{visible} ? 1 : 0);
    return $c->render(json => { ok => \1 });
}

# --- events ----------------------------------------------------------------

# GET /api/events?start&end&timeZone -- every occurrence in the window on the
# calendars this account has ticked, plus events shared to it one by one.
sub events ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $prefs = $m->prefs($me);
    my $zone = $c->viewer_zone($prefs);
    my ($ws, $we) = _window($c, $zone);
    return _fail($c, 400, 'The window must be a start before an end, at most three years apart.') unless $ws;

    my $cals = $m->calendars_for($me);
    my @visible = grep { $_->{visible} } @{ $cals->{own} }, @{ $cals->{shared} };
    my %perm  = map { $_->{id} => $_->{permission} } @visible;
    my %color = map { $_->{id} => $_->{color} } @visible;
    my @out;
    for my $inst (@{ $m->instances(calendars => \@visible, window_start => $ws, window_end => $we) }) {
        $inst->{calendar_color} = $color{ $inst->{calendar_id} };
        push @out, _fc_event($inst, $zone, $perm{ $inst->{calendar_id} });
    }
    # Single events shared to me, unless the sidebar's "Shared events" is off.
    if ($prefs->{show_shared_events}) {
        my $shares = $m->viewer_event_shares($me);
        my %ev_perm;
        for my $s (@$shares) {
            my $p = $s->{permission} eq 'edit' ? 'edit' : 'read';
            $ev_perm{ $s->{event_id} } = $p if !$ev_perm{ $s->{event_id} } || $p eq 'edit';
        }
        # Not the ones already shown through a shared calendar.
        delete $ev_perm{$_} for grep { my $e = $m->event($_); $e && $perm{ $e->{calendar_id} } } keys %ev_perm;
        if (%ev_perm) {
            my @events = grep { $_ && $m->calendar($_->{calendar_id}) } map { $m->event($_) } sort keys %ev_perm;
            for my $inst (@{ $m->instances(events => \@events, window_start => $ws, window_end => $we) }) {
                my $fc = _fc_event($inst, $zone, $ev_perm{ $inst->{event_id} });
                $fc->{extendedProps}{shared_event} = \1;
                push @out, $fc;
            }
        }
    }
    return $c->render(json => \@out);
}

sub _event_for ($c, $me, $need_edit) {
    my $m = _model($c);
    my $event = $m->event($c->stash('id'));
    return (_fail($c, 404, 'No such event.'), undef, undef) unless $event;
    my $cal = $m->calendar($event->{calendar_id});
    return (_fail($c, 404, 'No such event.'), undef, undef) unless $cal;
    my $perm = $m->permission_for_event($me, $event, $cal);
    return (_fail($c, 404, 'No such event.'), undef, undef) unless $perm;
    return (_fail($c, 403, 'You can see this event but not change it.'), undef, undef) if $need_edit && !may_edit($perm);
    $event->{permission} = $perm;
    return (undef, $event, $cal);
}

sub _event_json ($c, $event, $cal, $zone, $rid = undef) {
    my $m = _model($c);
    my $start = $m->event_start($event);
    my $end   = $m->event_end($event);
    my %j = (
        id => $event->{id} + 0, calendar_id => $event->{calendar_id} + 0, uid => $event->{uid},
        title => $event->{title}, description => $event->{description}, location => $event->{location},
        all_day => ($event->{all_day} ? \1 : \0), event_timezone => $event->{timezone}, timezone => $zone,
        start => $event->{all_day} ? $start->ymd : wall_string($start->clone->set_time_zone($zone)),
        end   => $event->{all_day} ? $end->ymd   : wall_string($end->clone->set_time_zone($zone)),
        rrule => $event->{rrule}, repeat => ($event->{rrule} ? parse_rrule($event->{rrule}, $event->{timezone}) : undef),
        color => $event->{color}, permission => $event->{permission}, is_recurring => ($event->{rrule} ? \1 : \0),
        created_by_email => $event->{created_by_email},
        calendar => { id => $cal->{id} + 0, name => $cal->{name}, color => $cal->{color}, owner_email => $cal->{owner_email} },
    );
    if ($rid && $event->{rrule}) {
        my ($inst) = grep { $_->{recurrence_id} && $_->{recurrence_id}->epoch == $rid->epoch }
            @{ $m->instances(events => [$event], window_start => $rid->clone->subtract(days => 1), window_end => $rid->clone->add(days => 400)) };
        # A moved occurrence may sit well away from its recurrence_id; look it
        # up directly when the window above missed it.
        if (!$inst) {
            my $x = (grep { Homelab::Calendar::Model::_dt($_->{recurrence_id})->epoch == $rid->epoch } @{ $m->exceptions_for($event->{id}) })[0];
            $inst = $m->_exception_instance($event, $x, $rid->clone->set_time_zone($event->{timezone})) if $x && !$x->{cancelled};
        }
        if ($inst) {
            $j{occurrence} = {
                recurrence_id => _rid_str($rid), is_exception => ($inst->{is_exception} ? \1 : \0),
                all_day => ($inst->{all_day} ? \1 : \0),
                start => $inst->{all_day} ? $inst->{start}->ymd : wall_string($inst->{start}->clone->set_time_zone($zone)),
                end   => $inst->{all_day} ? $inst->{end}->ymd   : wall_string($inst->{end}->clone->set_time_zone($zone)),
                title => $inst->{title}, description => $inst->{description}, location => $inst->{location}, color => $inst->{color},
            };
        }
    }
    return \%j;
}

sub event ($c) {
    my $me = $c->require_login or return;
    my ($err, $event, $cal) = _event_for($c, $me, 0); return $err if $err;
    my $zone = $c->viewer_zone(_model($c)->prefs($me));
    return $c->render(json => _event_json($c, $event, $cal, $zone, _rid($c->param('recurrence_id'))));
}

# The editor's fields, picked out of the body. 'repeat' is a form (see
# Recurrence::build_rrule) or null; 'timezone' names the zone the wall clocks
# are in (the viewer's, normally).
sub _event_input ($c, $b, $zone) {
    my %in;
    for my $k (qw(title description location color all_day start end repeat)) { $in{$k} = $b->{$k} if exists $b->{$k} }
    $in{timezone} = (defined $b->{timezone} && validate_zone($b->{timezone})) ? $b->{timezone} : $zone;
    return \%in;
}

sub create_event ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $b = _body($c);
    my $cal = $m->calendar($b->{calendar_id}) or return _fail($c, 404, 'No such calendar.');
    my $perm = $m->permission_for_calendar($me, $cal) or return _fail($c, 404, 'No such calendar.');
    return _fail($c, 403, 'You can see this calendar but not add to it.') unless may_edit($perm);
    my $zone = $c->viewer_zone($m->prefs($me));
    my $event = _try($c, sub { $m->create_event($cal, $me, _event_input($c, $b, $zone)) }) or return;
    $event->{permission} = $perm;
    return $c->render(json => _event_json($c, $event, $cal, $zone), status => 201);
}

sub update_event ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $event, $cal) = _event_for($c, $me, 1); return $err if $err;
    my $m = _model($c);
    my $b = _body($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my $scope = ($b->{scope} // 'all') =~ /\A(?:all|this|following)\z/ ? $b->{scope} // 'all' : 'all';
    my $rid = _rid($b->{recurrence_id});
    return _fail($c, 400, 'Say which occurrence (recurrence_id) when changing this one or the following ones.')
        if $scope ne 'all' && $event->{rrule} && !$rid;
    my $row = _try($c, sub { $m->update_event($event, _event_input($c, $b, $zone), scope => $scope, recurrence_id => $rid) }) or return;
    $row->{permission} = $event->{permission};
    return $c->render(json => _event_json($c, $row, $cal, $zone));
}

sub delete_event ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $event, $cal) = _event_for($c, $me, 1); return $err if $err;
    my $b = _body($c);
    my $scope = ($b->{scope} // 'all') =~ /\A(?:all|this|following)\z/ ? $b->{scope} // 'all' : 'all';
    my $rid = _rid($b->{recurrence_id});
    return _fail($c, 400, 'Say which occurrence (recurrence_id) when removing this one or the following ones.')
        if $scope ne 'all' && $event->{rrule} && !$rid;
    _model($c)->delete_event($event, scope => $scope, recurrence_id => $rid);
    return $c->render(json => { ok => \1 });
}

# --- shares ----------------------------------------------------------------

sub _share_json ($c, $s) {
    my $base = $c->app->public_base_url;
    my $path = $s->{calendar_id} ? "/c/$s->{token}" : "/e/$s->{token}";
    return {
        id => $s->{id} + 0, calendar_id => ($s->{calendar_id} ? $s->{calendar_id} + 0 : undef),
        event_id => ($s->{event_id} ? $s->{event_id} + 0 : undef),
        shared_with_email => $s->{shared_with_email}, permission => $s->{permission}, detail => $s->{detail},
        expires_at => $s->{expires_at}, created_at => $s->{created_at}, accessed_at => $s->{accessed_at},
        access_count => ($s->{access_count} // 0) + 0,
        url => $base . $path, ($s->{calendar_id} || $s->{event_id} ? (ics_url => "$base$path.ics") : ()),
    };
}

sub calendar_shares ($c) {
    my $me = $c->require_login or return;
    my ($err, $cal) = _owned_calendar($c, $me); return $err if $err;
    return $c->render(json => [ map { _share_json($c, $_) } @{ _model($c)->shares_for_calendar($cal->{id}) } ]);
}

sub _share_input ($c, $b) {
    my $email = $b->{email};
    $email = undef if defined $email && $email !~ /\S/;
    if (defined $email) {
        $email = lc($email =~ s/\A\s+|\s+\z//gr);
        return (_fail($c, 400, 'That does not look like an email address.'), undef)
            unless $email =~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/ && length $email <= 254;
        return (_fail($c, 400, 'You already have access to your own calendar.'), undef) if $email eq $c->session_email;
    }
    my $perm = ($b->{permission} // 'read') eq 'edit' ? 'edit' : 'read';
    return (_fail($c, 400, 'A link can only be read-only; share with a person to let them edit.'), undef) if $perm eq 'edit' && !defined $email;
    my $detail = ($b->{detail} // 'full') eq 'busy' ? 'busy' : 'full';
    my $days = $b->{expires_days};
    return (_fail($c, 400, 'expires_days must be a number of days.'), undef) if defined $days && length $days && $days !~ /\A\d{1,4}\z/;
    return (undef, { shared_with_email => $email, permission => $perm, detail => $detail, expires_days => (length($days // '') ? $days : undef) });
}

sub create_calendar_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $cal) = _owned_calendar($c, $me); return $err if $err;
    my ($e2, $in) = _share_input($c, _body($c)); return $e2 if $e2;
    my $share = _model($c)->create_share(owner => $me, calendar_id => $cal->{id}, %$in);
    _audit($c, action => 'calendar.share_create', resource_type => 'calendar_share', resource_id => $share->{id},
        affected_user => $in->{shared_with_email} // $me,
        detail => { calendar_id => $cal->{id}, with => $in->{shared_with_email}, permission => $in->{permission}, detail => $in->{detail} });
    _notify_share($c, $share, "the calendar \"$cal->{name}\"") if $in->{shared_with_email};
    return $c->render(json => _share_json($c, $share), status => 201);
}

sub event_shares ($c) {
    my $me = $c->require_login or return;
    my ($err, $event, $cal) = _event_for($c, $me, 0); return $err if $err;
    return _fail($c, 403, 'Only the calendar owner can share an event.') unless may_manage($event->{permission});
    return $c->render(json => [ map { _share_json($c, $_) } @{ _model($c)->shares_for_event($event->{id}) } ]);
}

sub create_event_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my ($err, $event, $cal) = _event_for($c, $me, 0); return $err if $err;
    return _fail($c, 403, 'Only the calendar owner can share an event.') unless may_manage($event->{permission});
    my ($e2, $in) = _share_input($c, _body($c)); return $e2 if $e2;
    my $share = _model($c)->create_share(owner => $me, event_id => $event->{id}, %$in);
    _audit($c, action => 'calendar.share_create', resource_type => 'calendar_share', resource_id => $share->{id},
        affected_user => $in->{shared_with_email} // $me,
        detail => { event_id => $event->{id}, with => $in->{shared_with_email}, permission => $in->{permission} });
    _notify_share($c, $share, "the event \"$event->{title}\"") if $in->{shared_with_email};
    return $c->render(json => _share_json($c, $share), status => 201);
}

sub revoke_share ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $share = $m->share($c->stash('id'));
    return _fail($c, 404, 'No such share.') unless $share && lc($share->{owner_email}) eq $me;
    $m->revoke_share($share->{id});
    _audit($c, action => 'calendar.share_revoke', resource_type => 'calendar_share', resource_id => $share->{id},
        affected_user => $share->{shared_with_email} // $me, detail => { with => $share->{shared_with_email} });
    return $c->render(json => { ok => \1 });
}

# A note to the person a calendar or event was shared with. Best effort: the
# share exists whether or not the mail goes out, and the page says so.
sub _notify_share ($c, $share, $what) {
    my $m = $c->app->mailer or return;
    my $to = $share->{shared_with_email} or return;
    my $me = $c->session_email;
    my $url = $c->app->public_base_url . ($share->{calendar_id} ? "/c/$share->{token}" : "/e/$share->{token}");
    my $can = $share->{permission} eq 'edit' ? 'see and edit' : 'see';
    eval {
        require Homelab::Common::Mailer;
        Homelab::Common::Mailer::send_mail(
            smtp_host => $m->{smtp_host}, smtp_port => $m->{smtp_port} // 587,
            from_email => $m->{email}, from_password => $m->{smtp_password},
            to => $to, subject => "$me shared $what with you",
            body => "$me shared $what with you on Calendar. You can $can it.\n\n"
                  . "Open it here (sign in as $to):\n$url\n\n"
                  . "It is also in your own calendar list at " . $c->app->public_base_url . "/ .\n",
        );
        1;
    } or $c->app->log->warn("calendar: share notification to $to failed: $@");
    return;
}

# --- export ----------------------------------------------------------------

# GET /api/calendars/:id/export.ics -- the whole calendar with its rules, for
# carrying it somewhere else.
sub export ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $cal = $m->calendar($c->stash('id')) or return _fail($c, 404, 'No such calendar.');
    $m->permission_for_calendar($me, $cal) or return _fail($c, 404, 'No such calendar.');
    my $events = $m->db->query('SELECT * FROM calendar.events WHERE calendar_id = ? AND deleted_at IS NULL ORDER BY starts_at', $cal->{id})->hashes->to_array;
    my @out;
    for my $e (@$events) {
        my %x = (uid => $e->{uid}, title => $e->{title}, description => $e->{description}, location => $e->{location},
            all_day => $e->{all_day} ? 1 : 0, start => $m->event_start($e), end => $m->event_end($e),
            created => Homelab::Calendar::Model::_dt($e->{created_at}), updated => Homelab::Calendar::Model::_dt($e->{updated_at}),
            rrule => $e->{rrule});
        if ($e->{rrule}) {
            my (@ex, @ov);
            for my $x (@{ $m->exceptions_for($e->{id}) }) {
                my $rid = Homelab::Calendar::Model::_dt($x->{recurrence_id}, $e->{timezone});
                if ($x->{cancelled}) { push @ex, $rid; next }
                my $inst = $m->_exception_instance($e, $x, $rid);
                push @ov, { recurrence_id => $rid, start => $inst->{start}, end => $inst->{end}, all_day => $inst->{all_day},
                    title => $inst->{title}, description => $inst->{description}, location => $inst->{location} };
            }
            $x{exdates} = \@ex; $x{overrides} = \@ov;
        }
        push @out, \%x;
    }
    my $ics = masters_ics(name => $cal->{name}, zone => $cal->{timezone}, description => $cal->{description}, events => \@out);
    my $fname = ($cal->{name} =~ s/[^A-Za-z0-9._-]+/_/gr) || 'calendar';
    $c->res->headers->content_type('text/calendar; charset=utf-8');
    $c->res->headers->content_disposition("attachment; filename=\"$fname.ics\"");
    return $c->render(data => $ics);
}

# --- preferences -----------------------------------------------------------

sub prefs ($c) {
    my $me = $c->require_login or return;
    return $c->render(json => _model($c)->prefs($me));
}

sub save_prefs ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $p = _try($c, sub { _model($c)->save_prefs($me, _body($c)) }) or return;
    return $c->render(json => $p);
}

1;
