package Homelab::AI::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(secure_compare);
use Time::HiRes ();
use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);

has 'pg';
has 'api_key';
has 'upstream';
has 'clients';
has 'ua';
has 'limits';

# homelab-ai: the ONE place in the fleet that talks to Anthropic (post-cutover
# #76). Internal only, no public name. An app that wants a model's answer
# sends the Messages API request it would have sent to Anthropic to
#
#     POST /internal/v1/ai/messages      Authorization: Bearer <client token>
#
# and gets Anthropic's response back, bytes and status untouched. This service
# adds the API key, pins the API version headers, enforces a per-client
# request budget, and records every call (client, model, tokens, cache reads,
# latency, status, which consent it was made under) in ai.requests -- so the
# key lives in one file, the spend is visible in one table, and a caller never
# needs its own credential or retry logic.
#
# WHY A BYTE-FOR-BYTE PASS-THROUGH: Anthropic's prompt caching is a byte-prefix
# match on the request. Re-encoding the caller's JSON here would reorder keys
# per process and silently turn every request into a cache write. The body is
# forwarded exactly as received; a decoded copy is read only for the usage row.
#
# CONSENT STAYS WITH THE APP. Each caller records its own informed consent
# (search's AI/Consent.pm pattern: the wording, hashed) and names it in the
# X-Homelab-Consent header; a request without one is refused. This service
# logs the assertion; it never sees who the person is unless the caller sends
# an opaque X-Homelab-Account (a hash is enough) for per-account totals.

use constant ANTHROPIC_URL => 'https://api.anthropic.com/v1/messages';
use constant API_VERSION   => '2026-10-21';
use constant BETA          => 'server-side-fallback-2026-07-01';

