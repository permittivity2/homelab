package Homelab::Calendar::App::Controller::Public;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use DateTime;
use Mojo::Util qw(url_escape);
use Mojo::JSON qw(encode_json);
use Homelab::Calendar::Recurrence qw(validate_zone parse_wall wall_string);
use Homelab::Calendar::Access qw(visible_detail);
use Homelab::Calendar::ICS qw(instances_ics masters_ics);

# What a link opens: a calendar (/c/<token>, its feed /c/<token>.ics) or one
# event (/e/<token>, /e/<token>.ics). A link to anyone needs no sign-in. A
# share to a named account needs the viewer signed in as that account (or as
# the owner): the link is then a convenience, not a credential.

sub _model ($c) { return $c->app->model }

sub _gone ($c) {
    my $ics = ($c->stash('format') // '') eq 'ics';
    return $c->render(text => "This link is not valid.\n", status => 404) if $ics;
    return $c->render(template => 'notice', status => 404, heading => 'This link is not valid',
        body => 'The calendar or event it pointed to is gone, or the link was turned off by its owner.');
}

# The share, if the link still works and this visitor may use it.
sub _share ($c) {
    my $share = _model($c)->share_by_token($c->stash('token'));
    unless ($share) { _gone($c); return undef }
    if (my $with = $share->{shared_with_email}) {
        my $me = $c->session_email;
        unless (length $me) {
            if ($c->app->sso && !$c->session('token') && ($c->stash('format') // '') ne 'ics') {
                $c->redirect_to('/login?next=' . url_escape($c->req->url->path->to_string));
                return undef;
            }
            delete @{ $c->session }{qw(token refresh_token)};
            $c->render(template => 'notice', status => 403, heading => 'Sign in to open this',
                body => "This was shared with $with. Sign in as that account to see it.", login_next => $c->req->url->path->to_string);
            return undef;
        }
        unless ($me eq lc $with || $me eq lc $share->{owner_email}) {
            $c->render(template => 'notice', status => 403, heading => 'This link is for another account',
                body => "This was shared with $with. You are signed in as $me.");
            return undef;
        }
    }
    _model($c)->note_share_access($share->{id});
    return $share;
}

sub _zone ($c, $share) {
    my $q = $c->param('timeZone') // $c->param('timezone');
    return $q if defined $q && validate_zone($q);
    return $share->{calendar}{timezone} if validate_zone($share->{calendar}{timezone} // '');
    return $c->app->default_zone;
}

# Everything in the feed window: a year back, two ahead.
sub _feed_window ($zone) {
    my $now = DateTime->now(time_zone => $zone)->truncate(to => 'day');
    return ($now->clone->subtract(years => 1), $now->clone->add(years => 2));
}

sub _ics_response ($c, $ics, $name) {
    my $fname = (($name // 'calendar') =~ s/[^A-Za-z0-9._-]+/_/gr) || 'calendar';
    $c->res->headers->content_type('text/calendar; charset=utf-8');
    $c->res->headers->content_disposition("inline; filename=\"$fname.ics\"");
    $c->res->headers->cache_control('private, max-age=300');
    return $c->render(data => $ics);
}

# GET /c/:token[.ics]
sub calendar_page ($c) {
    my $share = _share($c) or return;
    my $cal = $share->{calendar};
    my $detail = visible_detail($share);
    my $zone = _zone($c, $share);
    if (($c->stash('format') // '') eq 'ics') {
        my ($ws, $we) = _feed_window($zone);
        my $inst = _model($c)->instances(calendars => [$cal], window_start => $ws, window_end => $we);
        my $ics = instances_ics(name => $cal->{name}, zone => $cal->{timezone}, detail => $detail,
            description => ($detail eq 'busy' ? undef : $cal->{description}),
            instances => [ map { _feed_instance($_) } @$inst ]);
        return _ics_response($c, $ics, $cal->{name});
    }
    return $c->render(template => 'public_calendar', share => $share, calendar => $cal, detail => $detail,
        boot => encode_json({ token => $share->{token}, name => $cal->{name}, color => $cal->{color}, detail => $detail,
            zone => $zone, ics_url => $c->app->public_base_url . "/c/$share->{token}.ics",
            signed_in => $c->session_email }));
}

sub _feed_instance ($i) {
    return { uid => $i->{uid}, title => $i->{title}, description => $i->{description}, location => $i->{location},
        all_day => $i->{all_day}, start => $i->{start}, end => $i->{end}, recurrence_id => $i->{recurrence_id},
        created => Homelab::Calendar::Model::_dt($i->{event}{created_at}), updated => Homelab::Calendar::Model::_dt($i->{event}{updated_at}) };
}

# GET /c/:token/events?start&end&timeZone -- what the link page's calendar draws.
sub calendar_events ($c) {
    my $share = _share($c) or return;
    my $cal = $share->{calendar};
    my $detail = visible_detail($share);
    my $zone = _zone($c, $share);
    my ($ws, $we) = Homelab::Calendar::App::Controller::Api::_window($c, $zone);
    return $c->render(json => { error => 'bad window' }, status => 400) unless $ws;
    my $inst = _model($c)->instances(calendars => [$cal], window_start => $ws, window_end => $we);
    $_->{calendar_color} = $cal->{color} for @$inst;
    return $c->render(json => [ map { Homelab::Calendar::App::Controller::Api::_fc_event($_, $zone, 'read', $detail) } @$inst ]);
}

# GET /e/:token[.ics] -- one event, with its next occurrences.
sub event_page ($c) {
    my $share = _share($c) or return;
    my $m = _model($c);
    my ($event, $cal) = ($share->{event}, $share->{calendar});
    my $zone = _zone($c, $share);
    if (($c->stash('format') // '') eq 'ics') {
        my (@ex, @ov);
        for my $x (@{ $m->exceptions_for($event->{id}) }) {
            my $rid = Homelab::Calendar::Model::_dt($x->{recurrence_id}, $event->{timezone});
            if ($x->{cancelled}) { push @ex, $rid; next }
            my $i = $m->_exception_instance($event, $x, $rid);
            push @ov, { recurrence_id => $rid, start => $i->{start}, end => $i->{end}, all_day => $i->{all_day},
                title => $i->{title}, description => $i->{description}, location => $i->{location} };
        }
        my $ics = masters_ics(name => $event->{title}, zone => $event->{timezone}, events => [ {
            uid => $event->{uid}, title => $event->{title}, description => $event->{description}, location => $event->{location},
            all_day => $event->{all_day} ? 1 : 0, start => $m->event_start($event), end => $m->event_end($event),
            rrule => $event->{rrule}, exdates => \@ex, overrides => \@ov,
            created => Homelab::Calendar::Model::_dt($event->{created_at}), updated => Homelab::Calendar::Model::_dt($event->{updated_at}),
        } ]);
        return _ics_response($c, $ics, $event->{title});
    }
    my $now = DateTime->now(time_zone => $zone);
    my $from = $m->event_start($event) > $now ? $m->event_start($event)->clone->subtract(days => 1) : $now->clone->truncate(to => 'day');
    my $inst = $m->instances(events => [$event], window_start => $from, window_end => $from->clone->add(years => 2));
    my @next = map { {
        all_day => $_->{all_day}, start => $_->{start}->clone->set_time_zone($zone), end => $_->{end}->clone->set_time_zone($zone),
        title => $_->{title}, location => $_->{location}, description => $_->{description},
    } } @{$inst}[0 .. ($#$inst < 11 ? $#$inst : 11)];
    return $c->render(template => 'public_event', share => $share, event => $event, calendar => $cal, zone => $zone,
        occurrences => \@next, more => (@$inst > 12 ? 1 : 0),
        ics_url => $c->app->public_base_url . "/e/$share->{token}.ics");
}

1;
