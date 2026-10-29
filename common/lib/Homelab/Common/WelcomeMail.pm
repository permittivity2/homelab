package Homelab::Common::WelcomeMail;
use Mojo::Base -strict, -signatures;
use Homelab::Common::MailSetup qw(manual_setup_rows);
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(ready_email welcome_email);

# The two messages a new account triggers.
#
# This lived in homelab-invite until 2026-10-29, which was the right
# place while invite acceptance was the only thing that could create an
# account. It moved here when myaccount gained an admin action to RESEND
# these to an existing user: two packages composing the same message is
# exactly what this library is for, and the alternative -- a second copy
# in accountmanage -- is how the two drift until the resent mail quietly
# says something the original did not.
#
#   ready_email   -> the CONTACT address the invite was sent to (a Gmail,
#                    an Outlook, wherever they already read mail). This is
#                    the one that has existed all along; it used to be
#                    four lines of plain text saying the login exists.
#
#   welcome_email -> the NEW MAILBOX itself. This did not exist before,
#                    and its absence was conspicuous: a brand-new account
#                    opened for the first time showed an empty folder,
#                    which looks indistinguishable from a mailbox that is
#                    not receiving mail. It is also where the device-setup
#                    link belongs for the SECOND device, months later,
#                    since it stays in the mailbox the person already has.
#
# Both are multipart (see Homelab::Common::Mailer): the plain part is a
# real, complete message, not a "view this in HTML" stub. A good number of
# recipients will read exactly that part -- and a mail whose text
# alternative is a stub scores badly with spam filters, which is a poor
# trade for a message whose entire job is to arrive.
#
# NO QR CODE IS EMBEDDED. Gmail and Outlook both strip inline SVG, and a
# PNG attachment is blocked-by-default often enough to be unreliable. The
# mails carry a LINK; the page it opens carries the code. That also keeps
# the cross-device story correct -- someone reading this on a laptop
# follows the link and gets the code there.

