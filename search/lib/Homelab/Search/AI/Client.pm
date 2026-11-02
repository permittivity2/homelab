package Homelab::Search::AI::Client;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use JSON::PP ();

# The Claude API, over plain HTTP with Mojo::UserAgent.
#
# There is no official Anthropic SDK for Perl, so calling the HTTP API
# directly is the sanctioned approach for this language rather than a dodge
# of the Perl-for-production rule. Everything model-specific is pinned here
# in ONE place, with the reason, because several of these are not
# preferences -- they are 400s on the model this app calls.

use constant API_URL     => 'https://api.anthropic.com/v1/messages';
use constant API_VERSION => '2026-10-21';

# `fallbacks: "default"` (the scalar form) pairs with the -07-01 header; the
# array form pairs with -06-01, and crossing them is a 400.
use constant BETA_FALLBACK => 'server-side-fallback-2026-07-01';

# INACTIVITY as well as request: Mojo's inactivity_timeout defaults to 40
# seconds, so setting only request_timeout(120) bought nothing -- a
# non-streaming generation that thinks for 40 seconds without sending a
# byte was killed well short of the ceiling this line looks like it sets.
# A grantee searching across thousands of shared files is exactly the
# question slow enough to hit it.
has ua        => sub { Mojo::UserAgent->new->connect_timeout(10)
                                          ->inactivity_timeout(120)
                                          ->request_timeout(120) };
has api_key   => undef;
has model     => 'claude-opus-5-5';
has gate_model=> 'claude-haiku-5-5';
has effort    => 'low';
has max_tokens=> 16000;
has log       => undef;

# CANONICAL JSON, and this is load-bearing rather than tidy.
#
# Perl randomises hash iteration order per process. The tools block and the
# system prompt are the HEAD of the cached prompt prefix, and prompt caching
# is a byte-prefix match -- so an unsorted encode would emit a different
# prefix on every worker and silently turn every request into a cache WRITE
# instead of a read. There is no error for this. The only symptom is
# usage.cache_read_input_tokens sitting at 0 while the bill is ~20x what it
# should be, which is why _usage() below reports it.
my $CANON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1);

sub _headers ($self) {
    return {
        'x-api-key'         => $self->api_key,
        'anthropic-version' => API_VERSION,
        'anthropic-beta'    => BETA_FALLBACK,
        'content-type'      => 'application/json',
    };
}

# One request. Returns a hashref:
#   { ok => 1, body => <decoded>, usage => {...} }
#   { ok => 0, kind => 'http'|'transport'|'decode', status => N, error => '...' }
#
# Never dies: a search page must degrade to keyword results, not 500,
# because a third party had a bad minute.
sub call ($self, $payload) {
    return { ok => 0, kind => 'config', error => 'no API key configured' }
        unless defined $self->api_key && length $self->api_key;

    my $body = $CANON->encode($payload);
    my $t0   = time;
    my $tx   = eval { $self->ua->post(API_URL, $self->_headers, $body) };
    my $ms   = int((time - $t0) * 1000);

    if (!$tx || $@) {
        my $e = $@ || 'no transaction';
        chomp $e;
        return { ok => 0, kind => 'transport', error => $e, latency_ms => $ms };
    }

    # ->result CROAKS on a transport error rather than returning one, so
    # without this eval a timeout escaped `call` entirely and reached the
    # request handler as an exception -- past every `ok => 0` branch below,
    # which exist precisely so a failed call degrades into a message.
    my $res = eval { $tx->result };
    if (!$res) {
        my $e = $@ || 'no result';
        chomp $e;
        return { ok => 0, kind => 'transport', error => $e, latency_ms => $ms };
    }
    if ($res->is_error) {
        # The API's own error JSON is the useful part; the status alone is
        # not. Logged, never shown to the user.
        my $detail = eval { $res->json->{error}{message} } // $res->message // '';
        return { ok => 0, kind => 'http', status => $res->code,
                 error => $detail, latency_ms => $ms };
    }

    my $json = eval { $res->json };
    return { ok => 0, kind => 'decode', error => "$@", latency_ms => $ms }
        unless ref $json eq 'HASH';

    return { ok => 1, body => $json, usage => _usage($json), latency_ms => $ms };
}

sub _usage ($json) {
    my $u = $json->{usage} // {};
    return {
        input_tokens       => $u->{input_tokens}               // 0,
        output_tokens      => $u->{output_tokens}              // 0,
        cache_read_tokens  => $u->{cache_read_input_tokens}    // 0,
        cache_write_tokens => $u->{cache_creation_input_tokens} // 0,
    };
}

