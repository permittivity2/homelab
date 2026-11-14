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
    my $answer = $req->{messages}[0]{content} =~ /GARBAGE/ ? 'I cannot help with that.'
        : 'Here you go: {"title":"Dentist","all_day":false,"start":"2026-11-20T15:30:00","end":"2026-11-20T16:30:00","location":"Main St office","description":"Bring the insurance card.","confidence":"high","note":null,"evil":"ignored"}';
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
    location => 'Main St office', description => 'Bring the insurance card.', confidence => 'high', note => undef },
    'only the editor\'s fields, in its shapes (the stray key dropped, the JSON found inside prose)';
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

done_testing;
