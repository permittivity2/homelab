use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';

# The search page rendered with every value supplied, so the markup the
# calendar section (#90) hangs on is checked without a database: the third
# box, the section's heading and hits, the link for the related step, the
# messages when the calendar is off, failed or not asked. app.t renders the
# real thing against a live database and skips everywhere else; this one runs
# anywhere the shared libraries are on @INC.
BEGIN {
    plan skip_all => 'needs Homelab::Common and Homelab::WebTheme on @INC (prove -I ../common/lib -I ../webtheme/lib)'
        unless eval { require Homelab::Common::Config; require Homelab::WebTheme; 1 };
}

use Test::Mojo;
use Mojo::File qw(tempfile);
use Homelab::Search::Mime ();

# A configuration that reaches nothing: no route below touches the database.
my $cfg = tempfile(SUFFIX => '.yml');
$cfg->spew(<<'YML');
database:
  host: 127.0.0.1
  port: 1
  name: homelab
  user: nobody
  password: nothing
public_base_url: http://search.test
homelab_api:
  base_url: http://api.test:3000
session:
  secret: not-a-secret-just-a-test
sso:
  base_url: http://sso.test
  client_id: search
  client_secret: nothing
  redirect_uri: http://search.test/oauth/callback
YML
$ENV{HOMELAB_SEARCH_CONFIG} = "$cfg";
$ENV{HOMELAB_SEARCH_HOME}   = '.';

require Homelab::Search::App;
my $t = Test::Mojo->new('Homelab::Search::App');

my %f = (q => 'haircut', person => '', from => '', to => '', mailbox => '', mime => '', tag => '', shared => 'include',
         source => 'both', calendar => 1, related => 0, type_in => [], type_ex => [], in_trash => 0, has_attachments => 0,
         limit => 50, offset => 0);
my %hit = (id => 7, title => 'Haircut at <b>Par</b> Exsalonce', location => '11849 College Blvd, Overland Park, KS 66210',
           calendar => 'My calendar', start => '2026-11-16T13:30:00', end => '2026-11-16T14:30:00', all_day => 0, is_recurring => 1,
           when => 'Mon, Nov 16 · 1:30 – 2:30 PM', url => 'https://calendar.test/?date=2026-11-16&event=7');
my %base = (
    email => 'me@example.test', account => { account_id => 1, email => 'me@example.test' },
    f => \%f, mail => [], drive => [], ai => undef, ai_state => { available => 0, consented => 0, notice => 'notice' },
    mailboxes => [], counts => {}, mime_cats => Homelab::Search::Mime::categories(), mime_groups => [],
    drive_meta => {}, drive_faces => {}, searched => 1, filters_on => 0,
);
my $r = $t->app->routes;
$r->get('/t/events'   => sub ($c) { $c->render(template => 'index', %base, cal => { ok => 1, events => [ \%hit ], related => [], ai => { available => 1, enabled => 1 } }) });
$r->get('/t/ai-off'   => sub ($c) { $c->render(template => 'index', %base, cal => { ok => 1, events => [], related => [], ai => { available => 1, enabled => 0 } }) });
$r->get('/t/no-ai'    => sub ($c) { $c->render(template => 'index', %base, cal => { ok => 1, events => [], related => [], ai => { available => 0, enabled => 0 } }) });
$r->get('/t/failed'   => sub ($c) { $c->render(template => 'index', %base, cal => { ok => 0, error => 'unavailable', status => 502 }) });
$r->get('/t/mail-only'=> sub ($c) { $c->render(template => 'index', %base, cal => undef, f => { %f, source => 'mail', calendar => 0 }) });
$r->get('/t/cal-only' => sub ($c) { $c->render(template => 'index', %base, cal => { ok => 1, events => [ \%hit ], related => [], ai => {} }, f => { %f, source => 'calendar', calendar => 1 }) });
$r->get('/t/new'      => sub ($c) { $c->render(template => 'index', %base, account => undef, cal => { ok => 1, events => [ \%hit ], related => [], ai => {} }) });
$r->get('/t/idle'     => sub ($c) { $c->render(template => 'index', %base, cal => undef, searched => 0, f => { %f, q => '' }) });

