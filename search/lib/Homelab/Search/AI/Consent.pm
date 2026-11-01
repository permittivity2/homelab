package Homelab::Search::AI::Consent;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Digest::SHA qw(sha256_hex);

our @EXPORT_OK = qw(notice_body notice_sha256 state_for record ensure_notice);

# state_for() and record() take the QUERY OBJECT, not a $db handle. The
# ai_consent policy has a WITH CHECK, so a write through a bare handle is
# refused -- the GUC that says who is asking is set by Query::scoped, and
# routing through it is what keeps one account scope in one place.

# INFORMED CONSENT, recorded rather than assumed.
#
# AI mode sends this person's own mail and files to a third party. That is
# not a preference like a date format, so it is not stored like one: the
# record says WHICH WORDS they agreed to, by hash, and the words themselves
# are kept so the record can be read back later.
#
# THE CONSEQUENCE OF THE HASH. Change a word below and every account's
# consent stops matching. They are asked again, with the new wording, the
# next time they try to use AI mode -- which is the point. Nobody is carried
# silently onto terms they never saw. A typo fix therefore costs every user
# a second dialog, so fix typos deliberately and in one go.
#
# THE WORDS ARE SILVER LININGS', NOT MINE. This is the company's statement
# to its own users about what happens to their mail. It is drafted here so
# the feature is complete and honest on day one; it should be read and
# edited by someone who can speak for the company, and checked against two
# documents I have not seen: Anthropic's commercial terms on API data
# retention (and whether this organisation has zero-data-retention), and
# Silver Linings' own published privacy policy -- an in-app notice sitting
# beside a site-wide policy that says data never leaves is a contradiction
# somebody will eventually point at.

my $BODY = <<'NOTICE';
AI search sends your data to Anthropic, a third party.

With AI search on, what you type AND information from your emails and files
- names, addresses, subjects, dates, and excerpts of their contents - is
sent to Anthropic's API to answer your question.

Your personal information is NOT removed first. It is sent exactly as it
appears in your mail and files.

We do not tell Anthropic whose question it is. Every request from this
service goes through one shared Silver Linings workspace and carries no
account name, address or identifier, which makes it hard to tie any request
back to a particular user. That is not anonymity: the contents themselves
contain names and addresses, so what is sent can still identify you.

The connection is encrypted the whole way, so your data goes from our server
to Anthropic and nowhere else. Someone intercepting it in between is a very
low risk.

To keep the cost down we use prompt caching, which lets Anthropic reuse part
of each request. What is cached is the fixed instructions this service sends
every time - not your question, and not your mail or files, which are sent
after the cached part.

Anthropic is a separate company. Silver Linings, LLC has no control over
what Anthropic does with your data once it is sent, and cannot retrieve or
delete it.

Normal search does not send anything outside Silver Linings' own servers,
and works whether this is on or off.

You can turn this off at any time, in the same place you turned it on.
NOTICE

# Stored and compared as 64 hex characters rather than 32 raw bytes: a
# bytea bind through Mojo::Pg is a trap (`{bytea => ...}` dies with "Cannot
# bind a reference", a bare scalar arrives as 47 bytes), and hex compares
# identically, needs no type hint from any driver, and can be checked
# against `sha256sum` by hand. See migrations/006.
my $SHA = sha256_hex($BODY);

sub notice_body   () { return $BODY }
sub notice_sha256 () { return $SHA  }

# The notices table is write-once per distinct text. Called before any
# consent row references it.
sub ensure_notice ($db) {
    my $row = $db->query('SELECT notice_id FROM search.ai_notices WHERE body_sha256 = ?',
                         $SHA)->hash;
    return $row->{notice_id} if $row;
    # ON CONFLICT rather than a second SELECT: three hosts serve this app and
    # two of them can reach here at once on a cold start.
    return $db->query(
        'INSERT INTO search.ai_notices (body_sha256, body) VALUES (?, ?)
         ON CONFLICT (body_sha256) DO UPDATE SET body = EXCLUDED.body
         RETURNING notice_id', $SHA, $BODY)->hash->{notice_id};
}

# Is AI mode on for this account, RIGHT NOW, under the CURRENT wording?
#
# Derived from the append-only log rather than from a second "enabled"
# column, so there is no stored copy to drift out of step with the history.
# One index serves it: (account_id, notice_id, at DESC).
#
# Returns a hashref: { consented => 0|1, notice_id => N, at => ... }.
# `consented` is false both for someone who never agreed and for someone who
# agreed to EARLIER wording -- the caller cannot tell them apart and must
# not, because both need the dialog.
sub state_for ($query, $account_id) {
    return $query->scoped($account_id, sub ($db) {
    my $notice_id = ensure_notice($db);
    my $row = $db->query(
        'SELECT granted, at FROM search.ai_consent
          WHERE account_id = ? AND notice_id = ?
          ORDER BY at DESC, consent_id DESC LIMIT 1', $account_id, $notice_id)->hash;
    return {
        notice_id => $notice_id,
        consented => ($row && $row->{granted} ? 1 : 0),
        at        => ($row ? $row->{at} : undef),
    };
    });
}

# Append a grant or a revocation. Never updates or deletes: "they turned it
# off on the 3rd" is exactly the fact this table exists to keep.
sub record ($query, $account_id, $granted, $user_agent = undef) {
    return $query->scoped($account_id, sub ($db) {
    my $notice_id = ensure_notice($db);
    $db->query(
        'INSERT INTO search.ai_consent (account_id, notice_id, granted, user_agent)
         VALUES (?, ?, ?, ?)',
        $account_id, $notice_id, ($granted ? 1 : 0),
        (defined $user_agent ? substr($user_agent, 0, 300) : undef));
    return 1;
    });
}

1;
