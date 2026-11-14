package Homelab::Calendar::AI;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use Homelab::Calendar::Recurrence qw(parse_wall validate_zone);

# The AI proposal: one email's text in, one event's fields out, through the
# fleet's internal AI service (homelab-ai, #76) -- never Anthropic directly,
# so this app holds no key. Called only after the person consented (Consent.pm)
# and pressed the button; the service records the call under that consent.

has service_url   => '';
has service_token => '';
has model         => 'claude-haiku-5-5';
has max_tokens    => 1024;
# "Find out more" (#78) reads web pages: a model with more room than the
# proposal's, and the web-search server tool, capped per call.
has research_model      => 'claude-sonnet-5-5';
has research_max_tokens => 2048;
has research_max_uses   => 5;
has consent_name  => 'calendar';
has ua            => sub { Mojo::UserAgent->new->connect_timeout(5)->inactivity_timeout(60)->request_timeout(60) };
has log           => undef;

sub configured ($self) { return (length $self->service_url && length $self->service_token) ? 1 : 0 }

# Canonical JSON: the system prompt is the cached prefix, and the service
# forwards bytes as they are, so the encoding must be the same every call.
my $CANON = JSON::PP->new->canonical(1)->utf8(1);

my $SYSTEM = <<'PROMPT';
You turn one email into one calendar event. Answer with a single JSON object and nothing else, with exactly these keys:
"title" (short, no "Re:"), "all_day" (true/false), "start" ("YYYY-MM-DDTHH:MM:SS" wall-clock time in the given time zone, or "YYYY-MM-DD" when all_day), "end" (same form; for all_day the day AFTER the last day), "location" (string or null), "description" (one or two sentences from the email that matter for the event, or null), "confidence" ("high", "medium" or "low"), "note" (one short sentence on what was unclear, or null),
"research" (an object: "worth_it" true only when the email names something a web search could add facts about -- a venue, a team, a public event, an organisation -- and the facts would help the event (an address, who is playing, a schedule); "about" a few words naming that thing, e.g. "McCool Field, Cleveland MS"; "query" the single best web search to run; all three null when worth_it is false).
Rules: use the email's own dates and times; resolve relative words ("Friday", "tomorrow") against the reference date given; if no time is given, make it all_day; never invent a place; if the email contains no event at all, still answer with your best single guess and confidence "low".
PROMPT

