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
has consent_name  => 'calendar';
has ua            => sub { Mojo::UserAgent->new->connect_timeout(5)->inactivity_timeout(60)->request_timeout(60) };
has log           => undef;

sub configured ($self) { return (length $self->service_url && length $self->service_token) ? 1 : 0 }

# Canonical JSON: the system prompt is the cached prefix, and the service
# forwards bytes as they are, so the encoding must be the same every call.
my $CANON = JSON::PP->new->canonical(1)->utf8(1);

my $SYSTEM = <<'PROMPT';
You turn one email into one calendar event. Answer with a single JSON object and nothing else, with exactly these keys:
"title" (short, no "Re:"), "all_day" (true/false), "start" ("YYYY-MM-DDTHH:MM:SS" wall-clock time in the given time zone, or "YYYY-MM-DD" when all_day), "end" (same form; for all_day the day AFTER the last day), "location" (string or null), "description" (one or two sentences from the email that matter for the event, or null), "confidence" ("high", "medium" or "low"), "note" (one short sentence on what was unclear, or null).
Rules: use the email's own dates and times; resolve relative words ("Friday", "tomorrow") against the reference date given; if no time is given, make it all_day; never invent a place; if the email contains no event at all, still answer with your best single guess and confidence "low".
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

# Only the fields the editor knows, in shapes it accepts.
sub _sanitise ($p, $zone) {
    my %o;
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
