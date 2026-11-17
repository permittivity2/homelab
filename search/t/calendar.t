use strict;
use warnings;
use utf8;
use Test::More;
use lib 'lib';

# The calendar as a source of the site search (post-cutover #90): the source
# table, the day-and-time text, and the client against a fake gateway. No
# database: everything here is one module and one HTTP call.

use Mojolicious::Lite -signatures;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
use Mojo::IOLoop::Server;
use IO::Socket::INET;
use Homelab::Search::Calendar;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# --- when: the day and time as a person reads them ---------------------------
my $Y = 2026;
my $w = \&Homelab::Search::Calendar::when_text;
is $w->('2026-11-16T13:30:00', '2026-11-16T14:30:00', 0, $Y), 'Mon, Nov 16 · 1:30 – 2:30 PM', 'same day, same half of the day';
is $w->('2026-11-16T11:30:00', '2026-11-16T13:00:00', 0, $Y), 'Mon, Nov 16 · 11:30 AM – 1:00 PM', 'across noon says both halves';
is $w->('2026-11-16T22:00:00', '2026-11-17T01:00:00', 0, $Y), 'Mon, Nov 16, 10:00 PM – Tue, Nov 17, 1:00 AM', 'over midnight names both days';
is $w->('2026-11-16T13:30:00', '', 0, $Y),                    'Mon, Nov 16 · 1:30 PM', 'no end: the start alone';
is $w->('2026-12-01', '2026-12-02', 1, $Y),                   'Tue, Dec 1 (all day)', 'one all-day event (its end is the day after)';
is $w->('2026-12-01', '2026-12-04', 1, $Y),                   'Tue, Dec 1 – Thu, Dec 3 (all day)', 'three days: the last day shown is the last day';
is $w->('2026-12-01', '', 1, $Y),                             'Tue, Dec 1 (all day)', 'all day without an end';
is $w->('2027-01-02T09:00:00', '2027-01-02T09:30:00', 0, $Y), 'Sat, Jan 2, 2027 · 9:00 – 9:30 AM', 'another year says which';
is $w->('2026-11-16T00:05:00', '2026-11-16T12:00:00', 0, $Y), 'Mon, Nov 16 · 12:05 AM – 12:00 PM', 'midnight and noon are 12';
is $w->('garbage', undef, 0, $Y), '', 'unreadable start: empty, never a die';
is $w->(undef, undef, 0, $Y), '', 'no start: empty';

# --- which sources ------------------------------------------------------------
my @cases = (
    [ [],                           undef,      undef, 'both',     1, 'nothing ticked: everything' ],
    [ ['mail'],                     undef,      undef, 'mail',     0, 'mail alone stays mail alone' ],
    [ ['drive'],                    undef,      undef, 'drive',    0, 'files alone' ],
    [ ['mail', 'drive'],            undef,      undef, 'both',     0, 'mail and files, no calendar' ],
    [ ['calendar'],                 undef,      undef, 'calendar', 1, 'the calendar alone' ],
    [ ['mail', 'calendar'],         undef,      undef, 'mail',     1, 'mail and the calendar' ],
    [ ['drive', 'calendar'],        undef,      undef, 'drive',    1, 'files and the calendar' ],
    [ ['mail', 'drive', 'calendar'], undef,     undef, 'both',     1, 'all three ticked' ],
    [ ['bogus'],                    'mail',     undef, 'mail',     0, 'a junk tick is ignored and the wire word counts' ],
    [ [],                           'both',     undef, 'both',     1, 'wire: both means mail, files and the calendar' ],
    [ [],                           'both',     '0',   'both',     0, 'wire: calendar=0 leaves it out' ],
    [ [],                           'mail',     undef, 'mail',     0, 'wire: mail stays narrowed' ],
    [ [],                           'mail',     '1',   'mail',     1, 'wire: calendar=1 adds it to a narrowed search' ],
    [ [],                           'drive',    '1',   'drive',    1, '... and to files' ],
    [ [],                           'calendar', '0',   'calendar', 1, 'wire: events only cannot switch the calendar off' ],
    [ [],                           'all',      undef, 'both',     1, 'wire: all is both with the calendar' ],
    [ [],                           'nonsense', undef, 'both',     1, 'wire: a word that is not one is the default' ],
    [ [],                           'both',     'yes', 'both',     1, 'wire: calendar must be 0 or 1 to count' ],
);
for my $c (@cases) {
    my ($ticks, $src, $cal, $es, $ec, $name) = @$c;
    is_deeply [ Homelab::Search::Calendar::sources($ticks, $src, $cal) ], [ $es, $ec ], $name;
}

