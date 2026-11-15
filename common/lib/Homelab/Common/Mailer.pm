package Homelab::Common::Mailer;
use Mojo::Base -strict, -signatures;
use Net::SMTP;
use Mojo::Date;
use Mojo::Util qw(sha1_sum);
use MIME::Base64 qw(encode_base64);
use Encode ();
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(send_mail);

# Authenticated SMTP submission for services that have no human behind the
# send -- invites, share notifications, and whatever comes next.
#
# This lives in common because it is now wanted by more than one package.
# homelab-invite has carried its own copy since before this existed; that
# copy is the ancestor of this one and should be retired in favour of it
# (tracked as a follow-up) -- NOT because duplication is untidy, but because
# this codebase has been bitten repeatedly by a lesson learned in one copy
# and never applied to the other. The SMTP-host warning below is exactly
# such a lesson.
#
# THE HOST MUST BE A SUBMISSION ENDPOINT THAT ACCEPTS A PLAIN CONNECTION --
# the edge HAProxy submission frontend (the fleet's internal mail VIP), NOT a
# postfix submission backend and NOT loopback. The backends carry
# smtpd_upstream_proxy_protocol=haproxy, so their :587 requires a PROXY
# header a direct client cannot send; point at one and every send fails with
# "421 4.3.0 <host> Server local error" while the UI shows nothing at all.
# That is not hypothetical: it is what had homelab-invite silently failing
# until 2026-10-28.
#
# Explicitly NOT an unauthenticated loopback relay either: homelab-postfix's
# mynetworks is 127.0.0.0/8 only and correctly refuses unauthenticated relay
# to external recipients, which share/invite recipients are by definition.
#
# %opts: smtp_host, smtp_port, from_email, from_password, to, subject, body,
#        and optionally html, reply_to, calendar.
#
# `html` makes the message multipart/alternative, with `body` as the
# text/plain alternative. Both parts are required in that case, and the
# plain one is not a formality: it is what a text-only client, a screen
# reader, and a spam filter all read, and a message whose plain part is
# "please view this in HTML" is one that scores badly and reads worse.
#
# `calendar` => { method => 'REQUEST'|'CANCEL'|'REPLY', ics => $text } makes
# an iTIP message (RFC 6047; homelab-calendar's invitations): the shape
# Google's own invitations have, which is what every mail program's
# Yes/Maybe/No buttons are tuned to -- multipart/mixed holding a
# multipart/alternative of text/plain [+ text/html] + text/calendar with the
# method in the content type, then the same iCalendar once more as an
# application/ics attachment for the clients (Outlook) that read that one.
#
# `reply_to` sets a Reply-To header (an invitation's replies belong to the
# organizer, not to the service mailbox that sent it).
#
# Dies on any failure -- callers wrap this in their own eval, the same
# fail-loud-not-silent convention every other cross-service call here uses.
sub send_mail {
    my (%opts) = @_;
    my ($smtp_host, $smtp_port, $email, $password, $to, $subject, $body)
        = @opts{qw(smtp_host smtp_port from_email from_password to subject body)};
    my $html = $opts{html};

    die "send_mail: smtp_host is required\n"  unless defined $smtp_host  && length $smtp_host;
    die "send_mail: from_email is required\n" unless defined $email      && length $email;
    die "send_mail: to is required\n"         unless defined $to         && length $to;

    my $smtp = Net::SMTP->new($smtp_host, Port => ($smtp_port || 587), Timeout => 15)
        or die "SMTP connect to $smtp_host failed\n";
    $smtp->hello('homelab');
    $smtp->starttls(SSL_verify_mode => 0) or die "STARTTLS failed\n";
    # A second EHLO after STARTTLS is required, not belt-and-braces: the
    # server's capability list (AUTH in particular) is only trustworthy on
    # the encrypted channel, and Net::SMTP caches what it saw first.
    $smtp->hello('homelab');
    $smtp->auth($email, $password) or die 'SMTP auth failed: ' . $smtp->message . "\n";

    my $raw = _build_message(
        from => $email, to => $to, subject => $subject, body => $body, html => $html,
        reply_to => $opts{reply_to}, calendar => $opts{calendar},
    );

    $smtp->mail($email)                  or die 'MAIL FROM rejected: ' . $smtp->message . "\n";
    $smtp->to($to)                       or die 'RCPT TO rejected: '   . $smtp->message . "\n";
    $smtp->data()                        or die 'DATA rejected: '      . $smtp->message . "\n";
    $smtp->datasend($raw);
    $smtp->dataend()                     or die 'message rejected: '   . $smtp->message . "\n";
    $smtp->quit;
    return 1;
}

