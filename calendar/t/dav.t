use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use Mojo::URL;
use Mojo::Util qw(b64_encode url_escape);
use XML::LibXML;
use lib 'lib';

# CalDAV end to end (post-cutover #84): the discovery an iPhone and DAVx5
# do, the sign-in with an app password, objects in and out with ETags, the
# three reports, calendars made and changed by a client, a read-only share,
# and bad input. Needs TEST_PG_URL with the calendar migrations applied;
# the SSO side is not involved (that is the point of app passwords).
plan skip_all => 'TEST_PG_URL not set (a PostgreSQL with the calendar schema)' unless $ENV{TEST_PG_URL};

my $u = Mojo::URL->new($ENV{TEST_PG_URL});
my ($dbuser, $dbpass) = split /:/, ($u->userinfo // ''), 2;
my $dbname = $u->path->to_string =~ s{^/}{}r;
my $dir = tempdir;
my $cfg = $dir->child('config.yml');
$cfg->spew(<<"YAML");
homelab_api:
  base_url: "http://127.0.0.1:9"
database:
  host: "@{[ $u->host ]}"
  port: @{[ $u->port // 5432 ]}
  name: "$dbname"
  user: "$dbuser"
  password: "$dbpass"
calendar:
  public_base_url: "https://calendar.example.test/"
  default_timezone: America/Chicago
server:
  listen: "http://127.0.0.1:0"
YAML
$ENV{HOMELAB_CALENDAR_CONFIG} = $cfg->to_string;
$ENV{HOMELAB_CALENDAR_HOME}   = '.';
$ENV{HOMELAB_WEBTHEME_HOME}   = '../webtheme';
$ENV{HOMELAB_CALENDAR_RUNNER} = '0';

my $t = Test::Mojo->new('Homelab::Calendar::App');
my $m = $t->app->model;
my $ME    = 'dav-' . int(rand 1e9) . '@example.test';
my $OTHER = 'dav-other-' . int(rand 1e9) . '@example.test';
my $cal = $m->ensure_default_calendar($ME, 'America/Chicago');
my $dev = $m->create_app_password($ME, 'Test phone');
my %H = (Authorization => 'Basic ' . b64_encode("$ME:$dev->{secret}", ''));
my $esc_me  = url_escape($ME, '^A-Za-z0-9\-._~@');
my $home    = "/dav/calendars/$esc_me/";
my $calhref = $home . "$cal->{id}/";

sub xml ($t) { return XML::LibXML->load_xml(string => $t->tx->res->body) }
sub xpc ($doc) {
    my $x = XML::LibXML::XPathContext->new($doc);
    $x->registerNs(D => 'DAV:'); $x->registerNs(C => 'urn:ietf:params:xml:ns:caldav');
    $x->registerNs(CS => 'http://calendarserver.org/ns/'); $x->registerNs(A => 'http://apple.com/ns/ical/');
    return $x;
}
sub hrefs ($t) { my $x = xpc(xml($t)); return [ map { $_->textContent } $x->findnodes('/D:multistatus/D:response/D:href') ] }
sub resp ($x, $href) { my ($r) = grep { $x->findvalue('D:href', $_) eq $href } $x->findnodes('/D:multistatus/D:response'); return $r }
sub prop ($t, $href, $xpath) { my $x = xpc(xml($t)); my $r = resp($x, $href) or return undef; return $x->findvalue($xpath, $r) }
sub ok200 ($t, $href, $name) { my $x = xpc(xml($t)); my $r = resp($x, $href) or return 0; return $x->findnodes("D:propstat[D:status='HTTP/1.1 200 OK']/D:prop/$name", $r)->size }
sub ok404 ($t, $href, $name) { my $x = xpc(xml($t)); my $r = resp($x, $href) or return 0; return $x->findnodes("D:propstat[D:status='HTTP/1.1 404 Not Found']/D:prop/$name", $r)->size }
my $PF     = sub ($path, $depth, $body = '', %extra) { return $t->request_ok($t->ua->build_tx(PROPFIND => $path => { %H, Depth => $depth, %extra } => $body)) };
my $REPORT = sub ($path, $body, %extra) { return $t->request_ok($t->ua->build_tx(REPORT => $path => { %H, Depth => 1, 'Content-Type' => 'application/xml', %extra } => $body)) };
my $PUT    = sub ($path, $body, %extra) { return $t->request_ok($t->ua->build_tx(PUT => $path => { %H, 'Content-Type' => 'text/calendar; charset=utf-8', %extra } => $body)) };
my $TX     = sub ($method, $path, $body = '', %extra) { return $t->request_ok($t->ua->build_tx($method => $path => { %H, %extra } => $body)) };

# --- the door ---
$t->get_ok('/.well-known/caldav')->status_is(301)->header_is(Location => 'https://calendar.example.test/dav/', 'the well-known path points at /dav/');
$t->options_ok('/dav/')->status_is(200)->header_like(DAV => qr/calendar-access/, 'OPTIONS says CalDAV before any sign-in')->header_like(Allow => qr/PROPFIND/);
$t->request_ok($t->ua->build_tx(PROPFIND => '/dav/'))->status_is(401)->header_like('WWW-Authenticate' => qr/^Basic realm="calendar\.example\.test/, 'no sign-in: a Basic challenge naming the host');
$t->request_ok($t->ua->build_tx(PROPFIND => '/dav/' => { Authorization => 'Basic ' . b64_encode("$ME:wrong-secret-wrong-secret", '') }))->status_is(401, 'a wrong app password is refused');
$t->request_ok($t->ua->build_tx(PROPFIND => '/dav/' => { Authorization => 'Bearer not-for-here' }))->status_is(401, 'a Bearer token is not a CalDAV sign-in');
$t->get_ok('/dav/' => \%H)->status_is(200)->content_like(qr/app password/, 'GET of the root is a plain explanation');

# --- discovery: root -> principal -> home -> calendars ---
$PF->('/dav/', 0, '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/><D:resourcetype/></D:prop></D:propfind>')
  ->status_is(207)->content_type_like(qr{application/xml});
is prop($t, '/dav/', 'D:propstat/D:prop/D:current-user-principal/D:href'), "/dav/principals/$esc_me/", 'the root names my principal';
$PF->('/', 0, '<?xml version="1.0" encoding="UTF-8"?><A:propfind xmlns:A="DAV:"><A:prop><A:current-user-principal/><A:principal-URL/><A:resourcetype/></A:prop></A:propfind>')
  ->status_is(207, 'PROPFIND of the site root answers too (an iPhone asks it)');
is prop($t, '/', 'D:propstat/D:prop/D:current-user-principal/D:href'), "/dav/principals/$esc_me/", '... with the same principal, whatever prefix the client used';
$t->request_ok($t->ua->build_tx(PROPFIND => '/'))->status_is(401, '... after the same sign-in');
$t->get_ok('/')->status_is(302, '... and GET / is still the web app');
$PF->("/dav/principals/$esc_me/", 0, '<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/"><D:prop><C:calendar-home-set/><C:calendar-user-address-set/><D:displayname/><CS:nothing-of-the-kind/></D:prop></D:propfind>')->status_is(207);
is prop($t, "/dav/principals/$esc_me/", "D:propstat[D:status='HTTP/1.1 200 OK']/D:prop/C:calendar-home-set/D:href"), $home, 'the principal names the calendar home';
is prop($t, "/dav/principals/$esc_me/", "D:propstat[D:status='HTTP/1.1 200 OK']/D:prop/C:calendar-user-address-set/D:href"), "mailto:$ME", '... and a mailto address';
ok ok404($t, "/dav/principals/$esc_me/", 'CS:nothing-of-the-kind'), 'a property that is not here is in the 404 propstat';
$PF->("/dav/principals/$OTHER/", 0)->status_is(403, 'somebody else\'s principal: 403');
$PF->('/dav/principals/', 1)->status_is(207);
is_deeply hrefs($t), [ '/dav/principals/', "/dav/principals/$esc_me/" ], 'the principals folder holds mine';
$PF->($home, 1)->status_is(207);
my $hr = hrefs($t);
is $hr->[0], $home, 'the home comes first';
ok((grep { $_ eq $calhref } @$hr), '... then my calendar');
my $x = xpc(xml($t));
my $cr = resp($x, $calhref);
ok $x->findnodes('D:propstat/D:prop/D:resourcetype/C:calendar', $cr)->size, 'the calendar is a C:calendar collection';
is $x->findvalue('D:propstat/D:prop/D:displayname', $cr), 'My calendar', '... named';
like $x->findvalue('D:propstat/D:prop/A:calendar-color', $cr), qr/^#[0-9A-F]{6}FF$/, '... coloured in Apple\'s form';
like $x->findvalue('D:propstat/D:prop/D:sync-token', $cr), qr{^https://calendar\.example\.test/ns/sync/\d+$}, '... with a sync token';
like $x->findvalue('D:propstat/D:prop/CS:getctag', $cr), qr/^c\d+$/, '... and a ctag';
ok $x->findnodes('D:propstat/D:prop/D:current-user-privilege-set/D:privilege/D:write', $cr)->size, 'I may write to my own calendar';
ok $x->findnodes('D:propstat/D:prop/D:supported-report-set/D:supported-report/D:report/D:sync-collection', $cr)->size, '... and it offers sync-collection';
$PF->($calhref, 0, '<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><C:supported-calendar-component-set/><C:calendar-timezone/><D:quota-used-bytes/></D:prop></D:propfind>')->status_is(207);
ok ok200($t, $calhref, 'C:supported-calendar-component-set/C:comp[@name="VEVENT"]'), 'events only';
ok ok404($t, $calhref, 'C:calendar-timezone') && ok404($t, $calhref, 'D:quota-used-bytes'), 'what is not kept is 404, not an error';
$PF->("${home}no-such-calendar/", 0)->status_is(404, 'a calendar that is not there: 404');
$PF->("/dav/calendars/$OTHER/", 1)->status_is(403, 'somebody else\'s home: 403');

# --- PUT a new event, GET it back, replace it with ETags ---
my $uid = 'test-' . int(rand 1e9) . '-phone';
my $obj = "$calhref$uid.ics";
my $ics = join "\r\n", 'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Test//Phone//EN', 'BEGIN:VEVENT', "UID:$uid", 'DTSTAMP:20261116T120000Z',
    'DTSTART;TZID=America/Chicago:20261201T083000', 'DTEND;TZID=America/Chicago:20261201T093000', 'SUMMARY:Infusion', 'LOCATION:NKC Health',
    'BEGIN:VALARM', 'ACTION:DISPLAY', 'TRIGGER:-PT30M', 'DESCRIPTION:Infusion', 'END:VALARM', 'END:VEVENT', 'END:VCALENDAR', '';
$PUT->($obj, $ics, 'If-None-Match' => '*')->status_is(201, 'a new event is created')->header_like(ETag => qr/^"\d+"$/, '... with an ETag');
my $etag1 = $t->tx->res->headers->etag;
my $row = $m->event_in_calendar_by_uid($cal->{id}, $uid);
ok $row, 'it is in the calendar';
is $row->{title}, 'Infusion', '... titled';
is $row->{location}, 'NKC Health', '... placed';
is $row->{timezone}, 'America/Chicago', '... in the zone the file said';
is Homelab::Calendar::Model::_dt($row->{starts_at}, 'UTC')->strftime('%Y-%m-%dT%H:%M'), '2026-12-01T14:30', '8:30 Chicago is 14:30 UTC';
is_deeply [ map { $_->{minutes_before} } @{ $m->reminders_for($row->{id}) } ], [30], 'the alarm became the reminder';
$t->get_ok($obj => \%H)->status_is(200)->content_type_like(qr{text/calendar})->header_is(ETag => $etag1, 'GET gives the same ETag')
  ->content_like(qr/UID:\Q$uid\E/)->content_like(qr/SUMMARY:Infusion/)->content_like(qr/TRIGGER:-PT30M/, '... the alarm reads back')
  ->content_like(qr/DTSTART;TZID=America\/Chicago:20261201T083000/)->content_unlike(qr/^METHOD:/m, 'no METHOD in an object');
$t->head_ok($obj => \%H)->status_is(200)->header_is(ETag => $etag1, 'HEAD too');
$PUT->($obj, $ics, 'If-None-Match' => '*')->status_is(412, 'If-None-Match: * on an event that is there: 412');
(my $ics2 = $ics) =~ s/SUMMARY:Infusion/SUMMARY:Infusion (moved)/;
$ics2 =~ s{DTSTART;TZID=America/Chicago:20261201T083000}{DTSTART;TZID=America/Chicago:20261201T093000};
$ics2 =~ s{DTEND;TZID=America/Chicago:20261201T093000}{DTEND;TZID=America/Chicago:20261201T103000};
$ics2 =~ s/BEGIN:VALARM.*?END:VALARM\r\n//s;
$PUT->($obj, $ics2, 'If-Match' => '"999999999"')->status_is(412, 'a stale If-Match: 412');
$PUT->($obj, $ics2, 'If-Match' => $etag1)->status_is(204, 'the right If-Match replaces it');
my $etag2 = $t->tx->res->headers->etag;
isnt $etag2, $etag1, '... with a new ETag';
$row = $m->event($row->{id});
is $row->{title}, 'Infusion (moved)', 'the title changed';
is Homelab::Calendar::Model::_dt($row->{starts_at}, 'UTC')->strftime('%H:%M'), '15:30', '... and the time';
is_deeply $m->reminders_for($row->{id}), [], 'no alarm in the file: no reminder';
$PUT->($obj, $ics2)->status_is(204, 'without conditions it just replaces');

# --- the reports ---
$REPORT->($calhref, '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20261130T000000Z" end="20261202T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>')->status_is(207);
is_deeply hrefs($t), [$obj], 'calendar-query in its window finds it';
like prop($t, $obj, 'D:propstat/D:prop/C:calendar-data'), qr/SUMMARY:Infusion \(moved\)/, '... with the data';
like prop($t, $obj, 'D:propstat/D:prop/D:getetag'), qr/^"\d+"$/, '... and the ETag';
$REPORT->($calhref, '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20270101T000000Z" end="20270201T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>')->status_is(207);
is_deeply hrefs($t), [], 'outside the window: nothing';
$REPORT->($calhref, '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter></C:filter></C:calendar-query>')->status_is(207);
is_deeply hrefs($t), [], 'asking for tasks: nothing, there are none';
$REPORT->($calhref, '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop></C:calendar-query>')->status_is(207);
is_deeply hrefs($t), [$obj], 'no filter at all: everything';
$REPORT->($calhref, qq{<C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><D:href>$obj</D:href><D:href>${calhref}nothing-here.ics</D:href></C:calendar-multiget>})->status_is(207);
$x = xpc(xml($t));
like $x->findvalue(qq{/D:multistatus/D:response[D:href="$obj"]/D:propstat/D:prop/C:calendar-data}), qr/BEGIN:VEVENT/, 'multiget answers the one that is here';
like $x->findvalue(qq{/D:multistatus/D:response[D:href="${calhref}nothing-here.ics"]/D:status}), qr/404/, '... and 404 for the one that is not';

$REPORT->($calhref, '<D:sync-collection xmlns:D="DAV:"><D:sync-token/><D:sync-level>1</D:sync-level><D:prop><D:getetag/></D:prop></D:sync-collection>', Depth => 0)->status_is(207);
my $token1 = xpc(xml($t))->findvalue('/D:multistatus/D:sync-token');
like $token1, qr{/ns/sync/\d+$}, 'an initial sync hands out a token';
is_deeply hrefs($t), [$obj], '... and lists the event';
$REPORT->($calhref, qq{<D:sync-collection xmlns:D="DAV:"><D:sync-token>$token1</D:sync-token><D:sync-level>1</D:sync-level><D:prop><D:getetag/></D:prop></D:sync-collection>})->status_is(207);
is_deeply hrefs($t), [], 'nothing changed since: nothing listed';
is xpc(xml($t))->findvalue('/D:multistatus/D:sync-token'), $token1, '... and the same token';
$m->update_event($m->event($row->{id}), { title => 'Infusion (web edit)' });
$REPORT->($calhref, qq{<D:sync-collection xmlns:D="DAV:"><D:sync-token>$token1</D:sync-token><D:sync-level>1</D:sync-level><D:prop><D:getetag/></D:prop></D:sync-collection>})->status_is(207);
is_deeply hrefs($t), [$obj], 'an edit made on the web is a change';
my $token2 = xpc(xml($t))->findvalue('/D:multistatus/D:sync-token');
isnt $token2, $token1, '... with a newer token';
$REPORT->($calhref, '<D:sync-collection xmlns:D="DAV:"><D:sync-token>https://calendar.example.test/ns/sync/99999999999</D:sync-token><D:prop><D:getetag/></D:prop></D:sync-collection>')
  ->status_is(403)->content_like(qr/valid-sync-token/, 'a token from the future is refused with the precondition');
$REPORT->($calhref, '<D:sync-collection xmlns:D="DAV:"><D:sync-token>garbage</D:sync-token><D:prop><D:getetag/></D:prop></D:sync-collection>')->status_is(403, '... so is garbage');

# --- DELETE, and the sync says so ---
$TX->(DELETE => $obj, '', 'If-Match' => '"1"')->status_is(412, 'DELETE with a stale If-Match: 412');
$TX->(DELETE => $obj)->status_is(204, 'DELETE removes it');
$t->get_ok($obj => \%H)->status_is(404, '... and it is gone');
ok $m->deleted_event($row->{id}), '... into the trash';
$REPORT->($calhref, qq{<D:sync-collection xmlns:D="DAV:"><D:sync-token>$token2</D:sync-token><D:prop><D:getetag/></D:prop></D:sync-collection>})->status_is(207);
like xpc(xml($t))->findvalue(qq{/D:multistatus/D:response[D:href="$obj"]/D:status}), qr/404/, 'the deletion is reported as a 404 entry';
$PUT->($obj, $ics)->status_is(201, 'putting the same UID back restores it');
is $m->event_in_calendar_by_uid($cal->{id}, $uid)->{id}, $row->{id}, '... the same event, out of the trash';
$TX->(DELETE => $obj)->status_is(204);

# --- a series with a cancelled day and a moved occurrence, round trip ---
my $uid2 = 'test-' . int(rand 1e9) . '-series';
my $obj2 = "$calhref$uid2.ics";
my $series = join "\r\n", 'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Test//EN',
    'BEGIN:VEVENT', "UID:$uid2", 'DTSTAMP:20261116T120000Z', 'DTSTART;TZID=America/Chicago:20261202T090000', 'DTEND;TZID=America/Chicago:20261202T093000',
    'RRULE:FREQ=DAILY;COUNT=5', 'EXDATE;TZID=America/Chicago:20261204T090000', 'SUMMARY:Standup', 'END:VEVENT',
    'BEGIN:VEVENT', "UID:$uid2", 'RECURRENCE-ID;TZID=America/Chicago:20261203T090000', 'DTSTAMP:20261116T120000Z',
    'DTSTART;TZID=America/Chicago:20261203T100000', 'DTEND;TZID=America/Chicago:20261203T103000', 'SUMMARY:Standup (late)', 'END:VEVENT',
    'END:VCALENDAR', '';
$PUT->($obj2, $series)->status_is(201, 'a series with a cancelled day and a moved occurrence is created');
my $srow = $m->event_in_calendar_by_uid($cal->{id}, $uid2);
is $srow->{rrule}, 'FREQ=DAILY;COUNT=5', 'the rule is kept';
my $exc = $m->exceptions_for($srow->{id});
is scalar @$exc, 2, 'two exceptions';
is scalar(grep { $_->{cancelled} } @$exc), 1, '... one of them cancelled';
$t->get_ok($obj2 => \%H)->status_is(200)->content_like(qr/RRULE:FREQ=DAILY;COUNT=5/)->content_like(qr{EXDATE;TZID=America/Chicago:20261204T090000})
  ->content_like(qr{RECURRENCE-ID;TZID=America/Chicago:20261203T090000})->content_like(qr/SUMMARY:Standup \(late\)/, 'it reads back whole');
(my $series2 = $series) =~ s/BEGIN:VEVENT\r\nUID:\Q$uid2\E\r\nRECURRENCE-ID.*?END:VEVENT\r\n//s;
$PUT->($obj2, $series2)->status_is(204, 'a PUT without the moved occurrence');
is scalar @{ $m->exceptions_for($srow->{id}) }, 1, '... drops it and keeps the cancelled day';
$REPORT->($calhref, '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20261205T000000Z" end="20261207T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>')->status_is(207);
is_deeply hrefs($t), [$obj2], 'a window a later occurrence falls in finds the series (the phone expands it)';

# --- a calendar made, changed and removed by the client ---
my $seg = 'phone-' . int(rand 1e6);
$TX->(MKCALENDAR => "$home$seg/", '<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:A="http://apple.com/ns/ical/"><D:set><D:prop><D:displayname>From the phone</D:displayname><A:calendar-color>#FF8800FF</A:calendar-color></D:prop></D:set></C:mkcalendar>', 'Content-Type' => 'application/xml')
  ->status_is(201, 'MKCALENDAR makes a calendar');
my $newcal = $m->calendar_by_dav_name($ME, $seg);
ok $newcal, 'reachable by the name the phone chose';
is $newcal->{name}, 'From the phone', '... named from the body';
is $newcal->{color}, '#ff8800', '... coloured, the alpha dropped';
$TX->(MKCALENDAR => "$home$seg/")->status_is(405, 'again: 405');
$TX->(MKCALENDAR => "${home}12345/")->status_is(400, 'a number alone is not a name');
$PF->($home, 1);
ok((grep { $_ eq "$home$seg/" } @{ hrefs($t) }), 'the home lists it under that name');
$TX->(PROPPATCH => "$home$seg/", '<D:propertyupdate xmlns:D="DAV:" xmlns:A="http://apple.com/ns/ical/" xmlns:X="urn:x-test:"><D:set><D:prop><D:displayname>Renamed on the phone</D:displayname><A:calendar-color>#00AA00</A:calendar-color><X:whatever>1</X:whatever></D:prop></D:set></D:propertyupdate>', 'Content-Type' => 'application/xml')->status_is(207);
$x = xpc(xml($t));
ok $x->findnodes("/D:multistatus/D:response/D:propstat[D:status='HTTP/1.1 200 OK']/D:prop/D:displayname")->size, 'PROPPATCH took the name';
ok $x->findnodes("/D:multistatus/D:response/D:propstat[D:status='HTTP/1.1 403 Forbidden']/D:prop/*[local-name()='whatever']")->size, '... and refused the one it does not keep';
$newcal = $m->calendar($newcal->{id});
is $newcal->{name}, 'Renamed on the phone', 'the name changed';
is $newcal->{color}, '#00aa00', '... and the colour';
(my $ics_fresh = $ics) =~ s/UID:\Q$uid\E/UID:fresh-$uid/;
$PUT->("$home$seg/fresh-$uid.ics", $ics_fresh)->status_is(201, 'an event goes into the new calendar by its name');
# A phone moves an event between calendars as a PUT of the same UID into the
# other one followed by a DELETE of the old copy.
$PUT->("$home$seg/$uid2.ics", $series2)->status_is(201, 'PUT of a UID that lives in another calendar of mine moves the event');
is $m->event($srow->{id})->{calendar_id}, $newcal->{id}, '... the same row, now in the new calendar';
$t->get_ok($obj2 => \%H)->status_is(404, '... and gone from the old one');
$TX->(DELETE => $obj2)->status_is(404, '... whose DELETE of the old copy finds nothing, as the phone expects');
$t->get_ok("$home$seg/$uid2.ics" => \%H)->status_is(200)->content_like(qr/RRULE:FREQ=DAILY;COUNT=5/, '... and it reads back from the new one, rule and all');
$TX->(DELETE => "$home$seg/")->status_is(204, 'DELETE removes the calendar');
ok !$m->calendar($newcal->{id}), '... it is gone';

# --- a calendar shared to me, read-only ---
my $theirs = $m->create_calendar($OTHER, name => 'Theirs');
$m->create_share(owner => $OTHER, calendar_id => $theirs->{id}, shared_with_email => $ME, permission => 'read');
my $thref = $home . "$theirs->{id}/";
$PF->($home, 1);
ok((grep { $_ eq $thref } @{ hrefs($t) }), 'a calendar shared to me is in my home');
$x = xpc(xml($t));
my $tr = resp($x, $thref);
ok !$x->findnodes('D:propstat/D:prop/D:current-user-privilege-set/D:privilege/D:write', $tr)->size, '... read-only in its privileges';
like $x->findvalue('D:propstat/D:prop/D:displayname', $tr), qr/\ATheirs \(\Q$OTHER\E\)\z/, '... named with its owner';
is $x->findvalue('D:propstat/D:prop/D:owner/D:href', $tr), "/dav/principals/" . url_escape($OTHER, '^A-Za-z0-9\-._~@') . '/', '... whose principal it names';
$PUT->("${thref}x-$uid.ics", $ics)->status_is(403, 'a PUT into it is refused');
$TX->(PROPPATCH => $thref, '<D:propertyupdate xmlns:D="DAV:"><D:set><D:prop><D:displayname>x</D:displayname></D:prop></D:set></D:propertyupdate>', 'Content-Type' => 'application/xml')->status_is(403, '... so is renaming it');
$TX->(DELETE => $thref)->status_is(403, '... and deleting it');
$PF->($thref, 1)->status_is(207, '... but reading it is fine');

# --- bad input ---
$PUT->("${calhref}junk.ics", 'this is not a calendar')->status_is(403)->content_like(qr/valid-calendar-data/, 'not iCalendar: 403 with the precondition');
my $two = join "\r\n", 'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//T//EN', 'BEGIN:VEVENT', 'UID:a1', 'DTSTART:20261201T100000Z', 'SUMMARY:A', 'END:VEVENT', 'BEGIN:VEVENT', 'UID:b2', 'DTSTART:20261201T110000Z', 'SUMMARY:B', 'END:VEVENT', 'END:VCALENDAR', '';
$PUT->("${calhref}two.ics", $two)->status_is(403)->content_like(qr/valid-calendar-object-resource/, 'two events in one object: refused');
$TX->(REPORT => $calhref, '<nonsense')->status_is(400, 'broken XML: 400');
$TX->(REPORT => $calhref, '<D:unknown-report xmlns:D="DAV:"/>')->status_is(403)->content_like(qr/supported-report/, 'a report this server lacks: 403, named');
$TX->(REPORT => $calhref, '')->status_is(400, 'a REPORT without a body: 400');
$PF->('/dav/', 0, '<?xml version="1.0"?><!DOCTYPE d [<!ENTITY xxe SYSTEM "file:///etc/hostname">]><D:propfind xmlns:D="DAV:"><D:prop><D:displayname>&xxe;</D:displayname></D:prop></D:propfind>');
isnt $t->tx->res->code, 500, 'an external entity neither crashes the server nor is fetched';
$TX->(MOVE => $calhref, '', Destination => "${home}elsewhere/")->status_is(405, 'a method this server lacks: 405')->header_like(Allow => qr/PROPFIND/, '... naming what it has');
$PUT->($calhref, $ics)->status_is(409, 'PUT onto the calendar itself: 409');

# --- a revoked app password is a closed door ---
ok $m->revoke_app_password($ME, $dev->{id}), 'revoked';
$PF->('/dav/', 0)->status_is(401, 'a revoked app password no longer signs in');

$m->db->query('DELETE FROM calendar.calendars WHERE lower(owner_email) IN (?, ?)', lc $ME, lc $OTHER);
$m->db->query('DELETE FROM calendar.app_passwords WHERE lower(user_email) = ?', lc $ME);
done_testing;