# --- the client, against a fake gateway ------------------------------------------
my $port = Mojo::IOLoop::Server->generate_port;
get '/api/v1/calendar/search' => sub ($c) {
    my $auth = $c->req->headers->authorization // '';
    return $c->render(json => { error => 'not signed in' }, status => 401) unless $auth eq 'Bearer good-token';
    my $q = $c->param('q') // '';
    return $c->render(text => 'boom', status => 500) if $q eq 'BOOM';
    return $c->render(text => 'this is not json')     if $q eq 'TEXT';
    if ($q eq 'SLOW') {
        $c->render_later;
        Mojo::IOLoop->timer(3 => sub { $c->render(json => { q => $q, events => [] }) });
        return;
    }
    my %body = (
        q      => $q,
        events => [ {
            id => 7, title => 'Haircut at Par Exsalonce', location => '11849 College Blvd, Overland Park, KS 66210',
            all_day => \0, start => '2026-11-16T13:30:00', end => '2026-11-16T14:30:00', is_recurring => \0,
            calendar => { id => 1, name => 'My calendar' }, url => 'http://cal.example/?date=2026-11-16&event=7',
        } ],
        ai => { available => \1, enabled => ($q =~ /doctor/ ? \1 : \0) },
    );
    if ($c->param('related')) {
        if ($q =~ /doctor/) {
            $body{related} = [ { id => 9, title => 'Infusion', start => '2026-12-01T08:30:00', end => '2026-12-01T09:30:00',
                                 all_day => \0, why => 'a hospital visit', url => 'javascript:alert(1)',
                                 calendar => { name => 'My calendar' } }, 'not a hash' ];
        }
        else { $body{related} = []; $body{related_note} = 'Turn on AI in Settings to also find events by meaning.' }
    }
    return $c->render(json => \%body);
};
app->log->level('warn');
my $pid = fork // die "fork: $!";
if (!$pid) { Mojo::Server::Daemon->new(app => app, listen => ["http://127.0.0.1:$port"], silent => 1)->run; exit 0 }
END { kill 'TERM', $pid if $pid }
for (1 .. 50) { last if IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1); select undef, undef, undef, 0.1 }

ok !Homelab::Search::Calendar->new->ready, 'no gateway address: not ready';
my $cal = Homelab::Search::Calendar->new(api_base => "http://127.0.0.1:$port", literal_timeout => 2, related_timeout => 2);
ok $cal->ready, 'ready with one';

my $r = $cal->search('good-token', '  haircut ');
ok $r->{ok}, 'the literal search answers' or diag explain $r;
is scalar @{ $r->{events} }, 1, 'one event';
my $e = $r->{events}[0];
is $e->{title}, 'Haircut at Par Exsalonce', '... with its title';
is $e->{location}, '11849 College Blvd, Overland Park, KS 66210', '... its place';
is $e->{calendar}, 'My calendar', '... its calendar, by name';
is $e->{url}, 'http://cal.example/?date=2026-11-16&event=7', '... and the link into the calendar';
like $e->{when}, qr/\AMon, Nov 16(?:, 2026)? · 1:30 – 2:30 PM\z/, '... and when, as a person reads it';
is $e->{all_day}, 0, 'booleans are 0/1, not JSON objects';
is $e->{is_recurring}, 0, '... both of them';
ok !exists $e->{why}, 'a literal hit carries no reason';
is_deeply $r->{related}, [], 'no related list without asking';
is $r->{ai}{available}, 1, 'the calendar has AI';
is $r->{ai}{enabled}, 0, '... but this account has it off';

$r = $cal->search('good-token', 'doctor', related => 1);
ok $r->{ok}, 'with related=1' or diag explain $r;
is scalar @{ $r->{related} }, 1, 'the related list comes back (and the thing that was not an event is dropped)';
is $r->{related}[0]{why}, 'a hospital visit', '... with the reason';
is $r->{related}[0]{url}, '', '... and a link that is not a web address is dropped';
is $r->{ai}{enabled}, 1, '... this account has AI on';

$r = $cal->search('good-token', 'haircut', related => 1);
is $r->{related_note}, 'Turn on AI in Settings to also find events by meaning.', 'AI off: the calendar\'s note rides along';
is_deeply $r->{related}, [], '... and the list is empty';

$r = $cal->search('bad-token', 'haircut');
is_deeply [ @$r{qw(ok error status)} ], [ 0, 'denied', 401 ], 'a token the calendar refuses: denied';
$r = $cal->search('good-token', 'BOOM');
is_deeply [ @$r{qw(ok error status)} ], [ 0, 'unavailable', 500 ], 'a 500: unavailable';
$r = $cal->search('good-token', 'TEXT');
is_deeply [ @$r{qw(ok error)} ], [ 0, 'error' ], 'an answer that is not a result: error';
$r = $cal->search('good-token', 'x');
ok $r->{ok} && $r->{skipped}, 'one character: not asked, and not an error';
is_deeply $r->{events}, [], '... empty';
$r = $cal->search('', 'haircut');
is $r->{error}, 'unavailable', 'no token: nothing to ask with';

my $dead = Homelab::Search::Calendar->new(api_base => 'http://127.0.0.1:1', literal_timeout => 2);
$r = $dead->search('good-token', 'haircut');
is_deeply [ @$r{qw(ok error status)} ], [ 0, 'unavailable', 0 ], 'nothing listening: unavailable';

my $slow = Homelab::Search::Calendar->new(api_base => "http://127.0.0.1:$port", literal_timeout => 1);
my $t0 = time;
$r = $slow->search('good-token', 'SLOW');
is $r->{error}, 'unavailable', 'a slow calendar is given up on';
cmp_ok time - $t0, '<', 3, '... within its timeout, not the server\'s';

done_testing;
