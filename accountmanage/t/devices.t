use Mojo::Base -strict, -signatures;
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
# Loads the controller package. Does not start the app -- the real one
# needs a config file, an SSO client and a reachable homelab-api, none of
# which these routes touch.
require Homelab::Accountmanage::App;

# The device-setup routes on a stand-in app. The point of interest is the
# CROSS-DEVICE path: a phone that has never signed in here opens a URL and
# the token in it is the entire authorisation. _current_auth short-circuits
# with no session and no Authorization header, so nothing here reaches the
# network.

my $SECRET = 'accountmanage-test-secret-0123456789';
my $EMAIL  = 'johnboy002@mailmasker.org';

{
    package TestDevApp;
    use Mojo::Base 'Mojolicious', -signatures;
    has 'device_config';
    has 'api_base';
    has 'public_base_url';
    sub startup ($self) {
        # The real app falls back to session.secret when device_setup
        # has no key of its own -- pinned here so the no-secret subtest
        # below is testing the absence it means to test.
        $self->secrets(['CHANGE_ME_TO_A_LONG_RANDOM_STRING']);
        $self->api_base('http://127.0.0.1:9/api');     # discard port: never answers
        $self->public_base_url('https://myaccount.mailmasker.org');
        $self->device_config({ token_secret => $SECRET, service_label => 'MailMasker',
                               qr_ttl_minutes => 15 });
        my $r = $self->routes;
        $r->namespaces(['Homelab::Accountmanage::App::Controller']);
        $r->get('/devices/apple.mobileconfig')->to('account#device_apple_profile');
        $r->get('/devices/qr.svg')            ->to('account#device_qr');
    }
}

my $t = Test::Mojo->new('TestDevApp');
my $good = issue_setup_token(secret => $SECRET, purpose => 'mail-device-setup',
                             subject => $EMAIL, ttl => 900);