# Build the Messages request.
#
# RENDER ORDER IS tools -> system -> messages, and the cache breakpoint goes
# on the LAST BLOCK OF THE STABLE PREFIX -- here, the end of the system
# block. Everything that varies per request (the question, today's date, the
# person's timezone) must sit AFTER it, in messages, or it invalidates the
# prefix it precedes and the cache never reads.
#
# Opus 5.5 specifics that are 400s rather than preferences:
#   - thinking is ALWAYS on and cannot be disabled; `effort` is the only
#     control. Sending thinking:{type:"disabled"} or any budget_tokens is a
#     400. We omit `thinking` entirely, which runs adaptive.
#   - forced tool use (tool_choice any/tool) is a 400. `auto` cannot
#     guarantee a call, so the caller checks whether one happened; `strict`
#     on each tool keeps the schema-valid-arguments guarantee that `any`
#     used to provide.
#   - assistant prefill was removed.
sub build ($self, %a) {
    my $payload = {
        model      => $a{model} // $self->model,
        max_tokens => $a{max_tokens} // $self->max_tokens,
        system     => $a{system},
        messages   => $a{messages},
        output_config => { effort => $a{effort} // $self->effort },
        # Opt-in rescue when a safety classifier declines. A user's own mail
        # can trip one, and that must degrade rather than fail: without
        # fallbacks the request simply stops.
        fallbacks  => 'default',
    };
    $payload->{tools} = $a{tools} if $a{tools};
    $payload->{tool_choice} = { type => 'auto' } if $a{tools};
    $payload->{output_config}{format} = $a{format} if $a{format};
    return $payload;
}

# A system block with the cache breakpoint on its last element.
sub system_blocks ($self, @texts) {
    my @b = map { { type => 'text', text => $_ } } @texts;
    $b[-1]{cache_control} = { type => 'ephemeral' } if @b;
    return \@b;
}

# stop_reason must be read BEFORE content: on a policy decline the response
# is a 200 whose content is not an answer.
sub is_refusal ($self, $body) { return ($body->{stop_reason} // '') eq 'refusal' }

sub tool_uses ($self, $body) {
    return [ grep { ($_->{type} // '') eq 'tool_use' } @{ $body->{content} // [] } ];
}

sub text_of ($self, $body) {
    return join '', map { $_->{text} // '' }
        grep { ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
}

# Built-in prices, in MICRO-DOLLARS PER MILLION TOKENS. Config overrides
# these per model; these exist so that a config without a `prices:` block
# still accounts correctly.
#
# That is not hypothetical tidiness. The first hand-written ai: block on the
# fleet was {api_key, enabled} and nothing else, and with an empty price
# list every request cost 0, which meant the monthly budget could never
# trip. A spend cap that silently does not apply is worse than no cap,
# because it reads as one. Update these when the vendor changes prices.
use constant DEFAULT_PRICES => {
    'claude-opus-5-5' => {
        input_micros_per_mtok       =>  4_000_000,
        output_micros_per_mtok      => 20_000_000,
        cache_read_micros_per_mtok  =>    200_000,
        cache_write_micros_per_mtok =>  5_000_000,
    },
    'claude-haiku-5-5' => {
        input_micros_per_mtok       =>    100_000,
        output_micros_per_mtok      =>    500_000,
        cache_read_micros_per_mtok  =>     10_000,
        cache_write_micros_per_mtok =>    125_000,
    },
};

# Cost in MICRODOLLARS. Integer arithmetic throughout -- a float dollar
# amount summed over a month does not add up to what was billed.
#
# An unknown model is priced as the most expensive one we know rather than
# as free, and says so in the log. Over-charging a budget is recoverable;
# under-charging it to zero is how a cap stops existing.
sub cost_micros ($self, $prices, $model, $u) {
    my $p = $prices->{$model} // DEFAULT_PRICES->{$model};
    if (!$p) {
        return 0 unless grep { ($u->{$_} // 0) > 0 }
                        qw(input_tokens output_tokens cache_read_tokens cache_write_tokens);
        $self->log->error("ai: no price for model '$model'; charging it as the "
                        . "dearest known model so the budget still moves") if $self->log;
        ($p) = sort { ($b->{output_micros_per_mtok} // 0) <=> ($a->{output_micros_per_mtok} // 0) }
               values %{ +DEFAULT_PRICES };
    }
    my $n = 0;
    $n += ($u->{input_tokens}       // 0) * ($p->{input_micros_per_mtok}      // 0);
    $n += ($u->{output_tokens}      // 0) * ($p->{output_micros_per_mtok}     // 0);
    $n += ($u->{cache_read_tokens}  // 0) * ($p->{cache_read_micros_per_mtok} // 0);
    $n += ($u->{cache_write_tokens} // 0) * ($p->{cache_write_micros_per_mtok}
                                             // ($p->{input_micros_per_mtok} // 0) * 1.25);
    # per-MTok -> per-token, rounded up so an estimate never under-reports.
    return int($n / 1_000_000 + 0.999999);
}

1;
