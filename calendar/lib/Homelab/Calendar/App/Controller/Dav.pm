package Homelab::Calendar::App::Controller::Dav;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::Util qw(xml_escape url_escape);
use Mojo::URL;
use Mojo::Date;
use XML::LibXML;
use DateTime;
use Homelab::Calendar::ICS qw(masters_ics);
use Homelab::Calendar::ICSImport qw(parse_ics);
use Homelab::Calendar::Recurrence qw(parse_wall);
use Homelab::Calendar::Access qw(may_edit may_manage);

# CalDAV (RFC 4791) over WebDAV (RFC 4918) with sync-collection (RFC 6578):
# what an iPhone, Android (DAVx5) and Thunderbird speak to keep a calendar in
# both directions (post-cutover #84). The tree:
#
#   /.well-known/caldav                        -> 301 /dav/
#   /dav/                                      root: who am I (current-user-principal)
#   /dav/principals/<email>/                   the account: where its calendars are
#   /dav/calendars/<email>/                    the calendar home: one child per calendar
#   /dav/calendars/<email>/<cal>/              a calendar: PROPFIND, REPORT, PROPPATCH, DELETE, MKCALENDAR
#   /dav/calendars/<email>/<cal>/<uid>.ics     one event: GET, PUT, DELETE
#
# <email> is the signed-in account's (anyone else's answers 403); <cal> is the
# calendar's number, or the name a client made it under. Calendars shared to
# the account appear in its home too, read-only unless the share says edit.
#
# Sign-in is HTTP Basic with the address and an APP PASSWORD (Settings ->
# Devices), checked by App.pm's dav_login helper: never the SSO password,
# never a Bearer token, and the session cookie plays no part here.
#
# An object is a whole event as ICS::masters_ics writes it (the rule, EXDATEs,
# one RECURRENCE-ID component per moved occurrence, the reminders as alarms,
# no METHOD): the phone expands. Its ETag is "<change_seq>", a counter
# migration 009 stamps on every change to the event or its parts; a
# calendar's ctag and sync-token are the largest of those. XML comes in
# through XML::LibXML with entities and the network off and goes out by hand,
# escaped; the body of a PUT goes through the same parser as an import.

my %NS = (D => 'DAV:', C => 'urn:ietf:params:xml:ns:caldav', CS => 'http://calendarserver.org/ns/', A => 'http://apple.com/ns/ical/');
my %PREFIX = map { $NS{$_} => $_ } keys %NS;
my $XMLNS = join ' ', map { qq{xmlns:$_="$NS{$_}"} } qw(D C CS A);
my @REPORTS = ('C:calendar-query', 'C:calendar-multiget', 'D:sync-collection');
my $ALLOW_ROOT       = 'OPTIONS, GET, HEAD, PROPFIND, REPORT';
my $ALLOW_COLLECTION = 'OPTIONS, GET, HEAD, PROPFIND, PROPPATCH, REPORT, MKCALENDAR, DELETE';
my $ALLOW_OBJECT     = 'OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND';
my $MAX_BODY = 2_000_000;
my $PARSER = XML::LibXML->new(no_network => 1, expand_entities => 0, load_ext_dtd => 0, huge => 0);
my $ELEMENT = 1;     # XML_ELEMENT_NODE

my @ROOT_DEFAULT      = ('{DAV:}resourcetype', '{DAV:}displayname', '{DAV:}current-user-principal');
my @PRINCIPAL_DEFAULT = ('{DAV:}resourcetype', '{DAV:}displayname', '{DAV:}principal-URL', '{DAV:}current-user-principal',
                         "{$NS{C}}calendar-home-set", "{$NS{C}}calendar-user-address-set");
my @HOME_DEFAULT      = ('{DAV:}resourcetype', '{DAV:}displayname', '{DAV:}owner', '{DAV:}current-user-principal');
my @CALENDAR_DEFAULT  = ('{DAV:}resourcetype', '{DAV:}displayname', '{DAV:}owner', '{DAV:}current-user-privilege-set',
                         '{DAV:}supported-report-set', '{DAV:}sync-token', "{$NS{CS}}getctag", "{$NS{A}}calendar-color",
                         "{$NS{C}}supported-calendar-component-set");
my @OBJECT_DEFAULT    = ('{DAV:}resourcetype', '{DAV:}getetag', '{DAV:}getcontenttype', '{DAV:}getlastmodified');

# ----------------------------------------------------------------- small parts

