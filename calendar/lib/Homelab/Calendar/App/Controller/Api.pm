package Homelab::Calendar::App::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime;
use Mojo::Util qw(url_escape);
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::Calendar::Recurrence qw(validate_zone parse_wall wall_string parse_rrule);
use Homelab::Calendar::Access qw(may_edit may_manage);
use Homelab::Calendar::ICS qw(masters_ics instances_ics);
use Homelab::Calendar::ICSImport qw(parse_ics);
use Homelab::Calendar::Consent ();
use Homelab::Calendar::MailExtract ();

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
    my @out;
    for my $inst (@{ _instances_for($m, $me, $ws, $we, visible_only => 1, shared_events => $prefs->{show_shared_events}) }) {
        my $fc = _fc_event($inst, $zone, $inst->{permission});
        $fc->{extendedProps}{shared_event} = \1 if $inst->{shared_event};
        push @out, $fc;
    }
    return $c->render(json => \@out);
}

# Every occurrence the account sees in [$ws, $we): its calendars (all of them,
# or with visible_only the ones ticked in the sidebar; or one, calendar_id),
# plus with shared_events the single events shared to it that no calendar
# above already shows. Each instance carries its permission, calendar_name,
# calendar_color and, for a shared single event, shared_event. Sorted by start.
sub _instances_for ($m, $me, $ws, $we, %o) {
    my $cals = $m->calendars_for($me);
    my @cals = grep { !$o{visible_only} || $_->{visible} } @{ $cals->{own} }, @{ $cals->{shared} };
    @cals = grep { $_->{id} == $o{calendar_id} } @cals if $o{calendar_id};
    my %perm  = map { $_->{id} => $_->{permission} } @cals;
    my %color = map { $_->{id} => $_->{color} } @cals;
    my %name  = map { $_->{id} => $_->{name} } @cals;
    my @out;
    for my $inst (@{ $m->instances(calendars => \@cals, window_start => $ws, window_end => $we) }) {
        $inst->{calendar_color} = $color{ $inst->{calendar_id} };
        $inst->{calendar_name}  = $name{ $inst->{calendar_id} };
        $inst->{permission}     = $perm{ $inst->{calendar_id} };
        push @out, $inst;
    }
    if ($o{shared_events} && !$o{calendar_id}) {
        my %ev_perm;
        for my $s (@{ $m->viewer_event_shares($me) }) {
            my $p = $s->{permission} eq 'edit' ? 'edit' : 'read';
            $ev_perm{ $s->{event_id} } = $p if !$ev_perm{ $s->{event_id} } || $p eq 'edit';
        }
        delete $ev_perm{$_} for grep { my $e = $m->event($_); $e && $perm{ $e->{calendar_id} } } keys %ev_perm;
        if (%ev_perm) {
            my (%shared_cal, @events);
            for my $e (grep { $_ } map { $m->event($_) } sort keys %ev_perm) {
                $shared_cal{ $e->{calendar_id} } //= $m->calendar($e->{calendar_id}) or next;
                push @events, $e;
            }
            for my $inst (@{ $m->instances(events => \@events, window_start => $ws, window_end => $we) }) {
                $inst->{permission}    = $ev_perm{ $inst->{event_id} };
                $inst->{calendar_name} = $shared_cal{ $inst->{calendar_id} }{name};
                $inst->{shared_event}  = 1;
                push @out, $inst;
            }
        }
    }
    return [ sort { $a->{start} <=> $b->{start} || $a->{title} cmp $b->{title} } @out ];
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
        # #79: minutes before each occurrence an email goes out, or null.
        reminder_minutes => do { my $r = $m->reminder_for($event->{id}); $r ? $r->{minutes_before} + 0 : undef },
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
    return _create_from_body($c, $me, _body($c));
}

