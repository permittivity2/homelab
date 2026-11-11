package Homelab::PostfixBlockLink::Milter;
use strict;
use warnings;
use Exporter 'import';
use Email::Address::XS qw(parse_email_groups);

our @EXPORT_OK = qw(
    resolve_recipient effective_setting is_signed_mime
    generate_token build_header_value insert_pending_link
    normalise_message_id last_reference_id parse_header_addresses is_safe_address
    choose_reply_address rewrite_address_header
    reply_from_alias_enabled record_received_via lookup_received_via allowed_to_send_as
    single_account reply_footer_line footer_text_lines footer_html
);

# Replicates Postfix's OWN virtual_alias_maps resolution for one envelope
# address, in the SAME order as postfix/config/pgsql-virtual-alias-maps.cf
# .template's query plus Postfix's own @domain fallback:
#
#   1. an explicit, active mail_aliases row for the exact address wins;
#   2. otherwise an ACTIVE REAL MAILBOX maps to itself (this is what keeps
#      a domain catch-all from stealing mail addressed to a real account
#      at that domain -- Postfix's query gained this branch 2026-10-27);
#   3. otherwise the domain's '@domain' catch-all row, if any.
#
# Until 0.2.0 this sub checked the catch-all BEFORE the real mailbox, so a
# real account at a catch-all domain (e.g. testaccountforclaude@mailmasker
# .org, with the @mailmasker.org catch-all pointing elsewhere) resolved to
# the catch-all's destination: block-link then applied the wrong account's
# settings and minted links that would have blocked senders for the wrong
# account (318 of 318 messages, checked 2026-11-10). Postfix itself always
# delivered correctly; only this milter's view was wrong.
#
# Single-hop (an alias whose destination is itself an alias is not
# re-resolved; every destination in this system is a real mailbox, which
# domain-admin enforces when a catch-all is set).
#
# Returns the destination account email (lowercase, as stored in
# api.users), or undef if the address is not a valid, active local
# mailbox at all.
sub resolve_recipient {
    my ($db, $address) = @_;
    my $lc = lc($address // '');
    return undef unless $lc =~ /\@/;

    my $account;
    my $alias = $db->query(
        q{SELECT destination FROM domainadmin.mail_aliases WHERE source_pattern = ? AND active = true},
        $lc,
    )->hash;
    if ($alias) {
        $account = lc $alias->{destination};
    }
    else {
        my $self_row = $db->query('SELECT email FROM api.users WHERE email = ? AND active = true', $lc)->hash;
        return $self_row->{email} if $self_row;

        my ($domain) = $lc =~ /\@(.+)$/;
        my $catchall = $db->query(
            q{SELECT destination FROM domainadmin.mail_aliases WHERE source_pattern = ? AND active = true},
            '@' . ($domain // ''),
        )->hash;
        return undef unless $catchall;
        $account = lc $catchall->{destination};
    }

    my $user = $db->query('SELECT email FROM api.users WHERE email = ? AND active = true', $account)->hash;
    return $user ? $user->{email} : undef;
}

# Account override wins if set; else the account's own home domain's
# default; else off/header (a domain that's never touched this feature
# has no row at all, matching domain_settings' own DEFAULT FALSE).
# Same precedence logic as homelab-block-link's own
# Controller::BlockLink::_effective_setting -- kept in sync by hand
# (two different packages/languages can't share one Perl sub here),
# not by accident.
sub effective_setting {
    my ($db, $account_email) = @_;
    my ($domain) = $account_email =~ /\@(.+)$/;

    my $account = $db->query(
        'SELECT enabled FROM block_link.account_settings WHERE user_email = ?', $account_email,
    )->hash;
    my $domain_row = $db->query(
        'SELECT enabled, mode FROM block_link.domain_settings WHERE domain_name = ?', $domain // '',
    )->hash // { enabled => 0, mode => 'header' };

    my $enabled = (defined $account && defined $account->{enabled}) ? $account->{enabled} : $domain_row->{enabled};
    return { enabled => ($enabled ? 1 : 0), mode => $domain_row->{mode} };
}

# PGP/S-MIME-signed inbound mail silently falls back to header-only
# regardless of the domain's configured mode -- appending plaintext to
# a cryptographically signed body either corrupts it or sits
# untrustworthy outside the signed envelope either way; the header is
# unaffected by the signature and stays useful. Checked against the
# raw Content-Type header VALUE (not just the content-type, since the
# boundary/protocol params on multipart/signed are what actually
# identify it, but the type/subtype alone is enough to decide "don't
# touch the body").
sub is_signed_mime {
    my ($content_type) = @_;
    return 0 unless defined $content_type;
    my $lc = lc($content_type);
    return 1 if $lc =~ m{^\s*multipart/signed};
    return 1 if $lc =~ m{^\s*application/(x-)?pkcs7-mime};
    return 1 if $lc =~ m{^\s*application/pkcs7-signature};
    return 0;
}

# 32 random bytes, hex-encoded -- same /dev/urandom-backed idiom as
# every other token in this ecosystem (homelab-api's own
# Auth::generate_jti, homelab-invite's own _generate_token).
sub generate_token {
    open(my $fh, '<', '/dev/urandom') or die "cannot open /dev/urandom: $!";
    read($fh, my $bytes, 32) == 32 or die 'short read from /dev/urandom';
    close($fh);
    return unpack('H*', $bytes);
}

sub build_header_value {
    my ($public_base_url, $token) = @_;
    return "<$public_base_url/l/$token>";
}

sub insert_pending_link {
    my ($db, %opts) = @_;
    return $db->query(
        q{INSERT INTO block_link.pending_links (token, candidates, message_id, expires_at)
          VALUES (?, ?, ?, NOW() + (? || ' days')::INTERVAL)},
        $opts{token}, $opts{candidates_json}, $opts{message_id}, $opts{ttl_days},
    );
}

# ===== #67: reply from the alias a message was sent to =====================
#
# Two halves, both keyed by (destination account, Message-ID):
#   * inbound (any port): choose_reply_address + record_received_via remember
#     which of the user's own addresses the message was addressed to;
#   * submission (587, authenticated): lookup_received_via + allowed_to_send_as
#     decide whether a reply's From/envelope may be swapped to that address.
# Everything here is pure or plain SQL so it runs under CI's `prove -I lib`
# without Sendmail::PMilter; the daemon script only wires the pieces together.

# A Message-ID or In-Reply-To value -> the bare id between the angle
# brackets (the first one, if several), or a bare "left@right" token when the
# client omitted the brackets. Whitespace is dropped; CASE IS KEPT -- RFC 5322
# ids are compared byte for byte, and phones copy them verbatim into
# In-Reply-To. Capped at 998 (one header line) so a pathological header can
# never become a huge index key.
sub normalise_message_id {
    my ($raw) = @_;
    return undef unless defined $raw;
    my ($id) = $raw =~ /<\s*([^<>\s]+)\s*>/;
    ($id) = $raw =~ /\A\s*([^\s<>]+\@[^\s<>]+)\s*\z/ unless defined $id;
    return undef unless defined $id && length $id && length $id <= 998;
    return $id;
}

# The LAST id in a References: header is the direct parent (RFC 5322 3.6.4);
# used only when a client sent References but no In-Reply-To.
sub last_reference_id {
    my ($raw) = @_;
    return undef unless defined $raw;
    my @ids = $raw =~ /<\s*([^<>\s]+)\s*>/g;
    return @ids ? $ids[-1] : undef;
}

# An address header value (To, Cc, From, ...) -> arrayref of the bare
# addresses in it, lowercased, in header order, groups flattened, invalid
# mailboxes skipped, folded lines unfolded first. $limit (default 50) bounds
# how many a 1000-address To: can turn into (each one may cost the caller a
# resolver query).
sub parse_header_addresses {
    my ($raw, $limit) = @_;
    $limit //= 50;
    return [] unless defined $raw && length $raw;
    (my $v = $raw) =~ s/\r?\n[ \t]+/ /g;

    my @out;
    my @groups = parse_email_groups($v);
    while (@groups) {
        my ($name, $addrs) = splice(@groups, 0, 2);
        for my $a (@{ $addrs // [] }) {
            next unless $a->is_valid;
            my $addr = $a->address;
            next unless defined $addr && length $addr;
            push @out, lc $addr;
            return \@out if @out >= $limit;
        }
    }
    return \@out;
}

# Only an address that is plain RFC 5322 atext@dns-name may ever be written
# into a header or an envelope by this milter -- every address it rewrites TO
# originally arrived in somebody else's To:/Cc: header. No quotes, brackets,
# spaces, comments or control characters; at least one dot in the domain.
sub is_safe_address {
    my ($a) = @_;
    return 0 unless defined $a && length $a && length $a <= 254;
    return $a =~ m{\A[A-Za-z0-9!#\$%&'*+/=?^_`{|}~.-]{1,64}
                   \@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?
                   (?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\z}x ? 1 : 0;
}

# THE DECISION RULE (Gardner, 2026-11-10): when a message was addressed to
# several of the user's own addresses, the reply comes from the first of
# them on the To: line; if none there, the first on Cc:; if none there
# either (Bcc, mailing list), the first envelope recipient that resolved to
# the user. If the winner is the user's real address, the caller records
# nothing and the reply is left alone.
#
#   account  => destination account (lowercase)
#   to, cc   => arrayrefs from parse_header_addresses
#   envelope => [ { address => ..., account => ... }, ... ] in RCPT order
#   resolve  => sub { address -> account or undef } (resolve_recipient-backed
#               in the daemon; a hash in tests)
#
# To:/Cc: addresses are resolved through `resolve`, NOT just matched against
# this transaction's envelope: Postfix may split one message's recipients
# over several transactions (a 451 on one RCPT, a retry), and every copy
# must reach the same answer.
#
# Returns { chosen, via ('to'|'cc'|'envelope'), candidates => [ {address, via}, ... ] }
# or undef when none of the user's addresses appears anywhere.
sub choose_reply_address {
    my (%a) = @_;
    my $account = lc($a{account} // '');
    return undef unless length $account;

    my %account_of;
    for my $r (@{ $a{envelope} // [] }) {
        $account_of{ lc($r->{address} // '') } = lc($r->{account} // '');
    }
    my $resolve = $a{resolve} // sub { undef };
    my $acct_of = sub {
        my ($addr) = @_;
        $account_of{$addr} = lc($resolve->($addr) // '') unless exists $account_of{$addr};
        return $account_of{$addr};
    };

    my (@cands, %seen);
    for my $via (qw(to cc)) {
        for my $addr (@{ $a{$via} // [] }) {
            $addr = lc $addr;
            next if $seen{$addr}++;
            next unless is_safe_address($addr);
            next unless $acct_of->($addr) eq $account;
            push @cands, { address => $addr, via => $via };
        }
    }
    for my $r (@{ $a{envelope} // [] }) {
        my $addr = lc($r->{address} // '');
        next if $seen{$addr}++;
        next unless lc($r->{account} // '') eq $account;
        push @cands, { address => $addr, via => 'envelope' };
    }
    return undef unless @cands;
    return { chosen => $cands[0]{address}, via => $cands[0]{via}, candidates => \@cands };
}

# Rebuild a single-mailbox address header (From, Reply-To, Sender) with the
# address swapped from $old to $new, keeping everything else -- in
# particular an encoded-word display name ("=?UTF-8?Q?...?=") byte for byte,
# which Email::Address::XS->format would re-quote and break. Rules:
#   * exactly one valid mailbox, whose address is $old -- else undef (the
#     caller leaves the header alone);
#   * a display name that IS or CONTAINS the real address is dropped (a
#     reply "permittivity@... <alias>" would leak what we are hiding);
#   * "Name <old>" -> "Name <new>" by substituting the bracketed token;
#   * a bare "old" -> "new";
#   * anything else is rebuilt from the parsed parts.
sub rewrite_address_header {
    my ($raw, $old, $new) = @_;
    return undef unless defined $raw && defined $old && defined $new;
    (my $v = $raw) =~ s/\r?\n[ \t]+/ /g;
    $v =~ s/^\s+|\s+$//g;

    my @parsed;
    my @groups = parse_email_groups($v);
    while (@groups) {
        my ($name, $addrs) = splice(@groups, 0, 2);
        push @parsed, @{ $addrs // [] };
    }
    return undef unless @parsed == 1 && $parsed[0]->is_valid;
    return undef unless lc($parsed[0]->address // '') eq lc $old;

    my $phrase = $parsed[0]->phrase;
    return $new if defined $phrase && index(lc $phrase, lc $old) >= 0;
    return $v   if $v =~ s/<\s*\Q$old\E\s*>/<$new>/i;
    return $new if lc($v) eq lc($old);
    return Email::Address::XS->new(phrase => $phrase, address => $new, comment => $parsed[0]->comment)->format;
}

sub reply_from_alias_enabled {
    my ($db, $account) = @_;
    my $row = $db->query(
        'SELECT reply_from_alias FROM domainadmin.mail_reply_identity WHERE user_email = ?', lc($account // ''),
    )->hash;
    return ($row && $row->{reply_from_alias}) ? 1 : 0;
}

# One row per (account, Message-ID); a second copy of the same message (N
# aliases in one transaction, or a retry) is a no-op. Returns rows inserted.
sub record_received_via {
    my ($db, %o) = @_;
    return $db->query(
        q{INSERT INTO domainadmin.mail_received_via (account, message_id, chosen, chosen_via, candidates)
          VALUES (?, ?, ?, ?, ?::jsonb) ON CONFLICT (account, message_id) DO NOTHING},
        lc $o{account}, $o{message_id}, lc $o{chosen}, $o{via}, $o{candidates_json},
    )->rows;
}

sub lookup_received_via {
    my ($db, $account, $message_id) = @_;
    my $row = $db->query(
        'SELECT chosen FROM domainadmin.mail_received_via WHERE account = ? AND message_id = ?',
        lc($account // ''), $message_id,
    )->hash;
    return $row ? lc $row->{chosen} : undef;
}

# The milter's own copy of Postfix's smtpd_sender_login_maps rule
# (postfix/config/pgsql-sender-login-maps.cf.template), restricted to one
# login: the login itself, or an active+send_enabled mail_aliases row whose
# destination is the login and whose source is the exact address or its
# '@domain' catch-all. Postfix checks that rule against the client's MAIL
# FROM BEFORE this milter runs and never re-checks after chgfrom, so this
# is the real boundary for what a reply may be rewritten to.
sub allowed_to_send_as {
    my ($db, $login, $address) = @_;
    $login   = lc($login   // '');
    $address = lc($address // '');
    return 0 unless length $login && length $address;
    return 1 if $login eq $address;
    my ($domain) = $address =~ /\@(.+)\z/;
    return 0 unless defined $domain && length $domain;
    my $row = $db->query(
        q{SELECT 1 AS ok FROM domainadmin.mail_aliases
          WHERE active = true AND send_enabled = true AND destination = ?
            AND (source_pattern = ? OR source_pattern = ?)
          LIMIT 1},
        $login, $address, '@' . $domain,
    )->hash;
    return $row ? 1 : 0;
}

# ===== the footer: block link + "Reply from the alias" line (0.2.2) ========
#
# A milter edits ONE body per transaction, shared by every recipient, so a
# per-account line can only be written when the transaction has exactly one
# destination account. With two accounts (a message to Jeff's alias and
# Kristine's) the line would have to name both choices -- one person's
# alias is nobody else's business -- so it is left out. Gardner, 2026-11-11.

# The envelope's recipients ([ { address, account }, ... ]) -> the single
# destination account they all resolve to, or undef when there are none or
# more than one.
sub single_account {
    my ($recipients) = @_;
    my %seen = map { lc($_->{account} // '') => 1 } @{ $recipients // [] };
    delete $seen{''};
    my @accounts = keys %seen;
    return @accounts == 1 ? $accounts[0] : undef;
}

# The one line a user sees under a message that came to one of their aliases
# while their switch is on. Starts with the setting's own name (findable in
# myaccount), names only the alias -- never the real address, the thing the
# feature hides -- and footers get forwarded.
sub reply_footer_line {
    my ($alias) = @_;
    return "Reply from the alias: a reply to this message goes out from $alias.";
}

# The text lines of the footer, in order: the reply line (if any) ABOVE the
# block link (if any). The caller adds the signature separator and the line
# endings its path needs (CRLF straight to replacebody, LF through
# Email::MIME).
sub footer_text_lines {
    my (%o) = @_;
    my @lines;
    push @lines, reply_footer_line($o{reply_alias}) if defined $o{reply_alias};
    push @lines, "Don't want mail like this? Manage blocked addresses: $o{block_url}" if defined $o{block_url};
    return @lines;
}

sub _html_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

# The same footer for text/html leaf parts: one muted block, one line per
# item, the reply line first. Returns undef when there is nothing to say.
sub footer_html {
    my (%o) = @_;
    my @lines;
    push @lines, _html_escape(reply_footer_line($o{reply_alias})) if defined $o{reply_alias};
    push @lines, qq{Don't want mail like this? <a href="} . _html_escape($o{block_url}) . qq{">Manage blocked addresses</a>}
        if defined $o{block_url};
    return undef unless @lines;
    return qq{<div style="margin-top:1em;padding-top:0.6em;border-top:1px solid #ccc;font-size:12px;color:#777;font-family:sans-serif">}
        . join('<br>', @lines) . '</div>';
}

1;