$t->get_ok('/t/events')->status_is(200)
  ->element_exists('#q[placeholder="Search your email, files and calendar"]', 'the box asks for all three')
  ->element_exists('#srcCal[checked]', 'the Calendar box is there and ticked')
  ->element_exists('#srcMail[checked]', '... beside Email')
  ->element_exists('#srcDrive[checked]', '... and Files')
  ->text_like('h2.sec', qr/Calendar — 1 result/, 'the Calendar section comes first, with its count')
  ->element_exists('#calRes .hit .subj a[href="https://calendar.test/?date=2026-11-16&event=7"]', 'the title links into the calendar')
  ->content_like(qr/Haircut at &lt;b&gt;Par&lt;\/b&gt; Exsalonce/, '... escaped, never markup')
  ->content_like(qr/Mon, Nov 16 · 1:30 – 2:30 PM · My calendar · repeats/, 'when, the calendar and that it repeats')
  ->content_like(qr/11849 College Blvd, Overland Park, KS 66210/, 'the place')
  ->element_exists('#calRelated[data-q="haircut"] .calwait', 'a place for the related events, carrying the words')
  ->content_like(qr{fetch\('/calendar/related\?q='}, '... and the script that asks for them')
  ->content_like(qr/Email — 0 results/, 'Email follows')
  ->content_like(qr/Files — 0 results/, '... then Files');

$t->get_ok('/t/ai-off')->status_is(200)
  ->text_like('h2.sec', qr/Calendar — 0 results/)
  ->content_like(qr/No matching events\./, 'no hits says so')
  ->element_exists('#calRes a[href="https://calendar.mailmasker.org/settings"]', 'AI available but off: the link to the calendar\'s own settings')
  ->element_exists_not('#calRelated', '... and no related step')
  ->content_unlike(qr{/calendar/related}, '... nor its script');

$t->get_ok('/t/no-ai')->status_is(200)
  ->content_unlike(qr/calendar&rsquo;s settings/, 'no AI on the calendar at all: nothing is advertised')
  ->element_exists_not('#calRelated');

$t->get_ok('/t/failed')->status_is(200)
  ->text_like('h2.sec', qr/\ACalendar\z/, 'a failed calendar: the heading without a count')
  ->content_like(qr/The calendar could not be searched just now\./)
  ->content_like(qr/Email — 0 results/, '... and the rest of the page is unharmed');

$t->get_ok('/t/mail-only')->status_is(200)
  ->element_exists('#srcMail[checked]')
  ->element_exists_not('#srcCal[checked]', 'mail only: the Calendar box is unticked')
  ->element_exists_not('#calRes', '... no Calendar section')
  ->content_unlike(qr/<h2 class="sec">Calendar/, '... nor its heading')
  ->content_like(qr/Email — 0 results/)
  ->content_unlike(qr/Files — /, '... and no Files either');

$t->get_ok('/t/cal-only')->status_is(200)
  ->text_like('h2.sec', qr/Calendar — 1 result/)
  ->content_unlike(qr/Email — /, 'calendar only: no Email')
  ->content_unlike(qr/Files — /, '... and no Files')
  ->element_exists_not('#srcMail[checked]')
  ->element_exists('#srcCal[checked]');

$t->get_ok('/t/new')->status_is(200)
  ->text_like('h2.sec', qr/Calendar — 1 result/, 'nothing indexed yet: the calendar still answers')
  ->content_like(qr/Nothing of yours has been indexed yet/, '... and the page still says the index is empty');

$t->get_ok('/t/idle')->status_is(200)
  ->content_like(qr/Type something above to search your mail, files and calendar together\./, 'the empty page names all three')
  ->element_exists_not('#calRes', '... with no section yet')
  ->content_unlike(qr/<h2 class="sec">Calendar/, '... nor its heading');

done_testing;
