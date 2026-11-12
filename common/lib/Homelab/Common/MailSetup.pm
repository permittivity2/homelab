package Homelab::Common::MailSetup;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(mail_settings manual_setup_rows);

# One answer to "what do I type into my mail app?", shared by every place
# that answers it.
#
# Three surfaces show these numbers: the Apple profile (machine-read), the
# manual-settings table for Android/Thunderbird/Outlook (human-read), and
# the plain-text copy inside the welcome emails. They are the same three
# facts each time, and the failure mode when they drift is miserable to
# diagnose -- a user whose phone "just won't connect" because the table on
# the page says 143 while the profile says 993, with no error that points
# at the discrepancy. So the settings are resolved ONCE, here, and the
# profile builder and the table are both fed from the result.
#
# The defaults are derived from the mailbox domain (mail.<domain>,
# smtp.<domain>) because that is what this fleet's certificate actually
# carries as SANs. A host that is reachable but not on the certificate
# produces a TLS name mismatch, which on iOS surfaces as an unexplained
# "Cannot Verify Server Identity" -- so overriding these in config means
# checking the certificate too.

# mail_settings(email => ..., config => $device_setup_hashref)
sub mail_settings (%opts) {
    my $email = $opts{email} // die "mail_settings: email is required\n";
    die "mail_settings: email does not look like an address\n" unless $email =~ /\@/;
    my $cfg = $opts{config} // {};
    my ($domain) = $email =~ /\@(.+)$/;

    # `||` not `//` throughout: these come out of YAML, where a key left
    # present but blank (which the shipped example config does on
    # purpose, to mean "derive it") parses as an empty string, not undef.
    return {
        email         => $email,
        username      => $email,
        domain        => $domain,
        imap_host     => ($cfg->{imap_host} || "mail.$domain"),
        imap_port     => ($cfg->{imap_port} || 993),
        smtp_host     => ($cfg->{smtp_host} || "smtp.$domain"),
        smtp_port     => ($cfg->{smtp_port} || 587),
        service_label => ($cfg->{service_label} || 'MailMasker'),
        organization  => ($cfg->{organization}  || 'Silver Linings, LLC'),
        webmail_url   => ($cfg->{webmail_url}   || ''),
        myaccount_url => ($cfg->{myaccount_url} || ''),
    };
}

# Rows for the manual-settings table: [label, value, note].
#
# The security wording is spelled out rather than left as a port number
# because this table exists for the people who are NOT using the one-tap
# profile -- Android and desktop clients, where picking "SSL/TLS" versus
# "STARTTLS" from a dropdown is the single most common way a setup
# silently ends up unencrypted.
#
# The outgoing port has an alternative row (post-cutover #70): the pool
# serves submission on 587 (STARTTLS) and 465 (implicit TLS) alike, and
# the single most common sending failure was a client set to "SSL/TLS" on
# 587 -- or "STARTTLS" on 465 -- so whichever port is configured as the
# primary, the table names the other one with its own encryption word.
# The Apple profile keeps the primary port only (iOS picks the mechanism
# from the port, see AppleProfile.pm).
sub manual_setup_rows ($s) {
    my @alt = $s->{smtp_port} == 587 ? ([465, 'SSL/TLS', 'STARTTLS'])
            : $s->{smtp_port} == 465 ? ([587, 'STARTTLS', 'SSL/TLS'])
            : ();
    return [
        ['Email address', $s->{email},     ''],
        ['Username',      $s->{username},  'the full address, not just the part before the @'],
        ['Password',      '(your mailbox password)', ''],
        ['Incoming (IMAP) server', $s->{imap_host}, ''],
        ['Incoming port', $s->{imap_port},
            $s->{imap_port} == 993 ? 'SSL/TLS' : ($s->{imap_port} == 143 ? 'STARTTLS' : '')],
        ['Outgoing (SMTP) server', $s->{smtp_host}, ''],
        ['Outgoing port', $s->{smtp_port},
            $s->{smtp_port} == 465 ? 'SSL/TLS' : ($s->{smtp_port} == 587 ? 'STARTTLS' : '')],
        (@alt ? (['Outgoing port, alternative', $alt[0][0],
            "$alt[0][1] — both ports work; use this one if your app offers no $alt[0][2] option"]) : ()),
        ['Outgoing authentication', 'Yes — same username and password', ''],
    ];
}

1;

__END__

=head1 NAME

Homelab::Common::MailSetup - the one source of IMAP/SMTP client settings

=head1 SYNOPSIS

    use Homelab::Common::MailSetup qw(mail_settings manual_setup_rows);

    my $s    = mail_settings(email => $email, config => $cfg->{device_setup});
    my $rows = manual_setup_rows($s);

=cut
