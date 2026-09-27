package Homelab::SSO::Mailer;
use Mojo::Base -strict, -signatures;
use Net::SMTP;
use Mojo::Date;
use Mojo::Util qw(sha1_sum);
use Exporter 'import';

our @EXPORT_OK = qw(send_mail);

# Password-reset email sender. Ported near-verbatim from
# homelab-invite's own Mailer (the second place in this codebase that
# sends mail with no logged-in human behind it) -- a real api.users
# service-account identity (config.yml's mailer.email, created via
# `homelab-cli admin users create-service-account`), authenticating with
# a stored password over real STARTTLS+AUTH SMTP submission. Explicitly
# NOT an unauthenticated loopback relay: homelab-postfix's mynetworks is
# 127.0.0.0/8 only and correctly rejects unauthenticated relay to
# external recipients (a reset email goes to a user's external recovery
# address by definition), so a real authenticated identity is required.
# A deliberate ~50-line duplication rather than a shared
# Homelab::Common::Mailer, per this project's own precedent: pulling it
# into homelab-common would force a rebuild+reinstall of homelab-common
# and a restart of every dependent service for a change to one caller.
#
# %opts: smtp_host, smtp_port, from_email, from_password, to, subject,
# body. Dies on any failure -- callers wrap in eval.
sub send_mail {
    my (%opts) = @_;
    my ($smtp_host, $smtp_port, $email, $password, $to, $subject, $body)
        = @opts{qw(smtp_host smtp_port from_email from_password to subject body)};

    my $smtp = Net::SMTP->new($smtp_host, Port => $smtp_port, Timeout => 15)
        or die "SMTP connect failed\n";
    $smtp->hello('homelab-sso');
    $smtp->starttls(SSL_verify_mode => 0) or die "STARTTLS failed\n";
    $smtp->hello('homelab-sso');
    $smtp->auth($email, $password) or die 'SMTP auth failed: ' . $smtp->message . "\n";

    my $date  = Mojo::Date->new(time)->to_string;
    my $msgid = '<' . sha1_sum(time . $$ . rand()) . '@homelab-sso>';
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