sub _m ($c)  { return $c->app->model }
sub _me ($c) { return lc($c->stash('calendar.session_email') // '') }
sub _esc ($s) { return xml_escape($s // '') }
sub _seg ($s) { return url_escape($s // '', '^A-Za-z0-9\-._~@') }
sub _principal_href ($email) { return '/dav/principals/' . _seg(lc $email) . '/' }
sub _home_href ($email)      { return '/dav/calendars/' . _seg(lc $email) . '/' }
sub _cal_href ($email, $cal) { return _home_href($email) . _seg(Homelab::Calendar::Model::dav_segment($cal)) . '/' }
sub _obj_href ($email, $cal, $uid) { return _cal_href($email, $cal) . _seg($uid) . '.ics' }
sub _href ($h) { return '<D:href>' . _esc($h) . '</D:href>' }
sub _etag ($e) { return '"' . (($e->{change_seq} // 0) + 0) . '"' }
sub _token ($c, $seq) { return $c->app->public_base_url . '/ns/sync/' . ($seq + 0) }
sub _depth ($c) { my $d = lc($c->req->headers->header('Depth') // 'infinity'); return $d eq '0' ? 0 : $d eq '1' ? 1 : 2 }
sub _dav_headers ($c) { $c->res->headers->header(DAV => '1, 3, calendar-access'); return }

sub _plain ($c, $status, $text) { _dav_headers($c); return $c->render(text => "$text\n", status => $status) }
sub _empty ($c, $status) { _dav_headers($c); return $c->render(data => '', status => $status) }
sub _options ($c, $allow) { _dav_headers($c); $c->res->headers->allow($allow); return $c->render(data => '', status => 200) }
sub _not_allowed ($c, $allow) { $c->res->headers->allow($allow); return _plain($c, 405, 'That method is not available here.') }
sub _dav_error ($c, $status, $inner) {
    _dav_headers($c);
    $c->res->headers->content_type('application/xml; charset=utf-8');
    return $c->render(data => qq{<?xml version="1.0" encoding="utf-8"?>\n<D:error $XMLNS>$inner</D:error>\n}, status => $status);
}
# A model's one-line reason for the person, without the Perl trail.
sub _why ($err) { my $w = ($err // '') =~ s/ at \S+ line \d+.*//sr; $w =~ s/\s+\z//; return length $w ? $w : 'That could not be saved.' }

# The request body as a document, or () for none. A body that is not XML is
# an error the caller answers 400 with.
sub _xml ($c) {
    my $body = $c->req->body // '';
    return (undef, undef) unless $body =~ /\S/;
    return (undef, 'The request body is too large.') if length $body > $MAX_BODY;
    my $doc = eval { $PARSER->parse_string($body) };
    return (undef, 'The request body is not well-formed XML.') unless $doc;
    return ($doc, undef);
}
sub _root_of ($doc) { return $doc ? $doc->documentElement : undef }
sub _is ($node, $prefix, $name) {
    return 0 unless $node && $node->nodeType == $ELEMENT;
    return (($node->namespaceURI // '') eq $NS{$prefix} && $node->localname eq $name) ? 1 : 0;
}
sub _child ($node, $prefix, $name) { return undef unless $node; for my $k ($node->childNodes) { return $k if _is($k, $prefix, $name) } return undef }
sub _children ($node, $prefix, $name) { return () unless $node; return grep { _is($_, $prefix, $name) } $node->childNodes }
sub _elements ($node) { return () unless $node; return grep { $_->nodeType == $ELEMENT } $node->childNodes }
sub _qn ($node) { return '{' . ($node->namespaceURI // '') . '}' . $node->localname }
sub _text ($node) { return defined $node ? ($node->textContent =~ s/\A\s+|\s+\z//gr) : '' }

# The properties a PROPFIND or REPORT asks for, as "{ns}name"; 'all' for
# allprop, propname, or no body at all.
sub _wanted ($root) {
    return 'all' unless $root;
    return 'all' if _child($root, 'D', 'allprop') || _child($root, 'D', 'propname');
    my $prop = _child($root, 'D', 'prop') or return 'all';
    my @w = map { _qn($_) } _elements($prop);
    return @w ? \@w : 'all';
}

# '{ns}name' -> the tag to write it with, and any xmlns it needs declared.
sub _tag ($qn) {
    my ($ns, $name) = $qn =~ /\A\{([^}]*)\}(.+)\z/ or return ($qn, '');
    return ("$PREFIX{$ns}:$name", '') if exists $PREFIX{$ns};
    return (length $ns ? ("x:$name", qq{ xmlns:x="} . _esc($ns) . '"') : ($name, ' xmlns=""'));
}
sub _empty_tag ($qn) { my ($t, $x) = _tag($qn); return "<$t$x/>" }

# One <D:response>: the properties found (200) and those not (404), or a bare
# status (a resource removed since a sync-token, a multiget href that is not here).
sub _response ($href, $found, $missing, $status = undef) {
    my $x = '<D:response><D:href>' . _esc($href) . '</D:href>';
    return $x . "<D:status>HTTP/1.1 $status</D:status></D:response>\n" if $status;
    if (@$found) {
        $x .= '<D:propstat><D:prop>'
            . join('', map { my ($t, $xa) = _tag($_->[0]); length($_->[1]) ? "<$t$xa>$_->[1]</$t>" : "<$t$xa/>" } @$found)
            . '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>';
    }
    if (@$missing) {
        $x .= '<D:propstat><D:prop>' . join('', map { _empty_tag($_) } @$missing) . '</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>';
    }
    return $x . "</D:response>\n";
}
sub _multistatus ($c, $body) {
    _dav_headers($c);
    $c->res->headers->content_type('application/xml; charset=utf-8');
    return $c->render(data => qq{<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus $XMLNS>\n$body</D:multistatus>\n}, status => 207);
}
# One resource's properties against what was asked: ($found, $missing).
# $avail maps '{ns}name' to a sub; one that answers undef means "not here".
sub _props ($avail, $wanted, @default) {
    my @names = ref $wanted ? @$wanted : @default;
    my (@found, @missing);
    for my $qn (@names) {
        my $f = $avail->{$qn};
        my $v = $f ? $f->() : undef;
        if (defined $v) { push @found, [ $qn, $v ] } else { push @missing, $qn }
    }
    return (\@found, \@missing);
}
sub _privs ($perm) {
    my $x = '<D:privilege><D:read/></D:privilege><D:privilege><D:read-current-user-privilege-set/></D:privilege>';
    $x .= '<D:privilege><D:write/></D:privilege><D:privilege><D:write-content/></D:privilege><D:privilege><D:bind/></D:privilege><D:privilege><D:unbind/></D:privilege>' if may_edit($perm);
    $x .= '<D:privilege><D:write-properties/></D:privilege>' if may_manage($perm);
    return $x;
}

# ------------------------------------------------------- the properties of each

sub _root_props ($c) {
    my $me = _me($c);
    return {
        '{DAV:}resourcetype'               => sub { '<D:collection/>' },
        '{DAV:}displayname'                => sub { 'Calendar' },
        '{DAV:}current-user-principal'     => sub { _href(_principal_href($me)) },
        '{DAV:}principal-collection-set'   => sub { _href('/dav/principals/') },
        '{DAV:}owner'                      => sub { _href(_principal_href($me)) },
        '{DAV:}current-user-privilege-set' => sub { _privs('read') },
        '{DAV:}supported-report-set'       => sub { '' },
        "{$NS{C}}calendar-home-set"        => sub { _href(_home_href($me)) },
    };
}
sub _folder_props ($name) {
    return { '{DAV:}resourcetype' => sub { '<D:collection/>' }, '{DAV:}displayname' => sub { _esc($name) } };
}
sub _principal_props ($c, $email) {
    return {
        '{DAV:}resourcetype'                   => sub { '<D:collection/><D:principal/>' },
        '{DAV:}displayname'                    => sub { _esc($email) },
        '{DAV:}principal-URL'                  => sub { _href(_principal_href($email)) },
        '{DAV:}current-user-principal'         => sub { _href(_principal_href($email)) },
        '{DAV:}owner'                          => sub { _href(_principal_href($email)) },
        '{DAV:}alternate-URI-set'              => sub { '' },
        '{DAV:}group-membership'               => sub { '' },
        '{DAV:}group-member-set'               => sub { '' },
        '{DAV:}current-user-privilege-set'     => sub { _privs('read') },
        '{DAV:}supported-report-set'           => sub { '' },
        "{$NS{C}}calendar-home-set"            => sub { _href(_home_href($email)) },
        "{$NS{C}}calendar-user-address-set"    => sub { _href("mailto:$email") },
        "{$NS{C}}calendar-user-type"           => sub { 'INDIVIDUAL' },
        "{$NS{CS}}email-address-set"           => sub { '<CS:email-address>' . _esc($email) . '</CS:email-address>' },
    };
}
sub _home_props ($c, $email) {
    return {
        '{DAV:}resourcetype'               => sub { '<D:collection/>' },
        '{DAV:}displayname'                => sub { 'Calendars' },
        '{DAV:}current-user-principal'     => sub { _href(_principal_href($email)) },
        '{DAV:}owner'                      => sub { _href(_principal_href($email)) },
        '{DAV:}current-user-privilege-set' => sub { _privs('owner') },
        '{DAV:}supported-report-set'       => sub { '' },
    };
}
sub _calendar_props ($c, $email, $cal) {
    my $m = _m($c);
    my $perm = $cal->{permission};
    my $color = $cal->{color} // '#6f94b8';
    my $seq;
    my $sync = sub { $seq //= $m->sync_seq($cal->{id}) };
    return {
        '{DAV:}resourcetype'                       => sub { '<D:collection/><C:calendar/>' },
        '{DAV:}displayname'                        => sub { _esc($cal->{name}) . (($perm // '') eq 'owner' ? '' : ' (' . _esc($cal->{owner_email}) . ')') },
        '{DAV:}owner'                              => sub { _href(_principal_href($cal->{owner_email})) },
        '{DAV:}current-user-principal'             => sub { _href(_principal_href($email)) },
        '{DAV:}current-user-privilege-set'         => sub { _privs($perm) },
        '{DAV:}supported-report-set'               => sub { join '', map { "<D:supported-report><D:report><$_/></D:report></D:supported-report>" } @REPORTS },
        '{DAV:}sync-token'                         => sub { _esc(_token($c, $sync->())) },
        "{$NS{CS}}getctag"                         => sub { 'c' . $sync->() },
        "{$NS{A}}calendar-color"                   => sub { _esc(uc($color) . 'FF') },
        "{$NS{A}}calendar-order"                   => sub { ($cal->{position} // 0) + 0 },
        "{$NS{C}}calendar-description"             => sub { (defined $cal->{description} && length $cal->{description}) ? _esc($cal->{description}) : undef },
        "{$NS{C}}supported-calendar-component-set" => sub { '<C:comp name="VEVENT"/>' },
        "{$NS{C}}supported-calendar-data"          => sub { '<C:calendar-data content-type="text/calendar" version="2.0"/>' },
        "{$NS{C}}max-resource-size"                => sub { $MAX_BODY },
        "{$NS{C}}schedule-calendar-transp"         => sub { '<C:opaque/>' },
    };
}
sub _object_props ($c, $email, $cal, $e, $ics_ref) {
    my $m = _m($c);
    my $ics = sub { $$ics_ref //= _object_ics($m, $cal, $e) };
    return {
        '{DAV:}resourcetype'               => sub { '' },
        '{DAV:}getetag'                    => sub { _esc(_etag($e)) },
        '{DAV:}getcontenttype'             => sub { 'text/calendar; charset=utf-8; component=VEVENT' },
        '{DAV:}getlastmodified'            => sub { Mojo::Date->new(Homelab::Calendar::Model::_dt($e->{updated_at})->epoch)->to_string },
        '{DAV:}getcontentlength'           => sub { length $ics->() },
        '{DAV:}displayname'                => sub { _esc($e->{title}) },
        '{DAV:}owner'                      => sub { _href(_principal_href($cal->{owner_email})) },
        '{DAV:}current-user-principal'     => sub { _href(_principal_href($email)) },
        '{DAV:}current-user-privilege-set' => sub { _privs($cal->{permission}) },
        "{$NS{C}}calendar-data"            => sub { _esc($ics->()) },
    };
}
sub _object_ics ($m, $cal, $e) {
    return masters_ics(method => 'none', zone => $cal->{timezone}, events => [ $m->masters_entry($e) ]);
}
sub _object_response ($c, $email, $cal, $e, $wanted) {
    my $ics;
    return _response(_obj_href($email, $cal, $e->{uid}), _props(_object_props($c, $email, $cal, $e, \$ics), $wanted, @OBJECT_DEFAULT));
}

# ------------------------------------------------------------------ the routes

# GET /.well-known/caldav (any method): where the tree starts.
sub well_known ($c) {
    _dav_headers($c);
    $c->res->headers->location($c->app->public_base_url . '/dav/');
    return $c->render(data => '', status => 301);
}

# PROPFIND / (an iPhone asks the root of the site when the well-known path
# did not answer): the same answer as /dav/, after the same sign-in.
sub root_alias ($c) {
    return _options($c, $ALLOW_ROOT) if uc $c->req->method eq 'OPTIONS';
    return unless $c->dav_login;
    return root($c, '/');
}

sub root ($c, $href = '/dav/') {
    my $method = uc $c->req->method;
    return _options($c, $ALLOW_ROOT) if $method eq 'OPTIONS';
    return _plain($c, 200, 'This is the CalDAV side of the calendar. Add it to a phone or a desktop calendar app with your address and an app password from Settings, Devices.')
        if $method eq 'GET' || $method eq 'HEAD';
    return _not_allowed($c, $ALLOW_ROOT) unless $method eq 'PROPFIND' || $method eq 'REPORT';
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    return _dav_error($c, 403, '<D:supported-report/>') if $method eq 'REPORT';
    my $wanted = _wanted(_root_of($doc));
    my $body = _response($href, _props(_root_props($c), $wanted, @ROOT_DEFAULT));
    if (_depth($c) >= 1 && $href eq '/dav/') {
        $body .= _response('/dav/principals/', _props(_folder_props('Principals'), $wanted, '{DAV:}resourcetype', '{DAV:}displayname'));
        $body .= _response('/dav/calendars/',  _props(_folder_props('Calendars'),  $wanted, '{DAV:}resourcetype', '{DAV:}displayname'));
    }
    return _multistatus($c, $body);
}

# /dav/principals/ and /dav/calendars/: folders holding one thing each, the
# signed-in account's.
sub principals ($c) { return _folder($c, '/dav/principals/', 'Principals', sub ($email) { (_principal_href($email), _principal_props($c, $email), \@PRINCIPAL_DEFAULT) }) }
sub homes ($c)      { return _folder($c, '/dav/calendars/',  'Calendars',  sub ($email) { (_home_href($email), _home_props($c, $email), \@HOME_DEFAULT) }) }
sub _folder ($c, $href, $name, $child) {
    my $method = uc $c->req->method;
    return _options($c, $ALLOW_ROOT) if $method eq 'OPTIONS';
    return _plain($c, 200, "$name.") if $method eq 'GET' || $method eq 'HEAD';
    return _not_allowed($c, $ALLOW_ROOT) unless $method eq 'PROPFIND';
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    my $wanted = _wanted(_root_of($doc));
    my $body = _response($href, _props(_folder_props($name), $wanted, '{DAV:}resourcetype', '{DAV:}displayname'));
    if (_depth($c) >= 1) {
        my ($chref, $cprops, $cdefault) = $child->(_me($c));
        $body .= _response($chref, _props($cprops, $wanted, @$cdefault));
    }
    return _multistatus($c, $body);
}

# /dav/principals/<email>/
sub principal ($c) {
    my $method = uc $c->req->method;
    my $email = lc($c->stash('email') // '');
    return _options($c, $ALLOW_ROOT) if $method eq 'OPTIONS';
    return _plain($c, 403, 'That is not your address.') unless $email eq _me($c);
    return _plain($c, 200, "The calendar account $email.") if $method eq 'GET' || $method eq 'HEAD';
    return _not_allowed($c, $ALLOW_ROOT) unless $method eq 'PROPFIND' || $method eq 'REPORT';
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    my $root = _root_of($doc);
    my $wanted;
    if ($method eq 'REPORT') {
        # expand-property (a Mac asks it of the principal): the properties
        # named, unexpanded, which every client takes as an answer.
        return _dav_error($c, 403, '<D:supported-report/>') unless _is($root, 'D', 'expand-property');
        my @w = map { '{' . ($_->getAttribute('namespace') // 'DAV:') . '}' . ($_->getAttribute('name') // '') } _children($root, 'D', 'property');
        $wanted = @w ? \@w : 'all';
    }
    else { $wanted = _wanted($root) }
    return _multistatus($c, _response(_principal_href($email), _props(_principal_props($c, $email), $wanted, @PRINCIPAL_DEFAULT)));
}

# /dav/calendars/<email>/: the home, one child per calendar the account owns
# or has been given.
sub home ($c) {
    my $method = uc $c->req->method;
    my $email = lc($c->stash('email') // '');
    return _options($c, $ALLOW_ROOT) if $method eq 'OPTIONS';
    return _plain($c, 403, 'Those are not your calendars.') unless $email eq _me($c);
    return _plain($c, 200, "The calendars of $email. A calendar app lists them by itself.") if $method eq 'GET' || $method eq 'HEAD';
    return _plain($c, 403, 'Make a calendar under its own address: MKCALENDAR /dav/calendars/<you>/<name>/.') if $method eq 'MKCALENDAR' || $method eq 'MKCOL';
    return _dav_error($c, 403, '<D:supported-report/>') if $method eq 'REPORT';
    return _not_allowed($c, $ALLOW_ROOT) unless $method eq 'PROPFIND';
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    my $wanted = _wanted(_root_of($doc));
    my $body = _response(_home_href($email), _props(_home_props($c, $email), $wanted, @HOME_DEFAULT));
    if (_depth($c) >= 1) {
        my $all = _m($c)->calendars_for($email);
        $body .= _response(_cal_href($email, $_), _props(_calendar_props($c, $email, $_), $wanted, @CALENDAR_DEFAULT)) for @{ $all->{own} }, @{ $all->{shared} };
    }
    return _multistatus($c, $body);
}

# The calendar a path names, with the viewer's permission on it, or ().
sub _cal_for ($c, $email, $seg) {
    my $m = _m($c);
    my $cal = $m->calendar_by_dav_name($email, $seg) or return ();
    my $perm = $m->permission_for_calendar($email, $cal) or return ();
    $cal->{permission} = $perm;
    return ($cal);
}

# /dav/calendars/<email>/<cal>/
sub calendar ($c) {
    my $method = uc $c->req->method;
    my $email = lc($c->stash('email') // '');
    my $seg = $c->stash('cal') // '';
    return _options($c, $ALLOW_COLLECTION) if $method eq 'OPTIONS';
    return _plain($c, 403, 'Those are not your calendars.') unless $email eq _me($c);
    my ($cal) = _cal_for($c, $email, $seg);
    unless ($cal) {
        return _mkcalendar($c, $email, $seg) if $method eq 'MKCALENDAR';
        return _plain($c, 404, 'No such calendar.');
    }
    my $m = _m($c);
    if ($method eq 'MKCALENDAR' || $method eq 'MKCOL') { $c->res->headers->allow($ALLOW_COLLECTION); return _plain($c, 405, 'That calendar exists already.') }
    if ($method eq 'GET' || $method eq 'HEAD') {
        # The whole calendar as one iCalendar file, rules kept: what a desktop
        # app that only reads ICS subscribes to.
        _dav_headers($c);
        $c->res->headers->content_type('text/calendar; charset=utf-8');
        return $c->render(data => masters_ics(name => $cal->{name}, zone => $cal->{timezone}, description => $cal->{description},
            events => [ map { $m->masters_entry($_) } @{ $m->dav_events($cal->{id}) } ]));
    }
    if ($method eq 'PROPFIND') {
        my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
        my $wanted = _wanted(_root_of($doc));
        my $body = _response(_cal_href($email, $cal), _props(_calendar_props($c, $email, $cal), $wanted, @CALENDAR_DEFAULT));
        if (_depth($c) >= 1) { $body .= _object_response($c, $email, $cal, $_, $wanted) for @{ $m->dav_events($cal->{id}) } }
        return _multistatus($c, $body);
    }
    if ($method eq 'REPORT') {
        my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
        my $root = _root_of($doc) or return _plain($c, 400, 'A REPORT needs a body.');
        return _report_query($c, $root, $email, $cal)    if _is($root, 'C', 'calendar-query');
        return _report_multiget($c, $root, $email, $cal) if _is($root, 'C', 'calendar-multiget');
        return _report_sync($c, $root, $email, $cal)     if _is($root, 'D', 'sync-collection');
        return _dav_error($c, 403, '<D:supported-report/>');
    }
    return _proppatch($c, $email, $cal) if $method eq 'PROPPATCH';
    if ($method eq 'DELETE') {
        return _plain($c, 403, 'Only the calendar\'s owner can delete it.') unless may_manage($cal->{permission});
        $m->delete_calendar($cal);
        return _empty($c, 204);
    }
    return _plain($c, 409, 'An event goes at /<uid>.ics inside the calendar, not at the calendar itself.') if $method eq 'PUT';
    return _not_allowed($c, $ALLOW_COLLECTION);
}

# /dav/calendars/<email>/<cal>/<uid>.ics
sub object ($c) {
    my $method = uc $c->req->method;
    my $email = lc($c->stash('email') // '');
    my $seg = $c->stash('cal') // '';
    my $name = $c->stash('obj') // '';
    return _options($c, $ALLOW_OBJECT) if $method eq 'OPTIONS';
    return _plain($c, 403, 'Those are not your calendars.') unless $email eq _me($c);
    my ($cal) = _cal_for($c, $email, $seg) or return _plain($c, 404, 'No such calendar.');
    (my $uid = $name) =~ s/\.ics\z//i;
    return _plain($c, 404, 'No such event.') unless length $uid && length $uid <= 255;
    return _put_object($c, $email, $cal, $uid) if $method eq 'PUT';
    my $m = _m($c);
    my $e = $m->event_in_calendar_by_uid($cal->{id}, $uid) or return _plain($c, 404, 'No such event.');
    if ($method eq 'GET' || $method eq 'HEAD') {
        _dav_headers($c);
        $c->res->headers->etag(_etag($e));
        $c->res->headers->last_modified(Mojo::Date->new(Homelab::Calendar::Model::_dt($e->{updated_at})->epoch)->to_string);
        $c->res->headers->content_type('text/calendar; charset=utf-8');
        return $c->render(data => _object_ics($m, $cal, $e));
    }
    return _delete_object($c, $cal, $e) if $method eq 'DELETE';
    if ($method eq 'PROPFIND') {
        my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
        return _multistatus($c, _object_response($c, $email, $cal, $e, _wanted(_root_of($doc))));
    }
    return _plain($c, 403, 'An event has no properties to change this way; PUT the event.') if $method eq 'PROPPATCH';
    return _not_allowed($c, $ALLOW_OBJECT);
}

# ------------------------------------------------------------------ the reports

# calendar-query: the objects with an occurrence in the time-range asked for
# (or all of them). A filter for anything but VEVENT matches nothing here.
sub _report_query ($c, $root, $email, $cal) {
    my $wanted = _wanted($root);
    my ($ws, $we, $vevent) = _query_window($root);
    my @events = $vevent ? @{ _m($c)->dav_events($cal->{id}, (($ws && $we) ? (window_start => $ws, window_end => $we) : ())) } : ();
    return _multistatus($c, join '', map { _object_response($c, $email, $cal, $_, $wanted) } @events);
}
sub _query_window ($root) {
    my $filter = _child($root, 'C', 'filter') or return (undef, undef, 1);
    my ($vcal) = _children($filter, 'C', 'comp-filter') or return (undef, undef, 1);
    return (undef, undef, 0) unless uc($vcal->getAttribute('name') // '') eq 'VCALENDAR';
    my @inner = _children($vcal, 'C', 'comp-filter') or return (undef, undef, 1);
    my ($ev) = grep { uc($_->getAttribute('name') // '') eq 'VEVENT' } @inner;
    return (undef, undef, 0) unless $ev;
    my $tr = _child($ev, 'C', 'time-range') or return (undef, undef, 1);
    my $ws = _utc($tr->getAttribute('start')) // DateTime->new(year => 1970, time_zone => 'UTC');
    my $we = _utc($tr->getAttribute('end'))   // DateTime->new(year => 2100, time_zone => 'UTC');
    return (undef, undef, 1) unless $we > $ws;
    return ($ws, $we, 1);
}
sub _utc ($s) {
    return undef unless defined $s && $s =~ /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/;
    return eval { DateTime->new(year => $1, month => $2, day => $3, hour => $4, minute => $5, second => $6, time_zone => 'UTC') };
}

# calendar-multiget: the objects named by href, 404 for one that is not here.
sub _report_multiget ($c, $root, $email, $cal) {
    my $wanted = _wanted($root);
    my $m = _m($c);
    my @hrefs = map { _text($_) } _children($root, 'D', 'href');
    @hrefs = @hrefs[0 .. 499] if @hrefs > 500;
    my $out = '';
    for my $h (@hrefs) {
        my $uid = _uid_from_href($h);
        my $e = defined $uid ? $m->event_in_calendar_by_uid($cal->{id}, $uid) : undef;
        $out .= $e ? _object_response($c, $email, $cal, $e, $wanted) : _response($h, [], [], '404 Not Found');
    }
    return _multistatus($c, $out);
}
sub _uid_from_href ($h) {
    my $last = eval { Mojo::URL->new($h)->path->parts->[-1] };
    return undef unless defined $last && length $last;
    $last =~ s/\.ics\z//i;
    return length $last ? $last : undef;
}

# sync-collection: what changed since the token, deleted events as 404s, and
# the token to ask with next time. A token this calendar never gave (or one
# from the future) is refused so the client starts over.
sub _report_sync ($c, $root, $email, $cal) {
    my $wanted = _wanted($root);
    my $m = _m($c);
    my $given = _text(_child($root, 'D', 'sync-token'));
    my $current = $m->sync_seq($cal->{id});
    my $since = 0;
    if (length $given) {
        ($since) = $given =~ m{/ns/sync/(\d{1,18})\z};
        return _dav_error($c, 403, '<D:valid-sync-token/>') unless defined $since && $since <= $current;
    }
    my $out = '';
    my $max = $since;
    for my $r (@{ $m->events_changed_since($cal->{id}, $since) }) {
        $max = $r->{change_seq} if $r->{change_seq} > $max;
        if ($r->{deleted_at}) { $out .= _response(_obj_href($email, $cal, $r->{uid}), [], [], '404 Not Found'); next }
        my $e = $m->event($r->{id}) or next;
        $out .= _object_response($c, $email, $cal, $e, $wanted);
    }
    $out .= '<D:sync-token>' . _esc(_token($c, $max)) . "</D:sync-token>\n";
    return _multistatus($c, $out);
}

# ------------------------------------------------------------------- the writes

sub _etag_ok ($hdr, $e) {
    return 1 if $hdr =~ /\*/;
    my $tag = _etag($e);
    return (grep { $_ eq $tag } ($hdr =~ /("[^"]*")/g)) ? 1 : 0;
}

# PUT one event: a new UID creates, a known one replaces (If-Match checked
# against the ETag, If-None-Match: * refused when it is there). The body is
# read by the import's parser; its EXDATEs, RECURRENCE-ID components and
# first alarm become the event's exceptions and reminder, replacing what was
# there, so the object reads back as it was written.
sub _put_object ($c, $email, $cal, $uid_path) {
    my $m = _m($c);
    return _plain($c, 403, 'You can see this calendar but not change it.') unless may_edit($cal->{permission});
    my $text = $c->req->body // '';
    return _plain($c, 413, 'The event is too large (2 MB at most).') if length $text > $MAX_BODY;
    my $parsed = parse_ics($text, zone => $cal->{timezone});
    return _dav_error($c, 403, '<C:valid-calendar-data/>') if $parsed->{error};
    my @masters = @{ $parsed->{events} };
    return _dav_error($c, 403, '<C:valid-calendar-object-resource/>') unless @masters == 1;
    my $in = $masters[0];
    my $uid = (defined $in->{uid} && length $in->{uid}) ? $in->{uid} : $uid_path;
    my $existing = $m->event_in_calendar_by_uid($cal->{id}, $uid_path) // ($uid ne $uid_path ? $m->event_in_calendar_by_uid($cal->{id}, $uid) : undef);
    my $if_match = $c->req->headers->header('If-Match');
    my $if_none  = $c->req->headers->header('If-None-Match');
    my %input = map { $_ => $in->{$_} } qw(title description location all_day start end timezone repeat);
    my ($row, $status);
    if ($existing) {
        return _plain($c, 412, 'That event is already there (If-None-Match).') if defined $if_none && $if_none =~ /\*/;
        return _plain($c, 412, 'The event changed since it was fetched; fetch it again.') if defined $if_match && !_etag_ok($if_match, $existing);
        $row = eval { $m->update_event($existing, \%input) };
        return _plain($c, 400, _why($@)) unless $row;
        $m->clear_exceptions($row->{id});
        $status = 204;
    }
    else {
        return _plain($c, 412, 'There is no such event to replace (If-Match).') if defined $if_match;
        # A UID this calendar does not hold but another place does. In another
        # calendar the person may change: the phone is moving the event here
        # (it PUTs the copy first and deletes the old one after), so the row
        # changes calendars. In a trash: the phone is putting back what was
        # deleted, so that event comes back rather than a twin appearing.
        my $taken = $m->event_by_uid($uid) // $m->trashed_event_by_uid(undef, $uid);
        if ($taken) {
            my $tcal  = $m->calendar($taken->{calendar_id});
            my $tperm = ($tcal && $tcal->{id} == $cal->{id}) ? $cal->{permission}
                      : $tcal ? $m->permission_for_event(_me($c), { %$taken, deleted_at => undef }, $tcal) : undef;
            return _dav_error($c, 403, '<C:no-uid-conflict/>') unless $tperm && may_edit($tperm);
            $m->restore_event($taken->{id}) if $taken->{deleted_at};
            $m->move_event_to_calendar($taken->{id}, $cal->{id}) if $taken->{calendar_id} != $cal->{id};
            $row = eval { $m->update_event($m->event($taken->{id}), \%input) };
            return _plain($c, 400, _why($@)) unless $row;
            $m->clear_exceptions($row->{id});
        }
        else {
            $row = eval { $m->create_event($cal, _me($c), { %input, uid => $uid }) };
            return _plain($c, 400, _why($@)) unless $row;
        }
        $status = 201;
    }
    if ($row->{rrule}) {
        for my $x (@{ $in->{exdates} // [] }) {
            my $rid = parse_wall($x, $row->{timezone}) or next;
            eval { $m->_write_exception($row, $rid, {}, 1) };
        }
        for my $o (@{ $parsed->{overrides} // [] }) {
            my $rid = parse_wall($o->{recurrence_id}, $row->{timezone}) or next;
            eval { $m->_write_exception($row, $rid, { map { $_ => $o->{$_} } qw(title description location all_day start end timezone) }, 0) };
        }
    }
    eval { $m->set_reminders($row->{id}, defined $in->{reminder_minutes} ? [ { minutes_before => $in->{reminder_minutes}, channel => 'email' } ] : []) };
    my $fresh = $m->event($row->{id}) // $row;
    _dav_headers($c);
    $c->res->headers->etag(_etag($fresh));
    return $c->render(data => '', status => $status);
}

sub _delete_object ($c, $cal, $e) {
    return _plain($c, 403, 'You can see this calendar but not change it.') unless may_edit($cal->{permission});
    my $if_match = $c->req->headers->header('If-Match');
    return _plain($c, 412, 'The event changed since it was fetched.') if defined $if_match && !_etag_ok($if_match, $e);
    _m($c)->delete_event($e);
    return _empty($c, 204);
}

# <D:set><D:prop> of a MKCALENDAR or PROPPATCH body: the properties a
# calendar keeps here (name, colour, description, order) and the names of
# the others, which are refused.
sub _patch_props ($root) {
    my %p = (_other => [], _removed => []);
    return %p unless $root;
    for my $set (_children($root, 'D', 'set')) {
        my $prop = _child($set, 'D', 'prop') or next;
        for my $n (_elements($prop)) {
            my $qn = _qn($n);
            my $v  = _text($n);
            if    ($qn eq '{DAV:}displayname')            { $p{name} = substr($v =~ s/\s+/ /gr, 0, 100) }
            elsif ($qn eq "{$NS{A}}calendar-color")       { my ($hex) = $v =~ /\A#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?\z/; $p{color} = $hex ? "#\L$hex" : undef }
            elsif ($qn eq "{$NS{C}}calendar-description") { $p{description} = length $v ? substr($v, 0, 1000) : undef }
            elsif ($qn eq "{$NS{A}}calendar-order")       { $p{position} = $v =~ /\A(\d{1,6})\z/ ? $1 + 0 : undef }
            else                                          { push @{ $p{_other} }, $qn }
        }
    }
    for my $rm (_children($root, 'D', 'remove')) {
        my $prop = _child($rm, 'D', 'prop') or next;
        push @{ $p{_removed} }, map { _qn($_) } _elements($prop);
    }
    return %p;
}

# MKCALENDAR /dav/calendars/<me>/<name>/: a new calendar at the name the
# client chose (not a number: those are the calendars' own).
sub _mkcalendar ($c, $email, $seg) {
    return _plain($c, 403, 'Make calendars under your own address.') unless $email eq _me($c);
    return _plain($c, 400, 'A calendar\'s address here is letters, digits, dots and dashes (1-128), not a number alone.')
        unless $seg =~ /\A[A-Za-z0-9._~-]{1,128}\z/ && $seg !~ /\A\d+\z/;
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    my %p = _patch_props(_root_of($doc));
    my $m = _m($c);
    my $cal = eval { $m->create_calendar($email, name => (length($p{name} // '') ? $p{name} : $seg), color => $p{color}, description => $p{description}) };
    return _plain($c, 400, _why($@)) unless $cal;
    $m->set_dav_name($cal->{id}, $seg);
    $m->update_calendar($cal->{id}, position => $p{position}) if defined $p{position};
    return _empty($c, 201);
}

# PROPPATCH on a calendar: its name, colour, description and order; anything
# else is refused in the propstat, as the spec has it.
sub _proppatch ($c, $email, $cal) {
    return _plain($c, 403, 'Only the calendar\'s owner can change its settings.') unless may_manage($cal->{permission});
    my ($doc, $err) = _xml($c); return _plain($c, 400, $err) if $err;
    my $root = _root_of($doc) or return _plain($c, 400, 'A PROPPATCH needs a propertyupdate body.');
    my %p = _patch_props($root);
    my (%set, @ok, @bad);
    if (exists $p{name})        { if (length $p{name})      { $set{name} = $p{name}; push @ok, '{DAV:}displayname' }               else { push @bad, '{DAV:}displayname' } }
    if (exists $p{color})       { if ($p{color})            { $set{color} = $p{color}; push @ok, "{$NS{A}}calendar-color" }         else { push @bad, "{$NS{A}}calendar-color" } }
    if (exists $p{description}) { $set{description} = $p{description}; push @ok, "{$NS{C}}calendar-description" }
    if (exists $p{position})    { if (defined $p{position}) { $set{position} = $p{position}; push @ok, "{$NS{A}}calendar-order" }  else { push @bad, "{$NS{A}}calendar-order" } }
    push @bad, @{ $p{_other} }, @{ $p{_removed} };
    _m($c)->update_calendar($cal->{id}, %set) if %set;
    my $x = '<D:response><D:href>' . _esc(_cal_href($email, $cal)) . '</D:href>';
    $x .= '<D:propstat><D:prop>' . join('', map { _empty_tag($_) } @ok)  . '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>' if @ok;
    $x .= '<D:propstat><D:prop>' . join('', map { _empty_tag($_) } @bad) . '</D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat>' if @bad;
    return _multistatus($c, $x . "</D:response>\n");
}

1;
