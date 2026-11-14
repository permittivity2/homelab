use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(tempdir);
use Mojo::JSON qw(decode_json encode_json);
use Mojolicious::Lite -signatures;

# The pass-through without a database for the usage rows (recording fails
# loudly in the log and the request still goes through) and with a fake
# upstream standing in for Anthropic: what reaches it, and that its answer
# comes back byte for byte.

use lib 'lib';

# --- a fake Anthropic, in its OWN process: the app under test calls its
# upstream with a blocking request, which would deadlock an in-process fake
# sharing the same event loop. It records what it saw in a file.
use Mojo::Server::Daemon;
use IO::Socket::INET;
my $dir  = tempdir;
my $seen = $dir->child('seen.jsonl');
my $port = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp')->sockport;
post '/v1/messages' => sub ($c) {
    open my $fh, '>>', $seen or die $!;
    print $fh encode_json({ headers => $c->req->headers->to_hash, body => $c->req->body }), "\n";
    close $fh;
    my $req = $c->req->json // {};
    return $c->render(json => { type => 'error', error => { type => 'invalid_request_error', message => 'bad model' } }, status => 400)
        if ($req->{model} // '') eq 'claude-bogus';
    $c->res->headers->content_type('application/json');
    $c->render(data => '{"id":"msg_1","model":"claude-haiku-5-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":7,"output_tokens":2,"cache_read_input_tokens":5,"cache_creation_input_tokens":0},"zz_order":1,"aa_order":2}');
};
my $pid = fork // die "fork: $!";
if (!$pid) {
    Mojo::Server::Daemon->new(app => app, listen => ["http://127.0.0.1:$port"], silent => 1)->run;
    exit 0;
}
END { kill 'TERM', $pid if $pid }
for (1 .. 50) { last if IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1); select undef, undef, undef, 0.1 }
my $upstream = "http://127.0.0.1:$port/v1/messages";
sub seen_requests { return [ map { decode_json($_) } grep { length } split /\n/, (-e $seen ? $seen->slurp : '') ] }

sub config ($extra = '') {
    my $cfg = $dir->child('config-' . int(rand 1e9) . '.yml');
    $cfg->spew(<<"YAML" . $extra);
homelab_api:
  base_url: "http://127.0.0.1:9"
database:
  host: "127.0.0.1"
  port: 65432
  name: "nonexistent"
  user: "nobody"
  password: "nobody"
ai:
  api_key: "sk-test-key"
  upstream_url: "$upstream"
server:
  listen: "http://127.0.0.1:0"
clients:
  - name: search
    token: "search-token-0123456789abcdef0123456789abcdef"
YAML
    return $cfg->to_string;
}

{
    local $ENV{HOMELAB_AI_CONFIG} = config();
    my $t = eval { Test::Mojo->new('Homelab::AI::App') };
    plan skip_all => "could not start app: $@" unless $t;
}
{
    local $ENV{HOMELAB_AI_CONFIG} = config("  - name: short\n    token: tooshort\n");
    ok !eval { Test::Mojo->new('Homelab::AI::App') }, 'a short client token refuses to start';
    like $@, qr/too short/, '... and says so';
}

$ENV{HOMELAB_AI_CONFIG} = config();
my $t = Test::Mojo->new('Homelab::AI::App');
my $TOK = 'search-token-0123456789abcdef0123456789abcdef';
my $H = { Authorization => "Bearer $TOK", 'X-Homelab-Consent' => 'search:abc123', 'Content-Type' => 'application/json' };
my $payload = '{"model":"claude-haiku-5-5","max_tokens":50,"zeta":1,"alpha":2,"messages":[{"role":"user","content":"hi"}]}';

# --- who may call ---
$t->post_ok('/internal/v1/ai/messages' => { 'Content-Type' => 'application/json' } => $payload)->status_is(401)->json_is('/error', 'unknown client', 'no token: 401');
$t->post_ok('/internal/v1/ai/messages' => { Authorization => 'Bearer nope', 'Content-Type' => 'application/json' } => $payload)->status_is(401, 'wrong token: 401');
$t->get_ok('/internal/v1/ai/ping' => { Authorization => "Bearer $TOK" })->status_is(200)->json_is('/client', 'search', 'ping names the client');
is scalar(@{ seen_requests() }), 0, 'nothing reached the upstream yet';

# --- the request must say which consent it is made under ---
$t->post_ok('/internal/v1/ai/messages' => { Authorization => "Bearer $TOK", 'Content-Type' => 'application/json' } => $payload)
  ->status_is(400)->json_like('/error', qr/X-Homelab-Consent/, 'no consent header: 400');
$t->post_ok('/internal/v1/ai/messages' => $H => 'not json')->status_is(400)->json_like('/error', qr/JSON object/, 'a non-JSON body: 400');
$t->post_ok('/internal/v1/ai/messages' => $H => '{"model":"x"}')->status_is(400, 'no messages: 400');
is scalar(@{ seen_requests() }), 0, 'still nothing upstream';

# --- the pass-through. No database here: the budget read and the usage row
# both fail, are logged, and the answer still goes through (a DB blip must
# never stop an answer the caller could degrade without).
{
    $t->post_ok('/internal/v1/ai/messages' => $H => $payload)->status_is(200);
    is $t->tx->res->body, '{"id":"msg_1","model":"claude-haiku-5-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":7,"output_tokens":2,"cache_read_input_tokens":5,"cache_creation_input_tokens":0},"zz_order":1,"aa_order":2}',
        'the upstream answer comes back byte for byte (key order kept)';
    my @seen = @{ seen_requests() };
    is scalar(@seen), 1, 'one request reached the upstream';
    is $seen[0]{body}, $payload, '... with the body byte for byte (zeta before alpha, as sent)';
    is $seen[0]{headers}{'X-Api-Key'} // $seen[0]{headers}{'x-api-key'}, 'sk-test-key', '... with the key added';
    is $seen[0]{headers}{'Anthropic-Version'} // $seen[0]{headers}{'anthropic-version'}, '2026-10-21', '... and the pinned API version';
    ok !exists $seen[0]{headers}{Authorization}, '... and never the client token';
    $t->post_ok('/internal/v1/ai/messages' => $H => '{"model":"claude-bogus","messages":[]}')->status_is(400, 'an upstream 400 is passed through as 400');
}

done_testing;
