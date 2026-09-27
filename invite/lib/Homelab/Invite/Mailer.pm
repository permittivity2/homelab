package Homelab::Invite::Mailer;
use Mojo::Base -strict, -signatures;
use Net::SMTP;
use Mojo::Date;
use Mojo::Util qw(sha1_sum);
use Exporter 'import';

our @EXPORT_OK = qw(send_mail);

# The one genuinely new mail-sending path in this codebase: every other
# send (mailbridge, Roundcube's own native deliver_message()) is a real
# logged-in human's OAuth-authenticated session. This has no human
# behind it -- a real api.users identity (config.yml's mailer.email),
# created once via `homelab-cli admin users create-service-account`,
# authenticating with a plain stored password over real SMTP
# submission, same STARTTLS + AUTH + MAIL/RCPT/DATA shape
# homelab-mailbridge's own send_message uses, just AUTH PLAIN (Net::
# SMTP's built-in ->auth, via Authen::SASL) instead of a hand-rolled
# XOAUTH2 string -- there's no OAuth token to build one from here.
# Explicitly NOT an unauthenticated loopback relay: homelab-postfix's
# own mynetworks is 127.0.0.0/8 only and correctly rejects
# unauthenticated relay to any external recipient (confirmed live, see
# postfix/README.md) -- invite recipients are external by definition,
# so a real authenticated identity is required regardless.
#
# %opts: smtp_host, smtp_port, from, to, subject, body. Dies on any
# failure -- callers wrap this in their own eval, same convention as
# every other cross-service call in this codebase (fail loud, not
# silent-best-effort).
sub send_mail {
    my (%opts) = @_;
    my ($smtp_host, $smtp_port, $email, $password, $to, $subject, $body)
        = @opts{qw(smtp_host smtp_port from_email from_password to subject body)};

    my $smtp = Net::SMTP->new($smtp_host, Port => $smtp_port, Timeout => 15)
        or die "SMTP connect failed\n";
    $smtp->hello('homelab-invite');
    $smtp->starttls(SSL_verify_mode => 0) or die "STARTTLS failed\n";
    $smtp->hello('homelab-invite');
    $smtp->auth($email, $password) or die 'SMTP auth failed: ' . $smtp->message . "\n";

    my $date  = Mojo::Date->new(time)->to_string;
    my $msgid = '<' . sha1_sum(time . $$ . rand()) . '@homelab-invite>';
    my $raw   = "From: $email\r\nTo: $to\r\nSubject: $subject\r\nDate: $date\r\n"
              . "Message-ID: $msgid\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n$body";

    $smtp->mail($email) or die "MAIL FROM failed\n";
    $smtp->to($to)      or die "RCPT TO failed\n";
    $smtp->data         or die "DATA failed\n";
    $smtp->datasend($raw) or die "datasend failed\n";
    $smtp->dataend      or die "dataend failed\n";
    $smtp->quit;
    return 1;
}

1;