# Assemble the on-the-wire message. Split out from send_mail so the MIME
# shape can be unit-tested without an SMTP server -- a malformed boundary
# or a missing CRLF is otherwise only discoverable by looking at a real
# inbox, which is a slow way to find out.
sub _build_message {
    my (%a) = @_;
    my ($from, $to, $subject, $body, $html) = @a{qw(from to subject body html)};

    my $date  = Mojo::Date->new(time)->to_string;
    my $msgid = '<' . sha1_sum(time . $$ . rand()) . '@homelab>';
    my $head  = "From: $from\r\nTo: $to\r\n"
              . (defined $a{reply_to} && length $a{reply_to} ? "Reply-To: $a{reply_to}\r\n" : '')
              . "Subject: " . _header_text($subject) . "\r\nDate: $date\r\n"
              . "Message-ID: $msgid\r\nMIME-Version: 1.0\r\n";

    # An iTIP message (an invitation, a cancellation): see send_mail.
    if (ref $a{calendar} eq 'HASH' && defined $a{calendar}{ics} && length $a{calendar}{ics}) {
        my $method = ($a{calendar}{method} // 'REQUEST') =~ /\A(?:REQUEST|CANCEL|REPLY|PUBLISH)\z/ ? $a{calendar}{method} : 'REQUEST';
        my $ics = $a{calendar}{ics};
        my $outer = '=_homelab_m_' . sha1_sum($msgid . rand()) . '_=';
        my $inner = '=_homelab_a_' . sha1_sum($msgid . rand()) . '_=';
        return $head
             . qq{Content-Type: multipart/mixed; boundary="$outer"\r\n\r\n}
             . "This is a message in MIME format.\r\n"
             . "--$outer\r\n"
             . qq{Content-Type: multipart/alternative; boundary="$inner"\r\n\r\n}
             . "--$inner\r\n" . _part('text/plain; charset=UTF-8', $body)
             . (defined $html && length $html ? "--$inner\r\n" . _part('text/html; charset=UTF-8', $html) : '')
             . "--$inner\r\n" . _part("text/calendar; charset=UTF-8; method=$method", $ics)
             . "--$inner--\r\n"
             . "--$outer\r\n"
             . qq{Content-Type: application/ics; name="invite.ics"\r\n}
             . qq{Content-Disposition: attachment; filename="invite.ics"\r\n}
             . "Content-Transfer-Encoding: base64\r\n\r\n"
             . encode_base64(Encode::encode('UTF-8', $ics), "\r\n") . "\r\n"
             . "--$outer--\r\n";
    }

    if (defined $html && length $html) {
        # Boundary from the same entropy as the Message-ID. It must not
        # occur anywhere in either part; a random 40-hex string inside a
        # fixed delimiter will not.
        my $b = '=_homelab_' . sha1_sum($msgid . rand()) . '_=';
        return $head
             . qq{Content-Type: multipart/alternative; boundary="$b"\r\n\r\n}
             . "This is a message in MIME format.\r\n"
             . "--$b\r\n" . _part('text/plain; charset=UTF-8', $body)
             . "--$b\r\n" . _part('text/html; charset=UTF-8',  $html)
             . "--$b--\r\n";
    }

    # Unchanged from the plain-text-only original, deliberately: every
    # existing caller's mail keeps exactly the bytes it had.
    return $head . "Content-Type: text/plain; charset=UTF-8\r\n\r\n$body";
}

# A header value: as it is when it is ASCII, else RFC 2047 encoded-words
# (an event's title in a Subject may carry anything).
sub _header_text {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\r\n]+/ /g;
    return $s unless $s =~ /[^\x20-\x7e]/;
    my $b64 = encode_base64(Encode::encode('UTF-8', $s), '');
    return "=?UTF-8?B?$b64?=";
}

# One MIME part, base64-encoded. Base64 rather than 8bit because SMTP caps
# a line at 998 octets and HTML written as a here-doc routinely exceeds
# that; an over-long line is either refused or silently rewrapped in the
# middle of a tag. It also sidesteps dot-stuffing and any UTF-8 the
# transport might not be clean for.
sub _part {
    my ($content_type, $content) = @_;
    my $b64 = encode_base64(Encode::encode('UTF-8', $content), "\r\n");
    return "Content-Type: $content_type\r\n"
         . "Content-Transfer-Encoding: base64\r\n\r\n"
         . $b64 . "\r\n";
}

1;

__END__

=head1 NAME

Homelab::Common::Mailer - authenticated SMTP submission for unattended sends

=cut