subtest 'a scanned token downloads that mailbox and no other' => sub {
    $t->get_ok("/devices/apple.mobileconfig?t=$good")
      ->status_is(200)
      ->header_is('Content-Type' => 'application/x-apple-aspen-config')
      ->header_like('Content-Disposition' => qr/\.mobileconfig"$/)
      ->header_like('Cache-Control' => qr/no-store/)
      ->content_like(qr/<key>EmailAddress<\/key>\s*<string>\Q$EMAIL\E<\/string>/);

    my $other = issue_setup_token(secret => $SECRET, purpose => 'mail-device-setup',
        subject => 'someoneelse@mailmasker.org', ttl => 900);
    $t->get_ok("/devices/apple.mobileconfig?t=$other")
      ->status_is(200)
      ->content_unlike(qr/\Q$EMAIL\E/, 'a token only ever yields its own subject');
};

subtest 'without a session or a valid token there is nothing to download' => sub {
    $t->get_ok('/devices/apple.mobileconfig')->status_is(401);
    for my $bad ('garbage', "$good-tampered", substr($good, 0, -3)) {
        $t->get_ok("/devices/apple.mobileconfig?t=$bad")
          ->status_is(401)
          ->content_unlike(qr/\Q$EMAIL\E/, 'a rejection never leaks the address');
    }
    my $expired = issue_setup_token(secret => $SECRET, purpose => 'mail-device-setup',
        subject => $EMAIL, ttl => 1, now => time - 600);
    $t->get_ok("/devices/apple.mobileconfig?t=$expired")->status_is(401, 'expired token');

    my $wrong_purpose = issue_setup_token(secret => $SECRET, purpose => 'something-else',
        subject => $EMAIL, ttl => 900);
    $t->get_ok("/devices/apple.mobileconfig?t=$wrong_purpose")->status_is(401, 'wrong purpose');
};

subtest 'the QR endpoint needs a real session, not a token' => sub {
    # It MINTS the capability, so it must not be reachable with one --
    # otherwise a lapsed token could be traded for a fresh one forever.
    $t->get_ok("/devices/qr.svg?t=$good")->status_is(401, 'a valid setup token does not mint another');
    $t->get_ok('/devices/qr.svg')->status_is(401, 'and neither does nothing');
};

subtest 'the key falls back to the session secret, which the pool shares' => sub {
    # myaccount is three nodes behind one vhost. session.secret is already
    # identical across them (a cookie signed by one has to validate on the
    # next), so deriving from it is pool-safe by construction -- whereas a
    # per-host key would verify on about one request in three.
    my $t4 = Test::Mojo->new('TestDevApp');
    $t4->app->secrets(['a-real-looking-session-secret-9f3a']);
    $t4->app->device_config({ service_label => 'MailMasker' });    # no token_secret
    my $sess_token = issue_setup_token(secret => 'a-real-looking-session-secret-9f3a',
        purpose => 'mail-device-setup', subject => $EMAIL, ttl => 900);
    $t4->get_ok("/devices/apple.mobileconfig?t=$sess_token")
      ->status_is(200, 'a token signed with the session secret is accepted');

    # Domain separation: the same key, a different purpose, must not open
    # a mailbox -- that is what makes sharing the key with cookie signing
    # defensible rather than merely convenient.
    my $cookie_ish = issue_setup_token(secret => 'a-real-looking-session-secret-9f3a',
        purpose => 'some-other-feature', subject => $EMAIL, ttl => 900);
    $t4->get_ok("/devices/apple.mobileconfig?t=$cookie_ish")
      ->status_is(401, 'same key, different purpose, no access');

    # An explicit key wins over the fallback.
    my $t5 = Test::Mojo->new('TestDevApp');
    $t5->app->secrets(['a-real-looking-session-secret-9f3a']);
    $t5->app->device_config({ token_secret => 'pinned-key-abc' });
    $t5->get_ok("/devices/apple.mobileconfig?t=$sess_token")
      ->status_is(401, 'the session secret stops being honoured once a key is pinned');
    my $pinned = issue_setup_token(secret => 'pinned-key-abc',
        purpose => 'mail-device-setup', subject => $EMAIL, ttl => 900);
    $t5->get_ok("/devices/apple.mobileconfig?t=$pinned")->status_is(200, 'the pinned key works');
};

subtest 'no signing secret disables only the cross-device path' => sub {
    my $t2 = Test::Mojo->new('TestDevApp');
    $t2->app->device_config({});
    $t2->get_ok("/devices/apple.mobileconfig?t=$good")->status_is(401, 'tokens stop being honoured');

    my $t3 = Test::Mojo->new('TestDevApp');
    $t3->app->device_config({ token_secret => 'YOUR_SETUP_TOKEN_SECRET_HERE' });
    my $placeholder = issue_setup_token(secret => 'YOUR_SETUP_TOKEN_SECRET_HERE',
        purpose => 'mail-device-setup', subject => $EMAIL, ttl => 900);
    $t3->get_ok("/devices/apple.mobileconfig?t=$placeholder")
      ->status_is(401, 'the shipped placeholder is not a usable signing key');
};

subtest 'the Mail setup panel renders' => sub {
    # A template error in this partial would 500 the WHOLE dashboard for
    # every signed-in user, not just hide one card -- so it is rendered
    # here for real rather than trusted to review. Rendered standalone
    # (no layout) because the shared chrome is chrome.t's subject, not
    # this one's.
    plan skip_all => 'homelab-webtheme sources not alongside'
        unless -d "$FindBin::Bin/../../webtheme/templates";

    require Homelab::Common::MailSetup;
    my $settings = Homelab::Common::MailSetup::mail_settings(
        email => $EMAIL, config => { webmail_url => 'https://mail.mailmasker.org/' });

    my $t6 = Test::Mojo->new('TestDevApp');
    $t6->app->renderer->paths([ "$FindBin::Bin/../templates", @{ $t6->app->renderer->paths } ]);
    $t6->app->routes->get('/t/panel' => sub ($c) {
        $c->render(template => '_devices_panel',
            email           => $EMAIL,
            device_settings => $settings,
            device_rows     => Homelab::Common::MailSetup::manual_setup_rows($settings),
            device_qr_ok    => 1,
            device_hints    => { is_ios => 1, is_apple => 1, is_mac => 0, needs_safari => 0 },
        );
    });

    $t6->get_ok('/t/panel')->status_is(200)
      ->content_like(qr{/devices/apple\.mobileconfig},      'offers the profile download')
      ->content_like(qr{/devices/qr\.svg},                  'offers the QR code')
      ->content_like(qr/\Q$EMAIL\E/,                       'names the account')
      ->content_like(qr/mail\.mailmasker\.org/,            'IMAP host in the manual table')
      ->content_like(qr/smtp\.mailmasker\.org/,            'SMTP host in the manual table')
      ->content_like(qr/993/,                               'IMAPS port')
      ->content_like(qr/587/,                               'submission port')
      ->content_like(qr/IMAP/,                              'says IMAP')
      ->content_like(qr/does.*not.*contain your password/s, 'is explicit that the profile holds no password')
      ->content_like(qr/Add to this iPhone/,                'iOS wording when the UA is an iPhone');

    # The warning must appear only when it applies, or it is noise that
    # gets ignored on the one screen where it matters.
    $t6->app->routes->get('/t/panel-chrome' => sub ($c) {
        $c->render(template => '_devices_panel',
            email => $EMAIL, device_settings => $settings,
            device_rows => Homelab::Common::MailSetup::manual_setup_rows($settings),
            device_qr_ok => 0,
            device_hints => { is_ios => 1, is_apple => 1, is_mac => 0, needs_safari => 1 },
        );
    });
    $t6->get_ok('/t/panel-chrome')->status_is(200)
      ->content_like(qr/Open this page in <strong>Safari<\/strong>/, 'Safari warning on a non-Safari iOS browser')
      ->content_unlike(qr{/devices/qr\.svg}, 'no QR code offered when there is no signing key');
};

done_testing();