sub startup ($self) {
    my $config = load_config('HOMELAB_AI_CONFIG', '/etc/homelab/ai/config.yml');
    $self->config($config);

    my $ai = $config->{ai} // {};
    $self->api_key($ai->{api_key} // '');
    $self->upstream($ai->{upstream_url} // ANTHROPIC_URL);
    $self->limits({ requests_per_client_per_day => $ai->{requests_per_client_per_day} // 2000,
                    max_body_bytes => $ai->{max_body_bytes} // 4 * 1024 * 1024 });

    # Callers: name + token, both required. The token is what a request
    # carries; the name is what the usage table shows.
    my %clients;
    for my $c (@{ $config->{clients} // [] }) {
        next unless ref $c eq 'HASH' && length($c->{name} // '') && length($c->{token} // '');
        die "config: clients: token for '$c->{name}' is too short (32 characters at least)\n" if length $c->{token} < 32;
        $clients{ $c->{token} } = $c->{name};
    }
    $self->clients(\%clients);
    $self->log->warn('ai: no clients configured -- every request will be refused') unless %clients;
    $self->log->warn('ai: no api_key configured -- every request will fail upstream') unless length $self->api_key;

    # Generous inactivity: a non-streaming answer that thinks for a minute
    # sends nothing meanwhile (search found 40 s too short).
    $self->ua(Mojo::UserAgent->new->connect_timeout(10)->inactivity_timeout($ai->{inactivity_timeout} // 180)
                                   ->request_timeout($ai->{request_timeout} // 180));

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2521'],
        pid_file => $srv->{pid_file} // '/run/homelab-ai/hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });
    $self->max_request_size($self->limits->{max_body_bytes});
    $self->secrets([ $config->{session}{secret} // 'homelab-ai-has-no-sessions' ]);

    $self->pg(runtime_pg(%{ $config->{database} }));
    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port} && $config->{homelab_api}{base_url}) {
        register_recurring(
            api_base => $config->{homelab_api}{base_url}, feature_name => 'homelab-ai',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Internal AI service: the one Anthropic client, usage and budgets (POST /internal/v1/ai/messages)',
            log => $self->log,
        );
    }

    # Which client is calling, or a 401 already rendered.
    $self->helper(client_name => sub ($c) {
        my ($tok) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(\S+)$/;
        my $name;
        if (defined $tok) {
            for my $t (keys %{ $self->clients }) { $name = $self->clients->{$t} if secure_compare($t, $tok) }
        }
        return $name if $name;
        $c->render(json => { error => 'unknown client' }, status => 401);
        return undef;
    });

    my $r = $self->routes;
    $r->post('/internal/v1/ai/messages')->to(cb => sub ($c) { $self->_messages($c) });
    $r->get('/internal/v1/ai/usage')->to(cb => sub ($c) { $self->_usage($c) });
    $r->get('/internal/v1/ai/ping')->to(cb => sub ($c) { my $n = $c->client_name or return; $c->render(json => { ok => \1, client => $n }) });
    return;
}

# POST /internal/v1/ai/messages -- the pass-through.
sub _messages ($self, $c) {
    my $client = $c->client_name or return;
    my $consent = $c->req->headers->header('X-Homelab-Consent') // '';
    return $c->render(json => { error => 'X-Homelab-Consent is required: name the consent this request is made under' }, status => 400)
        unless $consent =~ /\A[A-Za-z0-9._:-]{1,120}\z/;
    my $account = $c->req->headers->header('X-Homelab-Account');
    $account = undef unless defined $account && $account =~ /\A[A-Za-z0-9._@+-]{1,200}\z/;

    my $raw = $c->req->body;
    my $req = eval { decode_json($raw) };
    return $c->render(json => { error => 'the body must be a JSON object (a Messages API request)' }, status => 400)
        unless ref $req eq 'HASH' && $req->{model} && ref $req->{messages} eq 'ARRAY';
    return $c->render(json => { error => 'no API key configured on the AI service' }, status => 503) unless length $self->api_key;

    # The budget is read from the usage table; a database blip must not stop
    # an answer the caller can still degrade without (it is logged instead).
    my $today = eval {
        $self->pg->db->query(q{SELECT count(*) FROM ai.requests WHERE client = ? AND created_at >= date_trunc('day', NOW())}, $client)->array->[0];
    };
    unless (defined $today) { $self->log->warn("ai: could not read today's usage for $client (budget not enforced this call): $@"); $today = 0 }
    if ($today >= $self->limits->{requests_per_client_per_day}) {
        $self->_record($client, $req, consent => $consent, account => $account, status => 429, error => 'daily budget', ms => 0);
        return $c->render(json => { error => "daily request budget reached for $client" }, status => 429);
    }

    my $t0 = [Time::HiRes::gettimeofday];
    my $tx = $self->ua->post($self->upstream, {
        'x-api-key'         => $self->api_key,
        'anthropic-version' => API_VERSION,
        'anthropic-beta'    => BETA,
        'content-type'      => 'application/json',
    }, $raw);
    my $ms = int(1000 * Time::HiRes::tv_interval($t0));
    my $res = $tx->res;
    my $err = $tx->error;
    if ($err && !$err->{code}) {
        $self->_record($client, $req, consent => $consent, account => $account, status => 0, error => $err->{message}, ms => $ms);
        return $c->render(json => { error => 'the AI service could not reach its upstream: ' . ($err->{message} // 'connection error'), kind => 'transport' }, status => 502);
    }
    my $body = eval { $res->json } // {};
    $body = {} unless ref $body eq 'HASH';
    my $uerr = $body->{error};
    $self->_record($client, $req, consent => $consent, account => $account, status => $res->code, ms => $ms,
        usage => $body->{usage}, model_used => $body->{model},
        error => ($res->code >= 400 ? (ref $uerr eq 'HASH' ? ($uerr->{message} // $uerr->{type}) : (defined $uerr && !ref $uerr ? $uerr : "HTTP " . $res->code)) : undef));
    # Anthropic's answer, status and bytes as they came.
    $c->res->headers->content_type($res->headers->content_type // 'application/json');
    $c->res->headers->header('X-Homelab-AI-Latency-Ms' => $ms);
    return $c->render(data => $res->body, status => $res->code);
}

sub _record ($self, $client, $req, %a) {
    my $u = $a{usage} // {};
    eval {
        $self->pg->db->query(
            q{INSERT INTO ai.requests (client, consent, account, model, model_used, status, error, latency_ms,
                  input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, max_tokens)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)},
            $client, $a{consent}, $a{account}, $req->{model}, $a{model_used}, $a{status}, (defined $a{error} ? substr($a{error}, 0, 500) : undef), $a{ms},
            $u->{input_tokens}, $u->{output_tokens}, $u->{cache_read_input_tokens}, $u->{cache_creation_input_tokens}, $req->{max_tokens},
        );
        1;
    } or $self->log->warn("ai: could not record usage: $@");
    return;
}

# GET /internal/v1/ai/usage?days=7 -- totals by client and day, for the
# Metrics tab and for a person wondering what this costs.
sub _usage ($self, $c) {
    $c->client_name or return;
    my $days = ($c->param('days') // 7) =~ /\A\d{1,3}\z/ ? $c->param('days') // 7 : 7;
    my $rows = $self->pg->db->query(
        q{SELECT client, date_trunc('day', created_at)::date AS day, count(*) AS requests,
                 count(*) FILTER (WHERE status = 200) AS ok,
                 coalesce(sum(input_tokens), 0) AS input_tokens, coalesce(sum(output_tokens), 0) AS output_tokens,
                 coalesce(sum(cache_read_tokens), 0) AS cache_read_tokens, coalesce(sum(cache_write_tokens), 0) AS cache_write_tokens,
                 coalesce(avg(latency_ms), 0)::int AS avg_latency_ms
            FROM ai.requests WHERE created_at >= NOW() - (?::int * INTERVAL '1 day')
           GROUP BY client, day ORDER BY day DESC, client}, $days,
    )->hashes->to_array;
    return $c->render(json => { days => $days + 0, rows => $rows, limits => $self->limits });
}

1;