# A new event from a body: the editor's, or homelab-cli's through the api
# (#82). The calendar is the one named, else the account's default one.
sub _create_from_body ($c, $me, $b) {
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my $cal = (defined $b->{calendar_id} && length $b->{calendar_id}) ? $m->calendar($b->{calendar_id}) : $m->ensure_default_calendar($me, $zone);
    return _fail($c, 404, 'No such calendar.') unless $cal;
    my $perm = $m->permission_for_calendar($me, $cal) or return _fail($c, 404, 'No such calendar.');
    return _fail($c, 403, 'You can see this calendar but not add to it.') unless may_edit($perm);
    # The Share field (#79): one address the new event is shared with, read-only.
    my $share_with = _share_with($c, $b, $me, $perm); return if $share_with && $share_with eq "\0";
    my $event = _try($c, sub { $m->create_event($cal, $me, _event_input($c, $b, $zone)) }) or return;
    $event->{permission} = $perm;
    if (exists $b->{reminder_minutes}) { _try($c, sub { $m->set_reminder($event->{id}, $b->{reminder_minutes}); 1 }) or return }
    # Created from a link in an email: the link remembers which event it
    # became, for this account (#81: a link may become several).
    if (my $link = (defined $b->{mail_link_token} ? $m->mail_link_for($b->{mail_link_token}, $me) : undef)) {
        $m->mail_link_used($link->{id}, $event->{id}, $me);
    }
    if ($share_with) {
        my $share = $m->create_share(owner => $me, event_id => $event->{id}, shared_with_email => $share_with, permission => 'read');
        _audit($c, action => 'calendar.share_create', resource_type => 'calendar_share', resource_id => $share->{id}, affected_user => $share_with,
            detail => { event_id => $event->{id}, with => $share_with, permission => 'read', at_creation => \1 });
        _notify_share($c, $share, "the event \"$event->{title}\"");
    }
    return $c->render(json => _event_json($c, $event, $cal, $zone), status => 201);
}

