use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File qw(tempdir);
use Mojolicious::Lite -signatures;
use Mojo::Server::Daemon;
use IO::Socket::INET;
use DateTime;

# The proposal through the fleet's AI service. A fake service runs in its own
# process (the client call is blocking) and records what it received.

use lib 'lib';
use_ok 'Homelab::Calendar::AI';

my $dir  = tempdir;
my $seen = $dir->child('seen.jsonl');
my $port = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp')->sockport;
post '/internal/v1/ai/messages' => sub ($c) {
    open my $fh, '>>', $seen or die $!; print $fh encode_json({ headers => $c->req->headers->to_hash, body => $c->req->body }), "\n"; close $fh;
    my $tok = $c->req->headers->authorization // '';
    return $c->render(json => { error => 'unknown client' }, status => 401) unless $tok eq 'Bearer cal-token-0123456789abcdef0123456789';
    my $req = $c->req->json;
    return $c->render(json => { error => 'daily request budget reached for calendar' }, status => 429) if $req->{messages}[0]{content} =~ /BUDGET/;
    # A research call (#78) carries the web-search tool: answer like the real
    # thing does, with search blocks first and the JSON fenced at the end.
    if (ref $req->{tools} eq 'ARRAY' && grep { ($_->{type} // '') =~ /^web_search/ } @{ $req->{tools} }) {
        return $c->render(json => { error => 'daily web-search budget reached for calendar' }, status => 429) if $req->{messages}[0]{content} =~ /SEARCHCAP/;
        my $nothing = $req->{messages}[0]{content} =~ /NOTHING/;
        $c->render(json => { id => 'msg_2', model => 'claude-sonnet-5-5',
            content => [ { type => 'server_tool_use', id => 'srvtoolu_1', name => 'web_search', input => { query => 'McCool Field Cleveland MS' } },
                         { type => 'web_search_tool_result', tool_use_id => 'srvtoolu_1', content => [] },
                         { type => 'text', text => 'I looked it up.' },
                         { type => 'text', text => $nothing ? "Nothing relevant.\n```json\n{\"summary\":\"No page names this game.\",\"facts\":[]}\n```"
                             : "Here is what I found.\n```json\n{\"summary\":\"McCool Field is the Delta State baseball park.\",\"facts\":[{\"label\":\"Address\",\"value\":\"1003 W Sunflower Rd, Cleveland, MS 38733\",\"field\":\"location\",\"source\":\"https://gostatesmen.example/facilities\",\"confidence\":\"high\"},{\"label\":\"Opponent\",\"value\":\"Delta State vs Valdosta State\",\"field\":\"description\",\"source\":\"javascript:alert(1)\",\"confidence\":\"medium\"},{\"label\":\"Bad\",\"value\":\"\",\"field\":\"title\"},{\"label\":\"Name\",\"value\":\"Statesmen home opener\",\"field\":\"nonsense\",\"source\":null,\"confidence\":\"silly\"}]}\n```" } ],
            usage => { input_tokens => 900, output_tokens => 200, server_tool_use => { web_search_requests => 2 } } });
        return;
    }
    # Search by meaning (#87) and the zone of a place (#89): told apart by the system prompt.
    my $sys = $req->{system}[0]{text} // '';
    if ($sys =~ /find events in their own calendar/) {
        my $ans = $req->{messages}[0]{content} =~ /GARBAGE/ ? 'no idea' : '{"matches":[{"id":2,"why":"a hospital visit"},{"id":99,"why":"never shown"},{"id":2,"why":"again"}]}';
        return $c->render(json => { id => 'msg_3', model => 'claude-haiku-5-5', content => [ { type => 'text', text => $ans } ], usage => { input_tokens => 300, output_tokens => 40 } });
    }
    if ($sys =~ /name the time zone of a place/) {
        my $ans = $req->{messages}[0]{content} =~ /NOWHERE/ ? '{"timezone":null,"confidence":"low","place":null}' : '{"timezone":"America/Chicago","confidence":"high","place":"Overland Park, KS"}';
        return $c->render(json => { id => 'msg_4', model => 'claude-haiku-5-5', content => [ { type => 'text', text => $ans } ], usage => { input_tokens => 80, output_tokens => 20 } });
    }
    my $answer = $req->{messages}[0]{content} =~ /GARBAGE/ ? 'I cannot help with that.'
        : $req->{messages}[0]{content} =~ /KANSAS/ ? '{"title":"Hair","all_day":false,"start":"2026-11-16T13:30:00","end":"2026-11-16T14:30:00","location":"11849 College Blvd, Overland Park, KS 66210","timezone":"America/Chicago","confidence":"high","note":null}'
        : 'Here you go: {"title":"Dentist","all_day":false,"start":"2026-11-20T15:30:00","end":"2026-11-20T16:30:00","location":"Main St office","description":"Bring the insurance card.","confidence":"high","note":null,"evil":"ignored","research":{"worth_it":true,"about":"Main St dental office","query":"Main St dental office Cleveland hours"}}';
    $c->render(json => { id => 'msg_1', model => 'claude-haiku-5-5', content => [ { type => 'text', text => $answer } ], usage => { input_tokens => 120, output_tokens => 60 } });
};
my $pid = fork // die "fork: $!";
if (!$pid) { Mojo::Server::Daemon->new(app => app, listen => ["http://127.0.0.1:$port"], silent => 1)->run; exit 0 }
END { kill 'TERM', $pid if $pid }
for (1 .. 50) { last if IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1); select undef, undef, undef, 0.1 }

my $now = DateTime->new(year => 2026, month => 11, day => 14, hour => 10, time_zone => 'America/Chicago');
my %mail = (subject => 'Re: Dentist', from => 'office@dentist.example', date_header => 'Fri, 13 Nov 2026 09:00:00 -0600',
            text => 'Your appointment is on 11/20 at 3:30 PM.', zone => 'America/Chicago', now => $now, consent_sha => ('a' x 64), account_key => 'me@example.test');

ok !Homelab::Calendar::AI->new->configured, 'unconfigured without a service';
my $r = Homelab::Calendar::AI->new->propose(%mail);
is $r->{ok}, 0, 'an unconfigured client refuses'; like $r->{error}, qr/not configured/, '... and says so';

my $ai = Homelab::Calendar::AI->new(service_url => "http://127.0.0.1:$port/", service_token => 'cal-token-0123456789abcdef0123456789');
ok $ai->configured, 'configured with a service URL and token';
$r = $ai->propose(%mail);
ok $r->{ok}, 'a proposal comes back' or diag explain $r;
is_deeply $r->{proposal}, { title => 'Dentist', all_day => 0, start => '2026-11-20T15:30:00', end => '2026-11-20T16:30:00',
    location => 'Main St office', description => 'Bring the insurance card.', confidence => 'high', note => undef, timezone => undef,
    research => { worth_it => 1, about => 'Main St dental office', query => 'Main St dental office Cleveland hours' } },
    'only the editor\'s fields, in its shapes (the stray key dropped, the JSON found inside prose), plus the research hint';
is $r->{model}, 'claude-haiku-5-5', 'the model that answered';

my @seen = map { decode_json($_) } split /\n/, $seen->slurp;
is scalar(@seen), 1, 'one request reached the service';
my $h = $seen[0]{headers};
is $h->{Authorization} // $h->{authorization}, 'Bearer cal-token-0123456789abcdef0123456789', '... with this app\'s token';
is $h->{'X-Homelab-Consent'} // $h->{'x-homelab-consent'}, 'calendar:' . ('a' x 16), '... naming the consent';
like $h->{'X-Homelab-Account'} // $h->{'x-homelab-account'}, qr/\A[0-9a-f]{64}\z/, '... and an opaque account hash';
my $body = decode_json($seen[0]{body});
is $body->{model}, 'claude-haiku-5-5', 'the configured model';
is $body->{system}[0]{cache_control}{type}, 'ephemeral', 'the system prompt is the cached prefix';
like $body->{messages}[0]{content}, qr/Time zone: America\/Chicago.*Reference date and time: Saturday 2026-11-14 10:00.*Subject: Re: Dentist.*3:30 PM/s,
    'the user turn carries the zone, the reference date and the email';
like $seen[0]{body}, qr/\A\{"max_tokens":1024,"messages":/, 'canonical key order (the service forwards bytes as they are)';

$r = Homelab::Calendar::AI->new(service_url => "http://127.0.0.1:$port", service_token => 'wrong-token-0123456789abcdef01234567')->propose(%mail);
is $r->{ok}, 0, 'a refused token is an error'; like $r->{error}, qr/error/, '... a plain one';
$r = $ai->propose(%mail, text => 'BUDGET');
like $r->{error}, qr/budget/, 'the service\'s 429 is explained as the budget';
$r = $ai->propose(%mail, text => 'GARBAGE');
is $r->{ok}, 0, 'an answer with no JSON is not usable'; like $r->{error}, qr/not usable/, '... and says so';
$r = Homelab::Calendar::AI->new(service_url => 'http://127.0.0.1:9', service_token => 'cal-token-0123456789abcdef0123456789')->propose(%mail);
like $r->{error}, qr/could not be reached/, 'a dead service is a plain error, not a 500';

# --- "Find out more" (#78): the research call ---
my %rq = (%mail, about => 'McCool Field, Cleveland MS', query => 'McCool Field Cleveland MS schedule', text => 'The game is at McCool field at 1pm in Cleveland, MS.');
$r = $ai->research(%rq);
ok $r->{ok}, 'research comes back' or diag explain $r;
is $r->{summary}, 'McCool Field is the Delta State baseball park.', 'the summary';
is $r->{searches}, 2, 'the searches the service reported';
is $r->{model}, 'claude-sonnet-5-5', 'the research model answered';
is_deeply $r->{facts}, [
    { label => 'Address', value => '1003 W Sunflower Rd, Cleveland, MS 38733', field => 'location', source => 'https://gostatesmen.example/facilities', confidence => 'high' },
    { label => 'Opponent', value => 'Delta State vs Valdosta State', field => 'description', source => undef, confidence => 'medium' },
    { label => 'Name', value => 'Statesmen home opener', field => 'description', source => undef, confidence => 'low' },
], 'facts sanitised: a javascript: source dropped, an empty value skipped, an unknown field becomes description, an odd confidence becomes low';
my $last = (map { decode_json($_) } split /\n/, $seen->slurp)[-1];
my $rb = decode_json($last->{body});
is $rb->{model}, 'claude-sonnet-5-5', 'the research request names the research model';
is_deeply $rb->{tools}, [ { type => 'web_search_20250305', name => 'web_search', max_uses => 5 } ], '... with the web-search tool, capped';
is $last->{headers}{'X-Homelab-Consent'} // $last->{headers}{'x-homelab-consent'}, 'calendar:research:' . ('a' x 16), '... naming the research consent';
like $rb->{messages}[0]{content}, qr/Look into: McCool Field, Cleveland MS.*Suggested search: McCool Field Cleveland MS schedule/s, '... and carrying the hint';
$r = $ai->research(%rq, text => 'NOTHING here');
ok $r->{ok} && !@{ $r->{facts} }, 'nothing found: ok with no facts' or diag explain $r;
like $r->{summary}, qr/No page/, '... and the summary says so';
$r = $ai->research(%rq, text => 'SEARCHCAP');
like $r->{error}, qr/web-search budget/, 'the search budget 429 is explained as such';

# --- 0.4.0: the zone read off the email's address, search by meaning, the zone of a place ---
$r = $ai->propose(%mail, text => 'KANSAS: your appointment is Monday 1:30 PM at 11849 College Blvd, Overland Park, KS 66210');
ok $r->{ok}, 'a proposal with a place' or diag explain $r;
is $r->{proposal}{timezone}, 'America/Chicago', '... carries the zone the AI read off the address';
is $r->{proposal}{location}, '11849 College Blvd, Overland Park, KS 66210', '... and the address';

my @cands = ({ id => 1, when => '2026-11-20 15:30', title => 'Dentist' }, { id => 2, when => '2026-12-01 08:30', title => 'Infusion', location => q{St Luke's Hospital} });
$r = $ai->relate(query => 'doctor', candidates => \@cands, zone => 'America/Chicago', now => $now, consent_sha => ('a' x 64), account_key => 'me@example.test');
ok $r->{ok}, 'related events come back' or diag explain $r;
is_deeply $r->{matches}, [ { id => 2, why => 'a hospital visit' } ], '... only ids it was shown, once each';
my $rel = (map { decode_json($_) } split /\n/, $seen->slurp)[-1];
is $rel->{headers}{'X-Homelab-Consent'} // $rel->{headers}{'x-homelab-consent'}, 'calendar:search:' . ('a' x 16), '... under the search consent tag';
like decode_json($rel->{body})->{messages}[0]{content}, qr/Search: doctor.*2 \| 2026-12-01 08:30 \| Infusion \| St Luke's Hospital/s, '... with the events as lines';
is_deeply $ai->relate(query => 'x', candidates => [], zone => 'America/Chicago', now => $now), { ok => 1, matches => [] }, 'no candidates: no call';
$r = $ai->relate(query => 'GARBAGE', candidates => \@cands, zone => 'America/Chicago', now => $now);
is $r->{ok}, 0, 'an unusable answer is an error';

$r = $ai->zone_for_place(place => '11849 College Blvd, Overland Park, KS 66210', zone => 'America/Denver', consent_sha => ('a' x 64), account_key => 'me@example.test');
ok $r->{ok}, 'the zone of a place' or diag explain $r;
is $r->{timezone}, 'America/Chicago', '... is Central for Overland Park';
is $r->{confidence}, 'high', '... with its confidence';
is $r->{place}, 'Overland Park, KS', '... and the place as read';
$r = $ai->zone_for_place(place => 'NOWHERE room 4', zone => 'America/Denver');
ok $r->{ok} && !defined $r->{timezone}, 'a non-place: ok with no zone' or diag explain $r;

done_testing;
