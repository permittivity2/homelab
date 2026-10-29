use v5.36;
use Test::More;
use Test::Mojo;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../common/lib";

BEGIN {
    plan skip_all => 'homelab-common not available'
        unless eval { require Homelab::Common::SetupToken; 1 };
}

use Homelab::Common::SetupToken qw(issue_setup_token);

# The device-setup routes, exercised against a stand-in Mojolicious app.
#
# NOT the real Homelab::Invite::App: that one needs a config file, a
# Postgres connection and a reachable homelab-api before it will start
# (t/basic.t is the integration test that provides all three). These
# routes need none of it -- they read a config hash and a signed token
# and nothing else -- so this mounts the real controller on a minimal
# app and tests it for real, in CI, with no infrastructure.

my $SECRET = 'test-setup-secret-0123456789abcdef';
my $EMAIL  = 'johnboy002@mailmasker.org';

{
    package TestSetupApp;
    use Mojo::Base 'Mojolicious', -signatures;
    has 'invite_config';
    sub startup ($self) {
        $self->invite_config({
            public_base_url => 'https://invite.mailmasker.org',
            device_setup => {
                token_secret  => $SECRET,
                service_label => 'MailMasker',
                myaccount_url => 'https://myaccount.mailmasker.org/',
            },
        });
        # The real app resolves this from invite.app_secrets so every node
        # in the pool agrees (see App.pm). Here it just returns what the
        # config holds -- the controller only ever asks for the key.
        $self->helper(device_setup_secret => sub ($c) {
            my $s = $self->invite_config->{device_setup}{token_secret};
            return undef unless defined $s && length $s && $s !~ /^YOUR_/;
            return $s;
        });
        my $r = $self->routes;
        $r->namespaces(['Homelab::Invite::App::Controller']);
        $r->get('/setup/mail')                    ->to('setup#page');
        $r->get('/setup/mail/apple.mobileconfig') ->to('setup#apple_profile');
        $r->get('/setup/mail/qr.svg')             ->to('setup#qr_code');
    }
}

my $t = Test::Mojo->new('TestSetupApp');
my $good = issue_setup_token(secret => $SECRET, purpose => 'mail-device-setup',
                             subject => $EMAIL, ttl => 600);

subtest 'the profile is served as an Apple configuration profile' => sub {
    $t->get_ok("/setup/mail/apple.mobileconfig?t=$good")
      ->status_is(200)
      # The single most important header here. Correct XML under the
      # wrong content type is a feature that looks finished and does
      # nothing -- iOS shows it as text instead of offering to install it.
      ->header_is('Content-Type' => 'application/x-apple-aspen-config')
      ->header_like('Content-Disposition' => qr/attachment; filename="[^"]+\.mobileconfig"/)
      # The URL carries a capability token; nothing downstream should
      # keep the response or hand it to the next person on a shared machine.
      ->header_like('Cache-Control' => qr/no-store/)
      ->content_like(qr/<key>EmailAddress<\/key>\s*<string>\Q$EMAIL\E<\/string>/)
      ->content_like(qr/com\.apple\.mail\.managed/);
};

subtest 'the token is what authorises it' => sub {
    # No session, no login: the token IS the authorisation, so these
    # cases are the entire access control for this route.
    for my $bad ('', 'garbage', "$good-tampered", substr($good, 0, -4)) {
        $t->get_ok('/setup/mail/apple.mobileconfig?t=' . $bad)
          ->status_is(410, "rejected: '" . (length $bad ? substr($bad, 0, 18) : '(empty)') . "'")
          ->header_like('Content-Type' => qr{^text/plain})
          ->content_unlike(qr/\Q$EMAIL\E/, 'a rejection never leaks the address');
    }
    $t->get_ok('/setup/mail/apple.mobileconfig')->status_is(410, 'no token at all');
};

subtest 'an expired token stops working' => sub {
    my $old = issue_setup_token(secret => $SECRET, purpose => 'mail-device-setup',
        subject => $EMAIL, ttl => 1, now => time - 100);
    $t->get_ok("/setup/mail/apple.mobileconfig?t=$old")->status_is(410);
};

subtest 'a token minted for another feature is not accepted here' => sub {
    # Domain separation inside one secret: if some future feature on this
    # service issues its own tokens, they must not open mailboxes.
    my $other = issue_setup_token(secret => $SECRET, purpose => 'something-else',
        subject => $EMAIL, ttl => 600);
    $t->get_ok("/setup/mail/apple.mobileconfig?t=$other")->status_is(410);
};

subtest 'the QR code points at the setup page, not the profile' => sub {
    plan skip_all => 'Text::QRCode not installed' unless eval { require Text::QRCode; 1 };
    $t->get_ok("/setup/mail/qr.svg?t=$good")
      ->status_is(200)
      ->header_is('Content-Type' => 'image/svg+xml')
      ->content_like(qr/^<svg /)
      ->content_like(qr/viewBox=/);

    # Scanning straight into a .mobileconfig download breaks on any iOS
    # device whose default browser is not Safari -- the file downloads
    # and then cannot be opened, with nothing explaining why. The code
    # has to land on a page that can say so.
    my $body = $t->tx->res->body;
    unlike $body, qr/mobileconfig/, 'the SVG does not encode a direct profile download';

    $t->get_ok('/setup/mail/qr.svg?t=nonsense')->status_is(410)->content_is('');
};

subtest 'no signing secret means the feature is simply off' => sub {
    # An upgrade from a version predating this feature has no
    # device_setup block. That must disable the links, not break the
    # service or -- worse -- serve profiles to unsigned URLs.
    my $t2 = Test::Mojo->new('TestSetupApp');
    $t2->app->invite_config({ public_base_url => 'https://x', device_setup => {} });
    $t2->get_ok("/setup/mail/apple.mobileconfig?t=$good")->status_is(410);

    # The placeholder straight out of the shipped example config must
    # also count as "no secret" -- otherwise every install that skipped
    # the postinst would share one publicly known signing key.
    my $t3 = Test::Mojo->new('TestSetupApp');
    $t3->app->invite_config({ public_base_url => 'https://x',
        device_setup => { token_secret => 'YOUR_SETUP_TOKEN_SECRET_HERE' } });
    my $placeholder_token = issue_setup_token(secret => 'YOUR_SETUP_TOKEN_SECRET_HERE',
        purpose => 'mail-device-setup', subject => $EMAIL, ttl => 600);
    $t3->get_ok("/setup/mail/apple.mobileconfig?t=$placeholder_token")->status_is(410);
};

subtest 'the page renders' => sub {
    # Needs homelab-webtheme, which supplies the shared layout partials
    # and is not installed in CI.
    plan skip_all => 'homelab-webtheme not installed'
        unless eval { require Homelab::WebTheme; 1 };
    $t->app->renderer->paths([ "$FindBin::Bin/../templates", @{ $t->app->renderer->paths } ]);
    $t->app->plugin('Homelab::WebTheme' => { app_name => '', menu_links => [] });
    $t->get_ok("/setup/mail?t=$good")
      ->status_is(200)
      ->content_like(qr/\Q$EMAIL\E/)
      ->content_like(qr/mail\.mailmasker\.org/)
      ->content_like(qr/smtp\.mailmasker\.org/)
      ->content_like(qr/IMAP/);
};

done_testing();
