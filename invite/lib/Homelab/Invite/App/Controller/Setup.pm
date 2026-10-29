package Homelab::Invite::App::Controller::Setup;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AppleProfile qw(build_mail_profile profile_filename);
use Homelab::Common::MailSetup qw(mail_settings manual_setup_rows);
use Homelab::Common::QRCode qw(qr_svg);
use Homelab::Common::SetupToken qw(verify_setup_token);

# The "add this mailbox to your phone" pages, served PUBLICLY (no login)
# on the same invite.<domain> vhost as the acceptance flow.
#
# WHY THESE ARE PUBLIC. The moment that matters is the thirty seconds
# after an account is created, and the device it has to end up on is a
# phone that has never signed in anywhere. Requiring a login first would
# mean the new user's very first act is typing a password they chose
# sixty seconds ago into a mail client they have not configured yet. So
# the URL carries its own authority instead, as a signed expiring token
# (Homelab::Common::SetupToken).
#
# WHAT THE TOKEN IS WORTH. It names a mailbox. The page and the profile
# it serves contain an email address and two public hostnames; the
# profile deliberately carries no password (see
# Homelab::Common::AppleProfile). So a leaked link discloses roughly what
# an MX record and a guessable username already would, and grants nothing.
# It is still expiring and still signed, because "roughly nothing" is not
# "nothing" and there is no cost to bounding it.
#
# The same three pages exist, session-authenticated instead of
# token-authenticated, in homelab-accountmanage -- that is where someone
# goes months later when they get a second phone.