sub _esc ($s) {
    $s //= '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

# Inline styles only, and a table for the button: Gmail strips <style>
# blocks, and Outlook ignores padding on an <a>.
sub _button ($href, $label) {
    return '' unless defined $href && length $href;
    return qq{<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:20px 0;">}
         . qq{<tr><td style="border-radius:6px;background:#1b1b1f;">}
         . qq{<a href="@{[_esc($href)]}" style="display:inline-block;padding:12px 22px;}
         . qq{font-family:Helvetica,Arial,sans-serif;font-size:15px;color:#ffffff;}
         . qq{text-decoration:none;border-radius:6px;">@{[_esc($label)]}</a>}
         . qq{</td></tr></table>};
}

sub _wrap ($inner) {
    return qq{<div style="font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.55;}
         . qq{color:#1b1b1f;max-width:34em;">$inner</div>};
}

sub _settings_text ($settings) {
    my $out = '';
    for my $r (@{ manual_setup_rows($settings) }) {
        my $note = length($r->[2] // '') ? " ($r->[2])" : '';
        $out .= sprintf("  %-26s %s%s\n", $r->[0] . ':', $r->[1], $note);
    }
    return $out;
}

sub _settings_html ($settings) {
    my $rows = '';
    for my $r (@{ manual_setup_rows($settings) }) {
        my $note = length($r->[2] // '')
            ? qq{<br><span style="color:#777;font-size:13px;">@{[_esc($r->[2])]}</span>} : '';
        $rows .= qq{<tr><td style="padding:3px 12px 3px 0;color:#555;white-space:nowrap;">}
               . _esc($r->[0]) . qq{</td><td style="padding:3px 0;font-family:monospace;">}
               . _esc($r->[1]) . qq{$note</td></tr>};
    }
    return qq{<table role="presentation" cellpadding="0" cellspacing="0" border="0" }
         . qq{style="font-size:14px;margin:8px 0 0;">$rows</table>};
}

# ready_email(account_email, settings, setup_url, login_url, webmail_url)
sub ready_email (%a) {
    my $email     = $a{account_email};
    my $settings  = $a{settings};
    my $setup_url = $a{setup_url};
    my $login_url = $a{login_url}   || 'https://myaccount.mailmasker.org/';
    my $webmail   = $a{webmail_url} || 'https://mail.mailmasker.org/';
    my $label     = $settings->{service_label} || 'MailMasker';
    # Comes from config, not from a user -- but it reaches the HTML by
    # interpolation, and "it is only config" is exactly the assumption
    # that turns into an injection the day something else writes config.
    my $elabel    = _esc($label);

    my $text = "Your $label account is ready.\n\n"
             . "Your login is: $email\n"
             . "Use the password you chose when you created the account.\n\n"
             . "Read your mail in a browser:\n  $webmail\n\n"
             . "Manage your account:\n  $login_url\n\n";

    if ($setup_url) {
        $text .= "Add this account to your iPhone, iPad or Mac in one tap:\n  $setup_url\n\n"
               . "Open that link on the device itself, or open it on a computer to get a\n"
               . "QR code you can scan with your phone's camera. You will be asked for your\n"
               . "password during setup -- the setup file never contains it.\n\n";
    }

    $text .= "Setting up a mail app by hand (Android, Thunderbird, Outlook):\n"
           . _settings_text($settings)
           . "\nChoose IMAP, not POP.\n";

    my $html = _wrap(
        qq{<p>Your $elabel account is ready.</p>}
      . qq{<p>Your login is <strong>@{[_esc($email)]}</strong>. Use the password you chose }
      . qq{when you created the account.</p>}
      . ($setup_url
          ? qq{<p><strong>Using an iPhone, iPad or Mac?</strong> Add this account to Mail in one tap.</p>}
            . _button($setup_url, 'Set up my device')
            . qq{<p style="font-size:13px;color:#555;">Open that on the device itself, or on a }
            . qq{computer to get a QR code to scan with your phone. You will be asked for your }
            . qq{password during setup &mdash; the setup file never contains it.</p>}
          : '')
      . qq{<p>Read your mail in a browser at <a href="@{[_esc($webmail)]}">@{[_esc($webmail)]}</a>, }
      . qq{or manage your account at <a href="@{[_esc($login_url)]}">@{[_esc($login_url)]}</a>.</p>}
      . qq{<p style="margin-top:24px;"><strong>Setting up a mail app by hand?</strong> }
      . qq{Choose IMAP, not POP, then:</p>}
      . _settings_html($settings)
    );

    return ("Your $label account is ready", $text, $html);
}

# welcome_email(account_email, settings, setup_url, ...) -- delivered INTO
# the new mailbox, so it is the first thing there.
sub welcome_email (%a) {
    my $email     = $a{account_email};
    my $settings  = $a{settings};
    my $setup_url = $a{setup_url};
    my $login_url = $a{login_url}   || 'https://myaccount.mailmasker.org/';
    my $webmail   = $a{webmail_url} || 'https://mail.mailmasker.org/';
    my $drive_url = $a{drive_url}   || 'https://drive.mailmasker.org/';
    my $label     = $settings->{service_label} || 'MailMasker';
    my $elabel    = _esc($label);

    my $text = "Welcome to $label.\n\n"
             . "This is $email -- your new mailbox. You are reading the first message in it.\n\n";

    if ($setup_url) {
        $text .= "GET THIS MAILBOX ON YOUR PHONE\n\n"
               . "  $setup_url\n\n"
               . "Open that on an iPhone or iPad and it sets up Mail in one tap. Open it on a\n"
               . "computer and you get a QR code to scan with your phone's camera. It also\n"
               . "has the settings for Android and desktop mail apps.\n\n"
               . "Keep this message -- that link is how you add your next device too.\n\n";
    }

    $text .= "WHAT ELSE YOU HAVE\n\n"
           . "  Webmail        $webmail\n"
           . "  File storage   $drive_url\n"
           . "  Your account   $login_url\n\n"
           . "From your account page you can change your password, see where you are signed\n"
           . "in, block senders, and invite other people.\n\n"
           . "MAIL APP SETTINGS\n\n"
           . _settings_text($settings)
           . "\nChoose IMAP, not POP.\n";

    my $html = _wrap(
        qq{<p style="font-size:18px;margin:0 0 16px;">Welcome to $elabel.</p>}
      . qq{<p>This is <strong>@{[_esc($email)]}</strong> &mdash; your new mailbox. You are reading }
      . qq{the first message in it.</p>}
      . ($setup_url
          ? qq{<p><strong>Get this mailbox on your phone.</strong></p>}
            . _button($setup_url, 'Set up my phone')
            . qq{<p style="font-size:13px;color:#555;">On an iPhone or iPad that sets up Mail in }
            . qq{one tap. On a computer it shows a QR code to scan with your phone's camera. }
            . qq{It also has the settings for Android and desktop mail apps.<br>}
            . qq{Keep this message &mdash; that link is how you add your next device too.</p>}
          : '')
      . qq{<p style="margin-top:24px;"><strong>What else you have</strong></p>}
      . qq{<ul style="padding-left:20px;margin:8px 0;">}
      . qq{<li>Webmail: <a href="@{[_esc($webmail)]}">@{[_esc($webmail)]}</a></li>}
      . qq{<li>File storage: <a href="@{[_esc($drive_url)]}">@{[_esc($drive_url)]}</a></li>}
      . qq{<li>Your account: <a href="@{[_esc($login_url)]}">@{[_esc($login_url)]}</a></li>}
      . qq{</ul>}
      . qq{<p style="font-size:14px;">From your account page you can change your password, see }
      . qq{where you are signed in, block senders, and invite other people.</p>}
      . qq{<p style="margin-top:24px;"><strong>Mail app settings</strong> &mdash; choose IMAP, not POP:</p>}
      . _settings_html($settings)
    );

    return ("Welcome to $label", $text, $html);
}

1;

__END__

=head1 NAME

Homelab::Common::WelcomeMail - the two messages a newly created account triggers

=cut