my $RESEARCH_SYSTEM = <<'PROMPT';
You help fill in one calendar event made from one email. Use the web_search tool (at most a few searches) to find facts about the thing named, then answer. Your final message must end with a JSON object inside a ```json fence, with exactly these keys:
"summary" (one sentence on what you found or did not find),
"facts" (an array of at most 8 objects: "label" (two or three words, e.g. "Address", "Opponent", "Schedule"), "value" (the fact, short), "field" (where it belongs in the event: "location" for an address or place, "title" for a better event name, otherwise "description"), "source" (the URL you got it from, or null), "confidence" ("high", "medium" or "low")).
Rules: only facts you actually found on a page; never guess an address or an opponent; when the searches find nothing relevant, answer with an empty facts array and say so in the summary; prefer the official page of a venue, team or organisation as the source; keep the reference date in mind when choosing which schedule entry matters.
PROMPT

# propose(%args) -> { ok => 1, proposal => {...}, raw => $text } or { ok => 0, error => '...' }
#   subject, from, date_header, text, zone, now (DateTime), account_key (opaque, optional)
sub propose ($self, %a) {
    return { ok => 0, error => 'AI proposals are not configured on this calendar' } unless $self->configured;
    my $zone = validate_zone($a{zone} // '') ? $a{zone} : 'America/Chicago';
    my $now  = $a{now};
    my $ref  = $now ? $now->clone->set_time_zone($zone)->strftime('%A %Y-%m-%d %H:%M') : '';
    my $text = substr($a{text} // '', 0, 12000);
    my $user = "Time zone: $zone\nReference date and time: $ref\n\nFrom: " . ($a{from} // '') . "\nDate: " . ($a{date_header} // '')
             . "\nSubject: " . ($a{subject} // '') . "\n\n" . $text;
    my $payload = $CANON->encode({
        model => $self->model, max_tokens => $self->max_tokens,
        system => [ { type => 'text', text => $SYSTEM, cache_control => { type => 'ephemeral' } } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my %h = (
        Authorization => 'Bearer ' . $self->service_token,
        'Content-Type' => 'application/json',
        'X-Homelab-Consent' => $self->consent_name . ':' . substr($a{consent_sha} // '', 0, 16),
    );
    $h{'X-Homelab-Account'} = sha256_hex($a{account_key}) if defined $a{account_key} && length $a{account_key};
    my $tx = eval { $self->ua->post($self->service_url =~ s{/\z}{}r . '/internal/v1/ai/messages', \%h, $payload) };
    return { ok => 0, error => 'the AI service could not be reached' } unless $tx;
    my $err = $tx->error;
    return { ok => 0, error => 'the AI service could not be reached: ' . ($err->{message} // 'connection error') } if $err && !$err->{code};
    my $res = $tx->res;
    my $body = eval { $res->json } // {};
    if ($res->code != 200) {
        # Anthropic's errors are objects; the service's own are plain strings.
        my $e = ref $body eq 'HASH' ? $body->{error} : undef;
        my $msg = ref $e eq 'HASH' ? ($e->{message} // $e->{type} // '') : (defined $e && !ref $e ? $e : '');
        $self->log->warn("calendar ai: service answered " . $res->code . " $msg") if $self->log;
        return { ok => 0, error => $res->code == 429 ? 'the AI budget for today is used up' : 'the AI service answered with an error' };
    }
    my $text_out = join '', map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
    my ($json) = $text_out =~ /(\{.*\})/s;
    my $p = $json ? eval { decode_json($json) } : undef;
    return { ok => 0, error => 'the AI answer was not usable', raw => substr($text_out, 0, 500) } unless ref $p eq 'HASH';
    return { ok => 1, proposal => _sanitise($p, $zone), raw => substr($text_out, 0, 2000),
             usage => $body->{usage}, model => $body->{model} };
}

# research(%args) -> { ok => 1, summary, facts => [...], searches => N } or { ok => 0, error }
#   subject, from, text, about, query, zone, now (DateTime), consent_sha, account_key
# One request with Anthropic's web-search server tool; the service counts
# and caps the searches (#78). Facts come back sanitised for the editor.
sub research ($self, %a) {
    return { ok => 0, error => 'Research is not configured on this calendar' } unless $self->configured;
    my $zone = validate_zone($a{zone} // '') ? $a{zone} : 'America/Chicago';
    my $ref  = $a{now} ? $a{now}->clone->set_time_zone($zone)->strftime('%A %Y-%m-%d %H:%M') : '';
    my $text = substr($a{text} // '', 0, 6000);
    my $user = "Time zone: $zone\nReference date and time: $ref\nLook into: " . ($a{about} // '') . "\nSuggested search: " . ($a{query} // '')
             . "\n\nFrom: " . ($a{from} // '') . "\nSubject: " . ($a{subject} // '') . "\n\n" . $text;
    my $payload = $CANON->encode({
        model => $self->research_model, max_tokens => $self->research_max_tokens,
        system => [ { type => 'text', text => $RESEARCH_SYSTEM, cache_control => { type => 'ephemeral' } } ],
        tools => [ { type => 'web_search_20250305', name => 'web_search', max_uses => $self->research_max_uses } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my %h = (
        Authorization => 'Bearer ' . $self->service_token,
        'Content-Type' => 'application/json',
        'X-Homelab-Consent' => $self->consent_name . ':research:' . substr($a{consent_sha} // '', 0, 16),
    );
    $h{'X-Homelab-Account'} = sha256_hex($a{account_key}) if defined $a{account_key} && length $a{account_key};
    my $tx = eval { $self->ua->post($self->service_url =~ s{/\z}{}r . '/internal/v1/ai/messages', \%h, $payload) };
    return { ok => 0, error => 'the AI service could not be reached' } unless $tx;
    my $err = $tx->error;
    return { ok => 0, error => 'the AI service could not be reached: ' . ($err->{message} // 'connection error') } if $err && !$err->{code};
    my $res = $tx->res;
    my $body = eval { $res->json } // {};
    if ($res->code != 200) {
        my $e = ref $body eq 'HASH' ? $body->{error} : undef;
        my $msg = ref $e eq 'HASH' ? ($e->{message} // $e->{type} // '') : (defined $e && !ref $e ? $e : '');
        $self->log->warn("calendar research: service answered " . $res->code . " $msg") if $self->log;
        return { ok => 0, error => $res->code == 429 ? ($msg =~ /search/ ? 'the web-search budget for today is used up' : 'the AI budget for today is used up')
                                                      : 'the AI service answered with an error' };
    }
    # With the search tool the answer is several blocks (searches, results,
    # text with citations); the JSON is in the text, fenced at the end.
    my $text_out = join "\n", map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
    my ($json) = $text_out =~ /```json\s*(\{.*?\})\s*```/s;
    ($json) = $text_out =~ /(\{\s*"(?:summary|facts)".*\})/s unless $json;
    my $p = $json ? eval { decode_json($json) } : undef;
    return { ok => 0, error => 'the research answer was not usable', raw => substr($text_out, 0, 500) } unless ref $p eq 'HASH';
    my $searches = (ref $body->{usage} eq 'HASH' && ref $body->{usage}{server_tool_use} eq 'HASH') ? ($body->{usage}{server_tool_use}{web_search_requests} // 0) : 0;
    return { ok => 1, summary => _str($p->{summary}, 300) // '', facts => _facts($p->{facts}), searches => $searches + 0,
             model => $body->{model}, usage => $body->{usage} };
}

sub _str ($v, $max) { return (defined $v && !ref $v && length $v) ? substr($v =~ s/\s+/ /gr =~ s/^\s+|\s+$//gr, 0, $max) : undef }

sub _facts ($list) {
    my @out;
    for my $f (@{ ref $list eq 'ARRAY' ? $list : [] }) {
        next unless ref $f eq 'HASH';
        my $value = _str($f->{value}, 300) or next;
        my $field = ($f->{field} // '') =~ /^(location|title|description)$/ ? $1 : 'description';
        my $source = _str($f->{source}, 500);
        $source = undef unless defined $source && $source =~ m{^https?://\S+$}i;
        push @out, { label => _str($f->{label}, 60) // 'Fact', value => $value, field => $field, source => $source,
                     confidence => (($f->{confidence} // '') =~ /^(high|medium|low)$/) ? $1 : 'low' };
        last if @out >= 8;
    }
    return \@out;
}

# Only the fields the editor knows, in shapes it accepts.
sub _sanitise ($p, $zone) {
    my %o;
    # The research hint (#78): is there anything a web search could add?
    my $r = ref $p->{research} eq 'HASH' ? $p->{research} : {};
    $o{research} = $r->{worth_it}
        ? { worth_it => 1, about => _str($r->{about}, 120) // '', query => _str($r->{query}, 200) // '' }
        : { worth_it => 0 };
    $o{title} = defined $p->{title} && !ref $p->{title} ? substr($p->{title} =~ s/\s+/ /gr =~ s/^\s+|\s+$//gr, 0, 300) : '';
    $o{all_day} = $p->{all_day} ? 1 : 0;
    for my $k (qw(start end)) {
        my $v = $p->{$k};
        my $dt = (defined $v && !ref $v) ? parse_wall($v, $zone) : undef;
        $o{$k} = $dt ? ($o{all_day} ? $dt->ymd : $dt->strftime('%Y-%m-%dT%H:%M:%S')) : undef;
    }
    $o{location}    = (defined $p->{location} && !ref $p->{location} && length $p->{location}) ? substr($p->{location}, 0, 500) : undef;
    $o{description} = (defined $p->{description} && !ref $p->{description} && length $p->{description}) ? substr($p->{description}, 0, 2000) : undef;
    $o{confidence}  = (($p->{confidence} // '') =~ /^(high|medium|low)$/) ? $1 : 'low';
    $o{note}        = (defined $p->{note} && !ref $p->{note} && length $p->{note}) ? substr($p->{note}, 0, 300) : undef;
    return \%o;
}

1;
