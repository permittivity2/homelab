package Homelab::Calendar::AI;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::Promise;
use Mojo::JSON qw(decode_json);
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use Homelab::Calendar::Recurrence qw(parse_wall validate_zone);

# The AI proposal: one email's text in, one event's fields out, through the
# fleet's internal AI service (homelab-ai, #76) -- never Anthropic directly,
# so this app holds no key. Called only after the person consented
# (Consent.pm) and pressed the button (or, with the #80 consent, by the
# runner as the email arrives); the service records the call under that
# consent.
#
# Every call has a blocking form (propose, research: the request handlers)
# and a promise form (propose_p, research_p: the runner, which must not stop
# the event loop that serves pages while it waits). Both share the request
# builder and the response parser, so there is one prompt and one shape.

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
has ua            => sub { Mojo::UserAgent->new->connect_timeout(5)->inactivity_timeout(90)->request_timeout(90) };
has log           => undef;

sub configured ($self) { return (length $self->service_url && length $self->service_token) ? 1 : 0 }

# Canonical JSON: the system prompt is the cached prefix, and the service
# forwards bytes as they are, so the encoding must be the same every call.
my $CANON = JSON::PP->new->canonical(1)->utf8(1);

my $SYSTEM = <<'PROMPT';
You turn one email into one calendar event. Answer with a single JSON object and nothing else, with exactly these keys:
"title" (short, no "Re:"), "all_day" (true/false), "start" ("YYYY-MM-DDTHH:MM:SS" wall-clock time as written in the email, or "YYYY-MM-DD" when all_day), "end" (same form; for all_day the day AFTER the last day), "location" (string or null), "timezone" (the IANA time zone the email's times are in: the zone of the location when the email gives a place whose zone is clear from a city, state, postcode or country, e.g. "America/Chicago" for Overland Park, KS; otherwise the given time zone), "description" (one or two sentences from the email that matter for the event, or null), "confidence" ("high", "medium" or "low"), "note" (one short sentence on what was unclear, or null),
"research" (an object: "worth_it" true only when the email names something a web search could add facts about -- a venue, a team, a public event, an organisation -- and the facts would help the event (an address, who is playing, a schedule); "about" a few words naming that thing, e.g. "McCool Field, Cleveland MS"; "query" the single best web search to run; all three null when worth_it is false).
Rules: use the email's own dates and times; resolve relative words ("Friday", "tomorrow") against the reference date given; if no time is given, make it all_day; never invent a place; if the email contains no event at all, still answer with your best single guess and confidence "low".
PROMPT

my $RESEARCH_SYSTEM = <<'PROMPT';
You help fill in one calendar event made from one email. Use the web_search tool (at most a few searches) to find facts about the thing named, then answer. Your final message must end with a JSON object inside a ```json fence, with exactly these keys:
"summary" (one sentence on what you found or did not find),
"facts" (an array of at most 8 objects: "label" (two or three words, e.g. "Address", "Opponent", "Schedule"), "value" (the fact, short), "field" (where it belongs in the event: "location" for an address or place, "title" for a better event name, otherwise "description"), "source" (the URL you got it from, or null), "confidence" ("high", "medium" or "low")).
Rules: only facts you actually found on a page; never guess an address or an opponent; when the searches find nothing relevant, answer with an empty facts array and say so in the summary; prefer the official page of a venue, team or organisation as the source; keep the reference date in mind when choosing which schedule entry matters.
PROMPT

sub _url ($self) { return $self->service_url =~ s{/\z}{}r . '/internal/v1/ai/messages' }

sub _headers ($self, $consent_tag, $account_key) {
    my %h = (
        Authorization => 'Bearer ' . $self->service_token,
        'Content-Type' => 'application/json',
        'X-Homelab-Consent' => $consent_tag,
    );
    $h{'X-Homelab-Account'} = sha256_hex($account_key) if defined $account_key && length $account_key;
    return \%h;
}

sub _ref ($zone, $now) { return $now ? $now->clone->set_time_zone($zone)->strftime('%A %Y-%m-%d %H:%M') : '' }

# --- propose ----------------------------------------------------------------

sub _propose_request ($self, %a) {
    my $zone = validate_zone($a{zone} // '') ? $a{zone} : 'America/Chicago';
    my $text = substr($a{text} // '', 0, 12000);
    my $user = "Time zone: $zone\nReference date and time: " . _ref($zone, $a{now}) . "\n\nFrom: " . ($a{from} // '') . "\nDate: " . ($a{date_header} // '')
             . "\nSubject: " . ($a{subject} // '') . "\n\n" . $text;
    my $payload = $CANON->encode({
        model => $self->model, max_tokens => $self->max_tokens,
        system => [ { type => 'text', text => $SYSTEM, cache_control => { type => 'ephemeral' } } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my $tag = $self->consent_name . ':' . ($a{consent_kind} ? "$a{consent_kind}:" : '') . substr($a{consent_sha} // '', 0, 16);
    return ($self->_url, $self->_headers($tag, $a{account_key}), $payload, $zone);
}

sub _parse_propose ($self, $res, $zone) {
    my $err = $self->_service_error($res);
    return $err if $err;
    my $body = eval { $res->json } // {};
    my $text_out = join '', map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
    my ($json) = $text_out =~ /(\{.*\})/s;
    my $p = $json ? eval { decode_json($json) } : undef;
    return { ok => 0, error => 'the AI answer was not usable', raw => substr($text_out, 0, 500) } unless ref $p eq 'HASH';
    return { ok => 1, proposal => _sanitise($p, $zone), raw => substr($text_out, 0, 2000), usage => $body->{usage}, model => $body->{model} };
}

# propose(%args) -> { ok => 1, proposal => {...} } or { ok => 0, error => '...' }
#   subject, from, date_header, text, zone, now (DateTime), consent_sha, account_key (opaque, optional)
sub propose ($self, %a) {
    return { ok => 0, error => 'AI proposals are not configured on this calendar' } unless $self->configured;
    my ($url, $h, $payload, $zone) = $self->_propose_request(%a);
    my $tx = eval { $self->ua->post($url, $h, $payload) };
    return $self->_transport_error($tx) // $self->_parse_propose($tx->res, $zone);
}

# The same, without blocking the event loop (the runner).
sub propose_p ($self, %a) {
    return Mojo::Promise->resolve({ ok => 0, error => 'AI proposals are not configured on this calendar' }) unless $self->configured;
    my ($url, $h, $payload, $zone) = $self->_propose_request(%a);
    return $self->ua->post_p($url, $h, $payload)->then(sub ($tx) { $self->_transport_error($tx) // $self->_parse_propose($tx->res, $zone) })
        ->catch(sub ($e) { { ok => 0, error => 'the AI service could not be reached: ' . ($e // '') } });
}

# --- research ("Find out more", #78) ----------------------------------------

sub _research_request ($self, %a) {
    my $zone = validate_zone($a{zone} // '') ? $a{zone} : 'America/Chicago';
    my $text = substr($a{text} // '', 0, 6000);
    my $user = "Time zone: $zone\nReference date and time: " . _ref($zone, $a{now}) . "\nLook into: " . ($a{about} // '') . "\nSuggested search: " . ($a{query} // '')
             . "\n\nFrom: " . ($a{from} // '') . "\nSubject: " . ($a{subject} // '') . "\n\n" . $text;
    my $payload = $CANON->encode({
        model => $self->research_model, max_tokens => $self->research_max_tokens,
        system => [ { type => 'text', text => $RESEARCH_SYSTEM, cache_control => { type => 'ephemeral' } } ],
        tools => [ { type => 'web_search_20250305', name => 'web_search', max_uses => $self->research_max_uses } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my $tag = $self->consent_name . ':research:' . substr($a{consent_sha} // '', 0, 16);
    return ($self->_url, $self->_headers($tag, $a{account_key}), $payload);
}

sub _parse_research ($self, $res) {
    my $err = $self->_service_error($res, 1);
    return $err if $err;
    my $body = eval { $res->json } // {};
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

# research(%args) -> { ok => 1, summary, facts => [...], searches => N } or { ok => 0, error }
#   subject, from, text, about, query, zone, now (DateTime), consent_sha, account_key
sub research ($self, %a) {
    return { ok => 0, error => 'Research is not configured on this calendar' } unless $self->configured;
    my ($url, $h, $payload) = $self->_research_request(%a);
    my $tx = eval { $self->ua->post($url, $h, $payload) };
    return $self->_transport_error($tx) // $self->_parse_research($tx->res);
}

sub research_p ($self, %a) {
    return Mojo::Promise->resolve({ ok => 0, error => 'Research is not configured on this calendar' }) unless $self->configured;
    my ($url, $h, $payload) = $self->_research_request(%a);
    return $self->ua->post_p($url, $h, $payload)->then(sub ($tx) { $self->_transport_error($tx) // $self->_parse_research($tx->res) })
        ->catch(sub ($e) { { ok => 0, error => 'the AI service could not be reached: ' . ($e // '') } });
}

# --- search by meaning (#87) -------------------------------------------------
#
# "doctor" should find the infusion at the hospital. The literal search cannot;
# the model can, given the words and a short list of the person's events.
# Blocking only: it runs inside the search request.

my $RELATE_SYSTEM = <<'PROMPT';
You help someone find events in their own calendar. You get what they typed and a list of their events, one per line: "id | date | title | place | notes". Answer with a single JSON object and nothing else: {"matches": [{"id": N, "why": "..."}]}.
List only events a reasonable person would consider relevant to what they typed by MEANING, not spelling: "doctor" matches a hospital infusion, a dentist or a physical; "car" matches an oil change or an inspection; a person's first name matches events with that person; "trip" matches a flight or a hotel. Most relevant first, at most 10. Exact word matches are already shown to the person, so you may leave them out. "why" is at most eight plain words saying what links the event to the search. When nothing is related, answer {"matches": []}.
PROMPT

sub _relate_request ($self, %a) {
    my $zone = validate_zone($a{zone} // '') ? $a{zone} : 'America/Chicago';
    my @lines;
    for my $e (@{ $a{candidates} // [] }) {
        my $when = $e->{when} // '';
        my $notes = _str($e->{description}, 160) // '';
        push @lines, join(' | ', $e->{id}, $when, _str($e->{title}, 120) // '', _str($e->{location}, 120) // '', $notes);
        last if @lines >= 300;
    }
    my $user = "Time zone: $zone\nReference date and time: " . _ref($zone, $a{now}) . "\nSearch: " . (_str($a{query}, 200) // '')
             . "\n\nEvents:\n" . join("\n", @lines);
    my $payload = $CANON->encode({
        model => $self->model, max_tokens => 600,
        system => [ { type => 'text', text => $RELATE_SYSTEM, cache_control => { type => 'ephemeral' } } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my $tag = $self->consent_name . ':search:' . substr($a{consent_sha} // '', 0, 16);
    return ($self->_url, $self->_headers($tag, $a{account_key}), $payload);
}

sub _parse_relate ($self, $res, $allowed) {
    my $err = $self->_service_error($res);
    return $err if $err;
    my $body = eval { $res->json } // {};
    my $text_out = join '', map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
    my ($json) = $text_out =~ /(\{.*\})/s;
    my $p = $json ? eval { decode_json($json) } : undef;
    return { ok => 0, error => 'the AI answer was not usable', raw => substr($text_out, 0, 500) } unless ref $p eq 'HASH' && ref $p->{matches} eq 'ARRAY';
    my (@out, %seen);
    for my $m (@{ $p->{matches} }) {
        next unless ref $m eq 'HASH' && defined $m->{id} && !ref $m->{id} && $m->{id} =~ /\A\d+\z/;
        next unless $allowed->{ $m->{id} } && !$seen{ $m->{id} }++;    # only ids it was shown, once each
        push @out, { id => $m->{id} + 0, why => _str($m->{why}, 80) // '' };
        last if @out >= 10;
    }
    return { ok => 1, matches => \@out, model => $body->{model}, usage => $body->{usage} };
}

# relate(%args) -> { ok => 1, matches => [ { id, why } ] } or { ok => 0, error }
#   query, candidates => [ { id, when, title, location, description } ], zone, now, consent_sha, account_key
sub relate ($self, %a) {
    return { ok => 0, error => 'AI search is not configured on this calendar' } unless $self->configured;
    return { ok => 1, matches => [] } unless @{ $a{candidates} // [] };
    my ($url, $h, $payload) = $self->_relate_request(%a);
    my $tx = eval { $self->ua->post($url, $h, $payload) };
    return $self->_transport_error($tx) // $self->_parse_relate($tx->res, { map { $_->{id} => 1 } @{ $a{candidates} } });
}

# --- the zone of a place (#89) ----------------------------------------------
#
# "11849 College Blvd, Overland Park, KS 66210" is Central time. The model
# knows that for any address or town a person would type; it is a guess and
# is shown as one.

my $ZONE_SYSTEM = <<'PROMPT';
You name the time zone of a place. You get an address, a town, a venue or a region as a person typed it into a calendar's location field. Answer with a single JSON object and nothing else: {"timezone": "...", "confidence": "high" | "medium" | "low", "place": "..."}.
"timezone" is the IANA zone the place keeps (e.g. "America/Chicago", "America/Denver", "Europe/Berlin"), or null when the text does not name a place on Earth clearly enough (a room number, a web link, "home"). "place" is the place as you understood it, in at most six words. Use "low" when you had to guess between zones (a state split between two, a town name found in several places).
PROMPT

sub _zone_request ($self, %a) {
    my $user = "Location field: " . (_str($a{place}, 300) // '') . "\nThe person's own zone, for context only: " . ($a{zone} // '');
    my $payload = $CANON->encode({
        model => $self->model, max_tokens => 200,
        system => [ { type => 'text', text => $ZONE_SYSTEM, cache_control => { type => 'ephemeral' } } ],
        messages => [ { role => 'user', content => $user } ],
    });
    my $tag = $self->consent_name . ':zone:' . substr($a{consent_sha} // '', 0, 16);
    return ($self->_url, $self->_headers($tag, $a{account_key}), $payload);
}

sub _parse_zone ($self, $res) {
    my $err = $self->_service_error($res);
    return $err if $err;
    my $body = eval { $res->json } // {};
    my $text_out = join '', map { $_->{text} // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @{ $body->{content} // [] };
    my ($json) = $text_out =~ /(\{.*\})/s;
    my $p = $json ? eval { decode_json($json) } : undef;
    return { ok => 0, error => 'the AI answer was not usable', raw => substr($text_out, 0, 500) } unless ref $p eq 'HASH';
    my $zone = (defined $p->{timezone} && !ref $p->{timezone} && validate_zone($p->{timezone})) ? $p->{timezone} : undef;
    return { ok => 1, timezone => $zone, confidence => (($p->{confidence} // '') =~ /^(high|medium|low)$/) ? $1 : 'low',
             place => _str($p->{place}, 80), model => $body->{model}, usage => $body->{usage} };
}

# zone_for_place(%args) -> { ok => 1, timezone => 'America/Chicago' | undef, confidence, place } or { ok => 0, error }
#   place, zone (the viewer's), consent_sha, account_key
sub zone_for_place ($self, %a) {
    return { ok => 0, error => 'AI is not configured on this calendar' } unless $self->configured;
    my ($url, $h, $payload) = $self->_zone_request(%a);
    my $tx = eval { $self->ua->post($url, $h, $payload) };
    return $self->_transport_error($tx) // $self->_parse_zone($tx->res);
}

# --- shared ----------------------------------------------------------------

sub _transport_error ($self, $tx) {
    return { ok => 0, error => 'the AI service could not be reached' } unless $tx;
    my $err = $tx->error;
    return { ok => 0, error => 'the AI service could not be reached: ' . ($err->{message} // 'connection error') } if $err && !$err->{code};
    return undef;
}

sub _service_error ($self, $res, $research = 0) {
    return undef if $res->code == 200;
    my $body = eval { $res->json } // {};
    # Anthropic's errors are objects; the service's own are plain strings.
    my $e = ref $body eq 'HASH' ? $body->{error} : undef;
    my $msg = ref $e eq 'HASH' ? ($e->{message} // $e->{type} // '') : (defined $e && !ref $e ? $e : '');
    $self->log->warn('calendar ' . ($research ? 'research' : 'ai') . ': service answered ' . $res->code . " $msg") if $self->log;
    return { ok => 0, error => $res->code == 429
        ? ($msg =~ /search/ ? 'the web-search budget for today is used up' : 'the AI budget for today is used up')
        : 'the AI service answered with an error' };
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
    # The zone the times are in (#89): the place's when the email names one,
    # so a Kansas appointment read in Montana lands at the right instant.
    # Only a real zone gets through; anything else means "the given one".
    $o{timezone}    = (defined $p->{timezone} && !ref $p->{timezone} && validate_zone($p->{timezone})) ? $p->{timezone} : undef;
    $o{description} = (defined $p->{description} && !ref $p->{description} && length $p->{description}) ? substr($p->{description}, 0, 2000) : undef;
    $o{confidence}  = (($p->{confidence} // '') =~ /^(high|medium|low)$/) ? $1 : 'low';
    $o{note}        = (defined $p->{note} && !ref $p->{note} && length $p->{note}) ? substr($p->{note}, 0, 300) : undef;
    return \%o;
}

1;
