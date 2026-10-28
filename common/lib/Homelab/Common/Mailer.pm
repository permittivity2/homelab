package Homelab::Common::Mailer;
use Mojo::Base -strict, -signatures;
use Net::SMTP;
use Mojo::Date;
use Mojo::Util qw(sha1_sum);
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
# %opts: smtp_host, smtp_port, from_email, from_password, to, subject, body.
# Dies on any failure -- callers wrap this in their own eval, the same
# fail-loud-not-silent convention every other cross-service call here uses.
sub send_mail {
    my (%opts) = @_;
    my ($smtp_host, $smtp_port, $email, $password, $to, $subject, $body)
        = @opts{qw(smtp_host smtp_port from_email from_password to subject body)};

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

    my $date  = Mojo::Date->new(time)->to_string;
    my $msgid = '<' . sha1_sum(time . $$ . rand()) . '@homelab>';
    my $raw   = "From: $email\r\nTo: $to\r\nSubject: $subject\r\nDate: $date\r\n"
              . "Message-ID: $msgid\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n$body";

    $smtp->mail($email)                  or die 'MAIL FROM rejected: ' . $smtp->message . "\n";
    $smtp->to($to)                       or die 'RCPT TO rejected: '   . $smtp->message . "\n";
    $smtp->data()                        or die 'DATA rejected: '      . $smtp->message . "\n";
    $smtp->datasend($raw);
    $smtp->dataend()                     or die 'message rejected: '   . $smtp->message . "\n";
    $smtp->quit;
    return 1;
}

1;

__END__

=head1 NAME

Homelab::Common::Mailer - authenticated SMTP submission for unattended sends

=cut