sub _device_config ($c) { return $c->app->invite_config->{device_setup} // {} }

# What kind of device is reading this page? Used only to decide what to
# show FIRST -- every option stays on the page whatever the answer, so a
# wrong guess costs a scroll, never a dead end. (That is also why this is
# a plain User-Agent sniff and not something cleverer: the cost of being
# wrong is bounded by design.)
sub _device_hints ($c) {
    my $ua = $c->req->headers->user_agent // '';
    my $ios = $ua =~ /\b(?:iPhone|iPad|iPod)\b/ ? 1 : 0;
    my $mac = (!$ios && $ua =~ /\bMacintosh\b/) ? 1 : 0;
    # Chrome, Firefox and Edge on iOS are all WebKit underneath and all
    # claim Safari in their UA -- they are told apart by their own
    # marker. This matters more than it looks: iOS will only hand a
    # configuration profile to Settings when it was downloaded in Safari
    # itself. In any other iOS browser the file downloads and then simply
    # cannot be opened, with nothing on screen explaining why.
    my $other_ios_browser = $ua =~ /\b(?:CriOS|FxiOS|EdgiOS|OPiOS|Chrome)\b/ ? 1 : 0;
    return {
        is_ios        => $ios,
        is_mac        => $mac,
        is_apple      => ($ios || $mac) ? 1 : 0,
        needs_safari  => ($ios && $other_ios_browser) ? 1 : 0,
    };
}

# The signing secret, or undef when this install has not got one. undef
# disables the whole feature rather than failing: an account that works
# without a setup link is much better than a service that will not start.
#
# The key is SHARED ACROSS THE POOL via the database -- see App.pm's
# device_setup_secret helper for why that is not optional here.
sub _secret ($c) { return $c->device_setup_secret }

# Shared by all three routes: turn ?t= into a mailbox, or reject and
# return undef.
#
# $mode decides what the rejection LOOKS like, which matters because
# these three routes are consumed very differently. A browser following
# a stale link wants a page it can read; a download of a .mobileconfig
# wants a short plain refusal (a themed HTML page saved as a
# .mobileconfig file is worse than useless); an <img> on a page that is
# otherwise fine wants nothing at all rather than a broken-image icon.
sub _subject_or_reject ($c, $mode) {
    my $secret = _secret($c);
    my $email  = $secret && verify_setup_token(
        secret => $secret, purpose => 'mail-device-setup', token => scalar $c->param('t'),
    );
    return $email if $email;

    # Deliberately one message for every failure -- expired, forged,
    # truncated by a mail client that mangled the URL. The user's next
    # action is the same in all of them, and naming which one it was only
    # helps someone probing.
    my $my = _device_config($c)->{myaccount_url} || 'https://myaccount.mailmasker.org/';
    if ($mode eq 'page') {
        $c->render(template => 'notice', heading => 'Setup link expired',
            body => 'This setup link has expired. Sign in at ' . $my
                  . ' and open "Mail setup" to add your account to another device.',
            format => 'html', status => 410);
    }
    elsif ($mode eq 'text') {
        $c->res->headers->content_type('text/plain; charset=UTF-8');
        $c->render(data => "This setup link has expired.\nSign in at $my and open "
                         . qq{"Mail setup" to add your account to another device.\n},
            status => 410);
    }
    else {
        $c->render(data => '', status => 410);
    }
    return undef;
}

# GET /setup/mail?t=...
sub page ($c) {
    my $email = _subject_or_reject($c, 'page') or return;
    my $s = mail_settings(email => $email, config => _device_config($c));

    # The QR encodes THIS page's own URL, not the profile's. Two reasons,
    # and the second is the important one: scanning straight into a
    # download gives no chance to explain what is about to happen, and
    # iOS will only install a configuration profile downloaded in SAFARI
    # -- a code scanned on a phone whose default browser is Chrome
    # downloads a file that then cannot be opened, with no explanation.
    # Landing on a page means that case can be detected and said out loud.
    my $base = $c->app->invite_config->{public_base_url} // '';
    $base =~ s{/+$}{};
    my $self_url = $base . '/setup/mail?t=' . $c->param('t');

    return $c->render(
        template     => 'setup',
        email        => $email,
        settings     => $s,
        manual_rows  => manual_setup_rows($s),
        profile_url  => '/setup/mail/apple.mobileconfig?t=' . $c->param('t'),
        qr_url       => '/setup/mail/qr.svg?t=' . $c->param('t'),
        self_url     => $self_url,
        hints        => _device_hints($c),
        webmail_url  => ($s->{webmail_url}   || 'https://mail.mailmasker.org/'),
        myaccount_url=> ($s->{myaccount_url} || 'https://myaccount.mailmasker.org/'),
    );
}

# GET /setup/mail/apple.mobileconfig?t=...
sub apple_profile ($c) {
    my $email = _subject_or_reject($c, 'text') or return;
    my $s = mail_settings(email => $email, config => _device_config($c));

    my $xml = build_mail_profile(
        email         => $email,
        imap_host     => $s->{imap_host}, imap_port => $s->{imap_port},
        smtp_host     => $s->{smtp_host}, smtp_port => $s->{smtp_port},
        account_label => $s->{service_label},
        organization  => $s->{organization},
        display_name  => $email,
    );

    # application/x-apple-aspen-config is the type that makes iOS hand the
    # file to the profile installer instead of showing it as text. Serving
    # correct XML under the wrong type is the classic way this feature
    # looks finished and does nothing.
    $c->res->headers->content_type('application/x-apple-aspen-config');
    $c->res->headers->content_disposition(
        'attachment; filename="' . profile_filename($email, $s->{service_label}) . '"');
    # The URL embeds a capability token; no shared cache should keep the
    # response, and no browser should serve it to the next person.
    $c->res->headers->cache_control('no-store, private');
    return $c->render(data => $xml);
}

# GET /setup/mail/qr.svg?t=...
#
# NOT named `qr`: that is the quote-regex builtin, and while Mojolicious
# dispatches it as a method regardless, a sub shadowing an operator in
# this package is a trap for whoever next writes a regex in it.
sub qr_code ($c) {
    my $email = _subject_or_reject($c, 'empty') or return;
    my $base = $c->app->invite_config->{public_base_url} // '';
    $base =~ s{/+$}{};
    my $svg = qr_svg($base . '/setup/mail?t=' . $c->param('t'),
        module => 6, title => "Mail setup for $email");
    # No code means Text::QRCode is not installed on this host. 404 lets
    # the page's <img> fail quietly next to the link that always works,
    # rather than taking the whole page down with it.
    return $c->render(data => '', status => 404) unless $svg;

    $c->res->headers->content_type('image/svg+xml');
    $c->res->headers->cache_control('no-store, private');
    return $c->render(data => $svg);
}

1;