# The editor's "Share with" address on a new event: a valid address of
# someone else, and only the calendar's owner may share. Returns the
# address, '' for none, or "\0" after rendering an error.
sub _share_with ($c, $b, $me, $perm) {
    my $v = $b->{share_with};
    return '' unless defined $v && !ref $v && $v =~ /\S/;
    my $email = lc($v =~ s/\A\s+|\s+\z//gr);
    unless ($email =~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/ && length $email <= 254) { _fail($c, 400, 'The "Share with" address does not look like an email address.'); return "\0" }
    if ($email eq $me) { _fail($c, 400, 'You already see your own event; share it with someone else.'); return "\0" }
    unless (may_manage($perm)) { _fail($c, 400, 'Only the calendar\'s owner can share an event. Leave "Share with" empty, or ask the owner.'); return "\0" }
    return $email;
}

# --- the account's switches (phase 3: mail links; phase 4: the AI proposal) ---

sub _account_json ($c, $me) {
    my $m = _model($c);
    my $s = $m->account_settings($me);
    my $consent = Homelab::Calendar::Consent::state_for($m->db, $me);
    my $rs = Homelab::Calendar::Consent::research_state_for($m->db, $me);
    my $as = Homelab::Calendar::Consent::auto_state_for($m->db, $me);
    return {
        mail_links_enabled => ($s->{mail_links_enabled} ? \1 : \0), mail_links_enabled_at => $s->{mail_links_enabled_at},
        ai => {
            available => ($c->app->ai->configured ? \1 : \0),
            enabled   => ($consent->{enabled} ? \1 : \0),
            consented_to_current_notice => ($consent->{current} ? \1 : \0),
            consent_at => $s->{ai_consent_at},
            notice     => Homelab::Calendar::Consent::notice_body(),
            notice_sha256 => Homelab::Calendar::Consent::notice_sha256(),
        },
        # "Find out more" (#78): the second notice, its state, and the
        # research-every-proposal switch.
        research => {
            available => ($c->app->ai->configured ? \1 : \0),
            enabled   => ($rs->{enabled} ? \1 : \0),
            consented_to_current_notice => ($rs->{current} ? \1 : \0),
            consent_at => $s->{research_consent_at},
            auto       => ($rs->{auto} ? \1 : \0),
            notice     => Homelab::Calendar::Consent::research_notice_body(),
            notice_sha256 => Homelab::Calendar::Consent::research_notice_sha256(),
        },
        # #80: proposing as the email arrives (its own notice), and the
        # research-at-arrival entitlement with the switch under it.
        auto => {
            available => ($c->app->ai->configured ? \1 : \0),
            enabled   => ($as->{enabled} ? \1 : \0),
            consented_to_current_notice => ($as->{current} ? \1 : \0),
            consent_at => $s->{auto_propose_consent_at},
            notice     => Homelab::Calendar::Consent::auto_notice_body(),
            notice_sha256 => Homelab::Calendar::Consent::auto_notice_sha256(),
            research_at_arrival_allowed => ($as->{research_allowed} ? \1 : \0),
            research_at_arrival => ($as->{research_at_arrival} ? \1 : \0),
        },
        # #79: where reminders go (empty = the account's own address).
        reminder_addresses => $m->reminder_addresses($me),
        settings_url => $c->app->public_base_url . '/settings',
    };
}

# Body: { mail_links_enabled?: bool, ai_enabled?: bool, ai_consent_sha256?: hex }
# Turning the AI proposal on needs the hash of the notice the page showed
# (the current wording); anything else is refused.
sub _apply_account ($c, $me, $b) {
    my $m = _model($c);
    if (exists $b->{mail_links_enabled}) {
        $m->set_mail_links($me, $b->{mail_links_enabled} ? 1 : 0);
        _audit($c, action => 'calendar.mail_links_set', resource_type => 'calendar_account', resource_id => $me,
            detail => { enabled => ($b->{mail_links_enabled} ? \1 : \0) });
    }
    if (exists $b->{ai_enabled}) {
        if ($b->{ai_enabled}) {
            return 'To turn on AI proposals, agree to the current notice (reload the page and try again).'
                unless Homelab::Calendar::Consent::record($m->db, $me, $b->{ai_consent_sha256});
            _audit($c, action => 'calendar.ai_consent', resource_type => 'calendar_account', resource_id => $me,
                detail => { notice_sha256 => $b->{ai_consent_sha256} });
        }
        else {
            Homelab::Calendar::Consent::withdraw($m->db, $me);
            _audit($c, action => 'calendar.ai_withdrawn', resource_type => 'calendar_account', resource_id => $me, detail => {});
        }
    }
    if (exists $b->{research_enabled}) {
        if ($b->{research_enabled}) {
            return 'To turn on "Find out more", agree to its notice (reload the page and try again).'
                unless Homelab::Calendar::Consent::research_record($m->db, $me, $b->{research_consent_sha256});
            _audit($c, action => 'calendar.research_consent', resource_type => 'calendar_account', resource_id => $me,
                detail => { notice_sha256 => $b->{research_consent_sha256} });
        }
        else {
            Homelab::Calendar::Consent::research_withdraw($m->db, $me);
            _audit($c, action => 'calendar.research_withdrawn', resource_type => 'calendar_account', resource_id => $me, detail => {});
        }
    }
    if (exists $b->{research_auto}) {
        $m->set_research_auto($me, $b->{research_auto} ? 1 : 0);
    }
    # #80: consent #3 (propose as the email arrives) ...
    if (exists $b->{auto_propose}) {
        if ($b->{auto_propose}) {
            return 'To propose automatically, agree to its notice (reload the page and try again).'
                unless Homelab::Calendar::Consent::auto_record($m->db, $me, $b->{auto_propose_consent_sha256});
            _audit($c, action => 'calendar.auto_propose_consent', resource_type => 'calendar_account', resource_id => $me,
                detail => { notice_sha256 => $b->{auto_propose_consent_sha256} });
        }
        else {
            Homelab::Calendar::Consent::auto_withdraw($m->db, $me);
            _audit($c, action => 'calendar.auto_propose_withdrawn', resource_type => 'calendar_account', resource_id => $me, detail => {});
        }
    }
    # ... and the research-at-arrival switch, only for an entitled account.
    if (exists $b->{research_at_arrival}) {
        my $s = $m->account_settings($me);
        return 'Research at arrival is not included in your account yet.' if $b->{research_at_arrival} && !$s->{research_at_arrival_allowed};
        $m->set_research_at_arrival($me, $b->{research_at_arrival} ? 1 : 0);
    }
    # #79: the list of addresses reminders go to.
    if (exists $b->{reminder_addresses}) {
        my $ok = eval { $m->set_reminder_addresses($me, $b->{reminder_addresses}); 1 };
        return ($@ =~ s/\s+\z//r || 'Those reminder addresses could not be saved.') unless $ok;
    }
    return undef;
}

sub account ($c) {
    my $me = $c->require_login or return;
    return $c->render(json => _account_json($c, $me));
}

sub save_account ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    if (my $err = _apply_account($c, $me, _body($c))) { return _fail($c, 400, $err) }
    return $c->render(json => _account_json($c, $me));
}

# The same two, Bearer-authenticated, for myaccount through homelab-api's
# /api/v1/calendar/account gateway route.
sub internal_account_show ($c) {
    my $me = $c->authenticated_email_any or return;
    $c->stash('calendar.session_email' => $me);
    $c->stash('calendar.session_jti' => $c->stash('current_jti'));
    return $c->render(json => _account_json($c, $me));
}

sub internal_account_set ($c) {
    my $me = $c->authenticated_email_any or return;
    $c->stash('calendar.session_email' => $me);
    $c->stash('calendar.session_jti' => $c->stash('current_jti'));
    if (my $err = _apply_account($c, $me, _body($c))) { return _fail($c, 400, $err) }
    return $c->render(json => _account_json($c, $me));
}

# --- a link from an email ------------------------------------------------

# What the page needs to open the editor pre-filled: the message's subject,
# sender and date, a short excerpt, the plain parse, and where the AI switch
# stands. Also used by GET /m/:token.
sub _mail_link_json ($c, $link, $me, $zone) {
    my $m = _model($c);
    my $guess = Homelab::Calendar::MailExtract::guess(
        subject => $link->{subject}, text => $link->{text_excerpt}, date_header => $link->{date_header},
        zone => $zone, now => DateTime->now(time_zone => $zone),
    );
    my $consent = Homelab::Calendar::Consent::state_for($m->db, $me);
    my $rs = Homelab::Calendar::Consent::research_state_for($m->db, $me);
    return {
        token => $link->{token}, subject => $link->{subject}, from => $link->{from_addr}, date_header => $link->{date_header},
        excerpt => substr($link->{text_excerpt} // '', 0, 2000), received_at => $link->{created_at},
        # #81: the live events this account already made from the link (the
        # "already added" sheet); empty for a first click.
        events_made => _events_made_json($c, $m, $link, $me, $zone),
        guess => $guess, zone => $zone,
        # #80: what the runner proposed (and found) when the email arrived, if anything.
        proposal => (ref $link->{proposal} eq 'HASH' ? $link->{proposal} : undef), proposed_at => $link->{proposed_at},
        facts => (ref $link->{facts} eq 'HASH' ? $link->{facts} : undef),
        ai => { available => ($c->app->ai->configured ? \1 : \0), enabled => ($consent->{enabled} ? \1 : \0),
                notice => Homelab::Calendar::Consent::notice_body(), notice_sha256 => Homelab::Calendar::Consent::notice_sha256() },
        research => { available => ($c->app->ai->configured ? \1 : \0), enabled => ($rs->{enabled} ? \1 : \0), auto => ($rs->{auto} ? \1 : \0),
                      notice => Homelab::Calendar::Consent::research_notice_body(), notice_sha256 => Homelab::Calendar::Consent::research_notice_sha256() },
    };
}

# The live events this account made from a link, in the viewer's zone, only
# those it can still see (an event in a calendar whose share was revoked
# since drops out). made_at is a wall clock in the viewer's zone.
sub _events_made_json ($c, $m, $link, $me, $zone) {
    my @out;
    for my $e (@{ $m->mail_link_events_for($link->{id}, $me) }) {
        my $cal  = $m->calendar($e->{calendar_id}) or next;
        my $perm = $m->permission_for_event($me, $e, $cal) or next;
        my ($s, $en) = ($m->event_start($e), $m->event_end($e));
        push @out, {
            id => $e->{id} + 0, title => $e->{title}, all_day => ($e->{all_day} ? \1 : \0), permission => $perm,
            start => $e->{all_day} ? $s->ymd  : wall_string($s->clone->set_time_zone($zone)),
            end   => $e->{all_day} ? $en->ymd : wall_string($en->clone->set_time_zone($zone)),
            location => $e->{location}, is_recurring => ($e->{rrule} ? \1 : \0),
            made_at => wall_string(Homelab::Calendar::Model::_dt($e->{made_at}, $zone)),
        };
    }
    return \@out;
}

# POST /api/mail-links/:token/research { about, query } -- "Find out more"
# (#78): one web-search call through the AI service, after its own consent.
sub research ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $link = $m->mail_link_for($c->stash('token'), $me) or return _fail($c, 404, 'This link is not valid, has expired, or belongs to another account.');
    return _fail($c, 503, '"Find out more" is not available on this calendar.') unless $c->app->ai->configured;
    my $rs = Homelab::Calendar::Consent::research_state_for($m->db, $me);
    return _fail($c, 403, 'Agree to the "Find out more" notice first (Settings, or the line under the proposal).') unless $rs->{enabled};
    my $b = _body($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my $r = $c->app->ai->research(
        subject => $link->{subject}, from => $link->{from_addr}, text => $link->{text_excerpt},
        about => (defined $b->{about} && !ref $b->{about} ? substr($b->{about}, 0, 120) : ''),
        query => (defined $b->{query} && !ref $b->{query} ? substr($b->{query}, 0, 200) : ''),
        zone => $zone, now => DateTime->now(time_zone => $zone), consent_sha => $rs->{sha}, account_key => $me,
    );
    return _fail($c, 502, $r->{error} // 'The research failed.') unless $r->{ok};
    return $c->render(json => { summary => $r->{summary}, facts => $r->{facts}, searches => $r->{searches}, model => $r->{model} });
}

sub mail_link ($c) {
    my $me = $c->require_login or return;
    my $link = _model($c)->mail_link_for($c->stash('token'), $me) or return _fail($c, 404, 'This link is not valid, has expired, or belongs to another account.');
    return $c->render(json => _mail_link_json($c, $link, $me, $c->viewer_zone(_model($c)->prefs($me))));
}

# POST /api/mail-links/:token/propose -- the AI proposal, only after consent
# to the current wording and only when the person pressed the button.
sub propose ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $link = $m->mail_link_for($c->stash('token'), $me) or return _fail($c, 404, 'This link is not valid, has expired, or belongs to another account.');
    return _fail($c, 503, 'AI proposals are not available on this calendar.') unless $c->app->ai->configured;
    my $consent = Homelab::Calendar::Consent::state_for($m->db, $me);
    return _fail($c, 403, 'Turn on AI proposals in Settings (and agree to the notice) first.') unless $consent->{enabled};
    my $zone = $c->viewer_zone($m->prefs($me));
    my $r = $c->app->ai->propose(
        subject => $link->{subject}, from => $link->{from_addr}, date_header => $link->{date_header}, text => $link->{text_excerpt},
        zone => $zone, now => DateTime->now(time_zone => $zone), consent_sha => $consent->{sha}, account_key => $me,
    );
    return _fail($c, 502, $r->{error} // 'The AI proposal failed.') unless $r->{ok};
    return $c->render(json => { proposal => $r->{proposal}, model => $r->{model} });
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
    # The reminder belongs to the event (or, after a split, to the new series).
    if (exists $b->{reminder_minutes}) { _try($c, sub { $m->set_reminder($row->{id}, $b->{reminder_minutes}); 1 }) or return }
    # "Update it from this email" (#81): the link remembers this event for
    # this account too (the new series after a split).
    if (my $link = (defined $b->{mail_link_token} ? $m->mail_link_for($b->{mail_link_token}, $me) : undef)) {
        $m->mail_link_used($link->{id}, $row->{id}, $me);
    }
    return $c->render(json => _event_json($c, $row, $cal, $zone));
}

# --- suggestions (#80): proposals made as the email arrived --------------

sub _suggestion_json ($c, $row, $zone) {
    my $p = $row->{proposal} // {};
    return {
        token => $row->{token}, subject => $row->{subject}, from => $row->{from_addr}, received_at => $row->{created_at},
        proposed_at => $row->{proposed_at}, zone => $zone,
        proposal => { map { $_ => $p->{$_} } qw(title all_day start end location description confidence note) },
        facts => (ref $row->{facts} eq 'HASH' ? scalar @{ $row->{facts}{facts} // [] } : 0),
        open_url => $c->app->public_base_url . "/m/$row->{token}",
    };
}

sub suggestions ($c) {
    my $me = $c->require_login or return;
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    return $c->render(json => { suggestions => [ map { _suggestion_json($c, $_, $zone) } @{ $m->suggestions_for($me) } ] });
}

# POST /api/suggestions/:token/save -- the event, as proposed, in the default
# calendar, with the default reminder; the editor is for anything else.
sub save_suggestion ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $link = $m->mail_link_for($c->stash('token'), $me) or return _fail($c, 404, 'This suggestion is gone.');
    return _fail($c, 404, 'This suggestion has no proposal.') unless ref $link->{proposal} eq 'HASH';
    # Per account (#81): another recipient's event does not consume this one's suggestion.
    return _fail($c, 409, 'An event was already made from this email.') if $m->mail_link_made_by($link->{id}, $me);
    my $zone = $c->viewer_zone($m->prefs($me));
    my $cal = $m->ensure_default_calendar($me, $zone);
    my $p = $link->{proposal};
    # The proposal's wall clocks are in the zone it was made in (the account's
    # at the time); the event carries its own zone, so that is what we pass.
    my $pzone = (defined $p->{zone} && validate_zone($p->{zone})) ? $p->{zone} : $zone;
    my $event = _try($c, sub { $m->create_event($cal, $me, {
        title => (length($p->{title} // '') ? $p->{title} : ($link->{subject} // 'Event from email')),
        all_day => ($p->{all_day} ? 1 : 0), start => $p->{start}, end => $p->{end}, timezone => $pzone,
        location => $p->{location}, description => $p->{description},
    }) }) or return;
    $m->set_reminder($event->{id}, 10);
    $m->mail_link_used($link->{id}, $event->{id}, $me);
    $event->{permission} = 'owner';
    return $c->render(json => _event_json($c, $event, $cal, $zone), status => 201);
}

sub dismiss_suggestion ($c) {
    my $me = $c->require_login or return;
    $c->csrf_ok or return;
    my $m = _model($c);
    my $link = $m->mail_link_for($c->stash('token'), $me) or return _fail($c, 404, 'This suggestion is gone.');
    $m->dismiss_suggestion($link->{id});
    return $c->render(json => { ok => \1 });
}

# PUT /internal/v1/calendar/admin/accounts/:email/entitlements -- what an
# administrator grants an account (#80; #63's billing will call this too).
# Through homelab-api's gateway as /api/v1/calendar/admin/accounts/...
sub admin_entitlements ($c) {
    my $me = $c->authenticated_site_admin or return;
    my $email = lc($c->stash('email') // '');
    return _fail($c, 400, 'That does not look like an email address.') unless $email =~ /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/;
    my $b = _body($c);
    return _fail($c, 400, 'Send research_at_arrival_allowed (true or false).') unless exists $b->{research_at_arrival_allowed};
    my $s = _model($c)->set_entitlements($email, research_at_arrival_allowed => ($b->{research_at_arrival_allowed} ? 1 : 0));
    $c->stash('calendar.session_email' => $me); $c->stash('calendar.session_jti' => $c->stash('current_jti'));
    _audit($c, action => 'calendar.entitlement_set', resource_type => 'calendar_account', resource_id => $email, affected_user => $email,
        detail => { research_at_arrival_allowed => ($s->{research_at_arrival_allowed} ? \1 : \0) });
    return $c->render(json => { email => $email, entitlements => { research_at_arrival_allowed => ($s->{research_at_arrival_allowed} ? \1 : \0) } });
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
    return _ics_download($c, _calendar_masters_ics($m, $cal), $cal->{name});
}

# One calendar's events as iCalendar with the rules kept (the export a person
# carries elsewhere; also homelab-cli's `calendar export` without a range).
sub _calendar_masters_ics ($m, $cal) {
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
    return masters_ics(name => $cal->{name}, zone => $cal->{timezone}, description => $cal->{description}, events => \@out);
}

sub _ics_download ($c, $ics, $name) {
    my $fname = (($name // '') =~ s/[^A-Za-z0-9._-]+/_/gr) || 'calendar';
    $c->res->headers->content_type('text/calendar; charset=utf-8');
    $c->res->headers->content_disposition("attachment; filename=\"$fname.ics\"");
    return $c->render(data => $ics);
}

# --- homelab-cli through the api gateway (post-cutover #82) ----------------
# Bearer, no CSRF (the gateway maps /api/v1/calendar/* here): the account's
# calendars, the occurrences in a range (paged), one new event, the range as
# iCalendar, a whole calendar as iCalendar with its rules, an iCalendar file in.

# A Bearer caller acts as the signed-in account for the helpers below
# (session_email reads the stash first).
sub _as_session ($c, $me) {
    $c->stash('calendar.session_email' => $me);
    $c->stash('calendar.session_jti' => $c->stash('current_jti'));
    return $me;
}

# from/to: a date (2026-11-20), a wall clock (2026-11-20T14:30), today or
# tomorrow, read in the account's zone. Neither: today. from alone: a year on.
# to alone: from today. A date (or today/tomorrow) as `to` means that whole
# day. Three years at most. Returns ($ws, $we) or (undef, 'a sentence').
sub _range ($c, $zone) {
    my $today = DateTime->now(time_zone => $zone)->truncate(to => 'day');
    my $read = sub ($s) {
        return undef unless defined $s && length $s;
        return $today->clone if lc $s eq 'today';
        return $today->clone->add(days => 1) if lc $s eq 'tomorrow';
        return parse_wall($s, $zone);
    };
    my ($f, $t) = ($c->param('from'), $c->param('to'));
    my ($ws, $we) = ($read->($f), $read->($t));
    return (undef, 'The from date must look like 2026-11-20 or 2026-11-20T14:30 (or today, tomorrow).') if defined $f && length $f && !$ws;
    return (undef, 'The to date must look like 2026-11-20 or 2026-11-20T14:30 (or today, tomorrow).') if defined $t && length $t && !$we;
    my $whole_day = defined $t && $t =~ /\A(?:\d{4}-\d{2}-\d{2}|today|tomorrow)\z/i;
    if    (!$ws && !$we) { $ws = $today->clone; $we = $today->clone->add(days => 1) }
    elsif ($ws && !$we)  { $we = $ws->clone->add(years => 1) }
    elsif (!$ws && $we)  { $ws = $today->clone }
    $we = $we->clone->add(days => 1) if $whole_day;
    return (undef, 'The to date must come after the from date.') unless $we > $ws;
    return (undef, 'The range cannot be more than three years.') if $we->epoch - $ws->epoch > 3 * 366 * 86400;
    return ($ws, $we);
}

# ?calendar_id= -> ($cal, undef), (undef, undef) for none, or (undef, 'error').
sub _cli_calendar_id ($c, $m, $me) {
    my $cid = $c->param('calendar_id');
    return (undef, undef) unless defined $cid && length $cid;
    return (undef, 'calendar_id must be a number.') unless $cid =~ /\A\d+\z/;
    my $cal = $m->calendar($cid);
    return (undef, 'No such calendar.') unless $cal && $m->permission_for_calendar($me, $cal);
    return ($cal, undef);
}
sub _fail_calendar ($c, $err) { return _fail($c, ($err eq 'No such calendar.' ? 404 : 400), $err) }

# One occurrence as homelab-cli sees it: wall clocks in the account's zone.
sub _cli_event ($inst, $zone) {
    my $all_day = $inst->{all_day};
    return {
        id => $inst->{event_id} + 0, occurrence => _rid_str($inst->{recurrence_id}), uid => $inst->{uid},
        title => $inst->{title}, all_day => ($all_day ? \1 : \0),
        start => $all_day ? $inst->{start}->ymd : wall_string($inst->{start}->clone->set_time_zone($zone)),
        end   => $all_day ? $inst->{end}->ymd   : wall_string($inst->{end}->clone->set_time_zone($zone)),
        timezone => $zone, event_timezone => $inst->{event}{timezone},
        location => $inst->{location}, description => $inst->{description},
        calendar => { id => $inst->{calendar_id} + 0, name => $inst->{calendar_name} },
        permission => $inst->{permission}, is_recurring => ($inst->{is_recurring} ? \1 : \0),
        is_exception => ($inst->{is_exception} ? \1 : \0), shared_event => ($inst->{shared_event} ? \1 : \0),
    };
}

# GET /internal/v1/calendar/calendars
sub internal_calendars ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    $m->ensure_default_calendar($me, $zone);
    my $cals = $m->calendars_for($me);
    return $c->render(json => {
        timezone => $zone,
        own    => [ map { _calendar_json($_) } @{ $cals->{own} } ],
        shared => [ map { _calendar_json($_) } @{ $cals->{shared} } ],
    });
}

# GET /internal/v1/calendar/events?from&to&calendar_id&limit&page
sub internal_events_list ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    $m->ensure_default_calendar($me, $zone);
    my ($ws, $we) = _range($c, $zone); return _fail($c, 400, $we) unless $ws;
    my ($cal, $err) = _cli_calendar_id($c, $m, $me); return _fail_calendar($c, $err) if $err;
    my $limit = $c->param('limit') // 50;
    my $page  = $c->param('page') // 1;
    return _fail($c, 400, 'limit must be a number from 1 to 200.') unless $limit =~ /\A\d+\z/ && $limit >= 1 && $limit <= 200;
    return _fail($c, 400, 'page must be a number from 1.') unless $page =~ /\A\d+\z/ && $page >= 1;
    my $all = _instances_for($m, $me, $ws, $we, shared_events => 1, calendar_id => ($cal ? $cal->{id} : undef));
    my $total = scalar @$all;
    my $pages = $total ? int(($total + $limit - 1) / $limit) : 1;
    my $first = ($page - 1) * $limit;
    my $last  = $first + $limit - 1;
    $last = $total - 1 if $last > $total - 1;
    my @slice = $first <= $last ? @$all[ $first .. $last ] : ();
    return $c->render(json => {
        timezone => $zone, from => wall_string($ws), to => wall_string($we),
        page => $page + 0, pages => $pages, limit => $limit + 0, total => $total,
        events => [ map { _cli_event($_, $zone) } @slice ],
    });
}

# POST /internal/v1/calendar/events -- the same body the editor sends.
sub internal_event_create ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    return _create_from_body($c, $me, _body($c));
}

# GET /internal/v1/calendar/events.ics?from&to&calendar_id -- every occurrence
# in the range as its own VEVENT (UTC instants: any client imports it).
sub internal_events_ics ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my ($ws, $we) = _range($c, $zone); return _fail($c, 400, $we) unless $ws;
    my ($cal, $err) = _cli_calendar_id($c, $m, $me); return _fail_calendar($c, $err) if $err;
    my $list = _instances_for($m, $me, $ws, $we, shared_events => 1, calendar_id => ($cal ? $cal->{id} : undef));
    my $ics = instances_ics(name => ($cal ? $cal->{name} : "Calendar of $me"), zone => $zone, instances => $list);
    return _ics_download($c, $ics, ($cal ? $cal->{name} : 'events') . '-' . $ws->ymd . '-' . $we->clone->subtract(seconds => 1)->ymd);
}

# GET /internal/v1/calendar/export.ics?calendar_id -- one calendar, rules kept.
sub internal_export_ics ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my ($cal, $err) = _cli_calendar_id($c, $m, $me); return _fail_calendar($c, $err) if $err;
    $cal //= $m->ensure_default_calendar($me, $zone);
    return _ics_download($c, _calendar_masters_ics($m, $cal), $cal->{name});
}

# POST /internal/v1/calendar/import?calendar_id -- the body is the .ics text.
# A UID already in one of the account's editable calendars updates that
# event; anything else is created in the calendar named (else the default).
sub internal_import ($c) {
    my $me = $c->authenticated_email_any or return;
    _as_session($c, $me);
    my $m = _model($c);
    my $zone = $c->viewer_zone($m->prefs($me));
    my ($cal, $err) = _cli_calendar_id($c, $m, $me); return _fail_calendar($c, $err) if $err;
    $cal //= $m->ensure_default_calendar($me, $zone);
    my $perm = $m->permission_for_calendar($me, $cal);
    return _fail($c, 403, 'You can see this calendar but not add to it.') unless may_edit($perm);
    my $text = $c->req->body // '';
    return _fail($c, 413, 'The file is too large (2 MB at most).') if length $text > 2_000_000;
    my $parsed = parse_ics($text, zone => $zone);
    return _fail($c, 400, $parsed->{error}) if $parsed->{error};
    my (@made, @skipped, $created, $updated);
    ($created, $updated) = (0, 0);
    push @skipped, @{ $parsed->{skipped} };
    for my $in (@{ $parsed->{events} }) {
        my %input = map { $_ => $in->{$_} } qw(title description location all_day start end timezone repeat);
        my ($row, $jcal);
        my $existing = defined $in->{uid} ? $m->event_by_uid($in->{uid}) : undef;
        if ($existing) {
            my $ecal  = $m->calendar($existing->{calendar_id});
            my $eperm = $ecal ? $m->permission_for_event($me, $existing, $ecal) : undef;
            if ($eperm && may_edit($eperm)) {
                $row = eval { $m->update_event($existing, \%input) };
                unless ($row) { push @skipped, { uid => $in->{uid}, reason => (($@ // 'could not be updated') =~ s/\n\z//r) }; next }
                $updated++;
                $row->{permission} = $eperm;
                $jcal = $ecal;
            }
            else { delete $in->{uid} }     # someone else's event: one of our own instead
        }
        unless ($row) {
            $input{uid} = $in->{uid} if defined $in->{uid};
            $row = eval { $m->create_event($cal, $me, \%input) };
            unless ($row) { push @skipped, { uid => $in->{uid}, reason => (($@ // 'could not be created') =~ s/\n\z//r) }; next }
            $created++;
            $row->{permission} = $perm;
            $jcal = $cal;
        }
        if ($row->{rrule} && @{ $in->{exdates} // [] }) {
            for my $x (@{ $in->{exdates} }) {
                my $rid = parse_wall($x, $row->{timezone}) or next;
                eval { $m->_write_exception($row, $rid, {}, 1) };
            }
        }
        $m->set_reminder($row->{id}, $in->{reminder_minutes}) if defined $in->{reminder_minutes};
        push @made, _event_json($c, $row, $jcal, $zone);
    }
    return $c->render(json => {
        created => $created, updated => $updated, skipped => \@skipped, events => \@made,
        calendar => _calendar_json({ %$cal, permission => $perm, visible => 1 }),
    });
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
