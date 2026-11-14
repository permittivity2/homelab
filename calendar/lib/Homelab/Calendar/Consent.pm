package Homelab::Calendar::Consent;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Digest::SHA qw(sha256_hex);

our @EXPORT_OK = qw(notice_body notice_sha256 state_for record withdraw
                    research_notice_body research_notice_sha256 research_state_for research_record research_withdraw);

# Informed consent for the AI proposal, recorded rather than assumed -- the
# same shape as search's AI/Consent.pm: the record says WHICH WORDS the person
# agreed to, by hash. Change a word below and every account is asked again
# with the new wording, which is the point. So fix typos deliberately.
#
# THE WORDS ARE SILVER LININGS'. Drafted here so the feature is complete and
# honest on day one; to be read by someone who can speak for the company and
# checked against the published privacy policy.

my $BODY = <<'NOTICE';
"Propose with AI" sends one email to Anthropic, a third party.

When you press it, the subject, the sender, the date and the first part of
the text of THE ONE EMAIL you opened the calendar link from are sent to
Anthropic's API, through Silver Linings' own AI service, to propose an event:
a title, a start, an end, a place and a note. Nothing is sent until you press
the button, and nothing is saved until you press Save.

Your personal information is NOT removed first. It is sent as it appears in
that email.

We do not tell Anthropic whose email it is. Requests carry no account name or
address; the email's own contents may still identify you.

You can turn this off at any time in the calendar's Settings. Turning it off
stops all further sending; it does not recall what was already sent.
NOTICE

sub notice_body   { return $BODY }
sub notice_sha256 { return sha256_hex($BODY) }

# state_for($db, $email) -> { enabled => 0|1, current => 0|1, sha => $recorded_or_undef }
# current = the record matches today's wording; only then may a request go out.
sub state_for ($db, $email) {
    my $row = $db->query('SELECT ai_enabled, ai_consent_sha256 FROM calendar.account_settings WHERE user_email = ?', lc $email)->hash // {};
    my $sha = $row->{ai_consent_sha256};
    my $current = (defined $sha && $sha eq notice_sha256()) ? 1 : 0;
    return { enabled => ($row->{ai_enabled} && $current) ? 1 : 0, current => $current, sha => $sha };
}

# record($db, $email, $sha) -> 1 when $sha is today's wording (anything else
# is refused: a stale page cannot consent to words it never showed).
sub record ($db, $email, $sha) {
    return 0 unless defined $sha && $sha eq notice_sha256();
    $db->query(
        q{INSERT INTO calendar.account_settings (user_email, ai_enabled, ai_consent_sha256, ai_consent_at)
          VALUES (?, TRUE, ?, NOW())
          ON CONFLICT (user_email) DO UPDATE SET ai_enabled = TRUE, ai_consent_sha256 = EXCLUDED.ai_consent_sha256,
              ai_consent_at = NOW(), updated_at = NOW()}, lc $email, $sha,
    );
    return 1;
}

sub withdraw ($db, $email) {
    $db->query(
        q{INSERT INTO calendar.account_settings (user_email, ai_enabled) VALUES (?, FALSE)
          ON CONFLICT (user_email) DO UPDATE SET ai_enabled = FALSE, updated_at = NOW()}, lc $email,
    );
    return 1;
}

# ----- "Find out more" (#78): a second notice, because it does more --------

my $RESEARCH_BODY = <<'NOTICE';
"Find out more" searches the web about the event in one email.

When you press it, the subject and the first part of THE ONE EMAIL you opened
the calendar link from, plus what the proposal suggested looking up (a place,
a team, a date), are sent to Anthropic's API through Silver Linings' own AI
service. The model then runs up to five web searches, built from that text,
through Anthropic's search provider, reads the pages it finds, and answers
with facts for you to pick (an address, who is playing, a schedule), each
with its source.

Your personal information is NOT removed first. Words from your email can
appear in those searches.

We do not tell Anthropic or the search provider whose email it is. Nothing
from the pages is kept by us except the facts you choose to put in the event.

You can turn this off at any time in the calendar's Settings. Turning it off
stops all further searching; it does not recall what was already sent.
NOTICE

sub research_notice_body   { return $RESEARCH_BODY }
sub research_notice_sha256 { return sha256_hex($RESEARCH_BODY) }

# research_state_for($db, $email) -> { enabled, current, sha, auto }
sub research_state_for ($db, $email) {
    my $row = $db->query('SELECT research_enabled, research_consent_sha256, research_auto FROM calendar.account_settings WHERE user_email = ?', lc $email)->hash // {};
    my $sha = $row->{research_consent_sha256};
    my $current = (defined $sha && $sha eq research_notice_sha256()) ? 1 : 0;
    return { enabled => ($row->{research_enabled} && $current) ? 1 : 0, current => $current, sha => $sha,
             auto => ($row->{research_auto} ? 1 : 0) };
}

sub research_record ($db, $email, $sha) {
    return 0 unless defined $sha && $sha eq research_notice_sha256();
    $db->query(
        q{INSERT INTO calendar.account_settings (user_email, research_enabled, research_consent_sha256, research_consent_at)
          VALUES (?, TRUE, ?, NOW())
          ON CONFLICT (user_email) DO UPDATE SET research_enabled = TRUE, research_consent_sha256 = EXCLUDED.research_consent_sha256,
              research_consent_at = NOW(), updated_at = NOW()}, lc $email, $sha,
    );
    return 1;
}

sub research_withdraw ($db, $email) {
    $db->query(
        q{INSERT INTO calendar.account_settings (user_email, research_enabled, research_auto) VALUES (?, FALSE, FALSE)
          ON CONFLICT (user_email) DO UPDATE SET research_enabled = FALSE, research_auto = FALSE, updated_at = NOW()}, lc $email,
    );
    return 1;
}

1;
