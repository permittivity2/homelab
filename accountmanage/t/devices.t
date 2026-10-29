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

# Derived, not written down. gitleaks' generic-api-key rule fires on the
# ENTROPY of whatever token follows a word like "secret" or "key", so a
# literal trips it even split into fragments -- and widening
# .gitleaks.toml to exempt a test file is the wrong trade. A repeated
# string has almost no entropy and is obviously not a credential.
my $SIGNER = join '', ('abcd1234') x 4;
my $SESS   = join '', ('wxyz5678') x 4;
my $EMAIL  = 'johnboy002@mailmasker.org';

{
    package TestDevApp;
    use Mojo::Base 'Mojolicious', -signatures;
    has 'device_config';
    has 'profile_signing';
    has 'mailer_config';
    has 'api_base';
    has 'public_base_url';
    sub startup ($self) {
        # The real app falls back to session.secret when device_setup
        # has no key of its own -- pinned here so the no-secret subtest
        # below is testing the absence it means to test.
        $self->secrets(['CHANGE_ME_TO_A_LONG_RANDOM_STRING']);
        $self->api_base('http://127.0.0.1:9/api');     # discard port: never answers
        $self->public_base_url('https://myaccount.mailmasker.org');
        $self->device_config({ token_secret => $SIGNER, service_label => 'MailMasker',
                               qr_ttl_minutes => 15 });
        # Signing off by default here: it is a call to another host, and
        # the subtest that cares about it configures it explicitly.
        $self->profile_signing({});
        $self->mailer_config({});
        my $r = $self->routes;
        $r->namespaces(['Homelab::Accountmanage::App::Controller']);
        $r->get('/devices/apple.mobileconfig')->to('account#device_apple_profile');
        $r->get('/devices/setup')             ->to('account#device_setup_page');
        $r->get('/devices/qr.svg')            ->to('account#device_qr');
        $r->get('/devices/setup-link')        ->to('account#device_setup_link');
        $r->post('/admin/welcome-email/resend')->to('account#admin_resend_welcome');
    }
}

my $t = Test::Mojo->new('TestDevApp');
my $good = issue_setup_token(secret => $SIGNER, purpose => 'mail-device-setup',
                             subject => $EMAIL, ttl => 900);

subtest 'a scanned token downloads that mailbox and no other' => sub {
    $t->get_ok("/devices/apple.mobileconfig?t=$good")
      ->status_is(200)
      ->header_is('Content-Type' => 'application/x-apple-aspen-config')
      ->header_like('Content-Disposition' => qr/\.mobileconfig"$/)
      ->header_like('Cache-Control' => qr/no-store/)
      ->content_like(qr/<key>EmailAddress<\/key>\s*<string>\Q$EMAIL\E<\/string>/);

    my $other = issue_setup_token(secret => $SIGNER, purpose => 'mail-device-setup',
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
    my $expired = issue_setup_token(secret => $SIGNER, purpose => 'mail-device-setup',
        subject => $EMAIL, ttl => 1, now => time - 600);
    $t->get_ok("/devices/apple.mobileconfig?t=$expired")->status_is(401, 'expired token');

    my $wrong_purpose = issue_setup_token(secret => $SIGNER, purpose => 'something-else',
        subject => $EMAIL, ttl => 900);
    $t->get_ok("/devices/apple.mobileconfig?t=$wrong_purpose")->status_is(401, 'wrong purpose');
};

subtest 'the QR endpoint echoes a token but only a session mints one' => sub {
    # The distinction matters and is invisible from outside, so it is
    # asserted on the BYTES. With a token, the code drawn must encode
    # THAT token's own URL -- re-encoding a capability the caller already
    # holds. If it minted a fresh one instead, a lapsed link could be
    # traded for a new lease indefinitely.
    $t->get_ok('/devices/qr.svg')->status_is(401, 'nothing at all is refused');
    $t->get_ok('/devices/qr.svg?t=garbage')->status_is(401, 'an invalid token is refused');

    SKIP: {
        require Homelab::Common::QRCode;
        skip 'Text::QRCode not installed', 3 unless Homelab::Common::QRCode::qr_available();

        my $expect = Homelab::Common::QRCode::qr_svg(
            "https://myaccount.mailmasker.org/devices/setup?t=$good",
            module => 6, title => "Mail setup for $EMAIL");

        $t->get_ok("/devices/qr.svg?t=$good")
          ->status_is(200)
          ->content_is($expect, 'the code encodes the presented token, not a fresh one');
    }

    # And it must still be impossible to get a code for someone else.
    my $other = issue_setup_token(secret => $SIGNER, purpose => 'mail-device-setup',
        subject => 'someoneelse@mailmasker.org', ttl => 900);
    $t->get_ok("/devices/qr.svg?t=$other")->status_is(200);
};

subtest 'an unreachable signer costs a label, never the download' => sub {
    # The entire design rests on this: profile signing happens on
    # another host, and that host being down, slow or misconfigured must
    # degrade to a red "Unverified" on the install screen rather than to
    # a failed download. Pointed at a port nothing listens on.
    my $ts = Test::Mojo->new('TestDevApp');
    $ts->app->profile_signing({ url => 'http://127.0.0.1:1',
        lineage => 'myaccount.mailmasker.org', timeout_seconds => 2,
        credential_file => '/nonexistent/credential.yml' });
    $ts->get_ok("/devices/apple.mobileconfig?t=$good")
      ->status_is(200, 'still serves a profile')
      ->header_is('Content-Type' => 'application/x-apple-aspen-config')
      ->content_like(qr/<\?xml/, 'falls back to the unsigned XML form')
      ->content_like(qr/\Q$EMAIL\E/, 'and it is still the right mailbox');
};

subtest 'resending the welcome email is site_admin only' => sub {
    # api_base is a discard port, so introspect cannot succeed and the
    # gate must fail CLOSED. Everything past the gate is exercised in
    # the subtest below, which stubs it.
    $t->post_ok('/admin/welcome-email/resend', form => { user_email => $EMAIL })
      ->status_is(403, 'no session, no resend');
};

subtest 'resend validates, then reports per destination' => sub {
    # _admin_auth and _api_get are stubbed rather than stood up: both are
    # pure HTTP to homelab-api, which is covered by its own tests, and
    # what is worth testing here is the handler's own logic -- what it
    # refuses, and that a failed send is reported rather than swallowed.
    no warnings 'redefine';
    local *Homelab::Accountmanage::App::Controller::Account::_admin_auth
        = sub ($c) { return ('admin@mailmasker.org', 'stub-jwt') };
    local *Homelab::Accountmanage::App::Controller::Account::_api_get
        = sub ($c, $jwt, $path) {
            return [ { id => 7, email => $EMAIL, active => 1 } ] if $path =~ /\Qjohnboy002\E/;
            return [];
        };

    my $ta = Test::Mojo->new('TestDevApp');
    $ta->app->device_config({ token_secret => $SIGNER, service_label => 'MailMasker',
                              link_ttl_days => 30, webmail_url => 'https://mail.mailmasker.org/' });

    # No mailer: say so plainly rather than appear to have sent.
    $ta->post_ok('/admin/welcome-email/resend', form => { user_email => $EMAIL })
      ->status_is(501)
      ->json_like('/error', qr/no mailer configured/);

    $ta->app->mailer_config({ email => 'invites@mailmasker.org',
        smtp_host => '127.0.0.1', smtp_port => 1, smtp_password => 'x' });

    $ta->post_ok('/admin/welcome-email/resend', form => { user_email => 'not-an-email' })
      ->status_is(400, 'a malformed address is refused');
    $ta->post_ok('/admin/welcome-email/resend',
        form => { user_email => $EMAIL, also_to => 'bad@@x' })
      ->status_is(400, 'a malformed second address is refused too');
    $ta->post_ok('/admin/welcome-email/resend', form => { user_email => 'nobody@mailmasker.org' })
      ->status_is(404, 'an account that does not exist is refused');

    # SMTP points at a closed port, so both sends fail -- which is the
    # case worth checking: a failure has to come back named, per
    # destination, not as a bare error.
    $ta->post_ok('/admin/welcome-email/resend',
        form => { user_email => $EMAIL, also_to => 'elsewhere@example.net' })
      ->status_is(200)
      ->json_is('/ok' => 0, 'reports overall failure')
      ->json_is('/setup_url' => 1, 'a device-setup link was minted')
      ->json_is('/results/0/to' => $EMAIL, 'the welcome message targets the mailbox')
      ->json_is('/results/0/what' => 'welcome')
      ->json_is('/results/0/ok' => 0)
      ->json_like('/results/0/error' => qr/\S/, 'and says why it failed')
      ->json_is('/results/1/to' => 'elsewhere@example.net', 'the second address gets the other wording')
      ->json_is('/results/1/what' => 'account-ready');

    # Without a second address there is exactly one message, into the
    # mailbox. Nothing is sent anywhere the admin did not name.
    $ta->post_ok('/admin/welcome-email/resend', form => { user_email => $EMAIL })
      ->status_is(200)
      ->json_is('/results/1' => undef, 'no second message when no second address is given');
};

subtest 'the setup page offers the hand-off only where it can be used' => sub {
    plan skip_all => 'homelab-webtheme sources not alongside'
        unless -d "$FindBin::Bin/../../webtheme/templates";
    my $tp = Test::Mojo->new('TestDevApp');
    $tp->app->renderer->paths([ "$FindBin::Bin/../templates",
        "$FindBin::Bin/../../webtheme/templates", @{ $tp->app->renderer->paths } ]);
    # This page pulls in the shared chrome's partial, which uses the
    # webtheme plugin's theme_base helper. Stubbed rather than registering
    # the real plugin: whether the plugin is wired up correctly is
    # chrome.t's subject, and this test deliberately starts a stand-in app
    # with no config and no network.
    $tp->app->helper(theme_base => sub { 'https://static.mailmasker.org' });

    # On a laptop -- which is where the link in a resent welcome email
    # gets opened as often as not -- the page has to offer a way across
    # to the phone, or it describes a one-tap install for a device the
    # reader is not holding.
    $tp->get_ok("/devices/setup?t=$good", { 'User-Agent' => 'Mozilla/5.0 (X11; Linux x86_64)' })
      ->status_is(200)
      ->content_like(qr{/devices/qr\.svg\?t=}, 'offers a QR code carrying the same token')
      ->content_like(qr{https://myaccount\.mailmasker\.org/devices/setup\?t=\Q$good\E},
                     'shows the full URL')
      ->content_like(qr{<a class="self-link" href=}, '  ... and it is a real link')
      ->content_like(qr/Copy link/, '  ... next to a copy button');

    # On the phone itself every one of those is noise: the install
    # button is right there.
    $tp->get_ok("/devices/setup?t=$good",
        { 'User-Agent' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/605' })
      ->status_is(200)
      ->content_like(qr/Add to this iPhone/, 'leads with the one-tap install')
      ->content_unlike(qr{/devices/qr\.svg}, 'and does not offer a code to scan with itself');
};

subtest 'the key falls back to the session secret, which the pool shares' => sub {
    # myaccount is three nodes behind one vhost. session.secret is already
    # identical across them (a cookie signed by one has to validate on the
    # next), so deriving from it is pool-safe by construction -- whereas a
    # per-host key would verify on about one request in three.
    my $t4 = Test::Mojo->new('TestDevApp');
    $t4->app->secrets([$SESS]);
    $t4->app->device_config({ service_label => 'MailMasker' });    # no token_secret
    my $sess_token = issue_setup_token(secret => $SESS,
        purpose => 'mail-device-setup', subject => $EMAIL, ttl => 900);
    $t4->get_ok("/devices/apple.mobileconfig?t=$sess_token")
      ->status_is(200, 'a token signed with the session secret is accepted');

    # Domain separation: the same key, a different purpose, must not open
    # a mailbox -- that is what makes sharing the key with cookie signing
    # defensible rather than merely convenient.
    my $cookie_ish = issue_setup_token(secret => $SESS,
        purpose => 'some-other-feature', subject => $EMAIL, ttl => 900);
    $t4->get_ok("/devices/apple.mobileconfig?t=$cookie_ish")
      ->status_is(401, 'same key, different purpose, no access');

    # An explicit key wins over the fallback.
    my $t5 = Test::Mojo->new('TestDevApp');
    $t5->app->secrets([$SESS]);
    $t5->app->device_config({ token_secret => 'pinned-value' });
    $t5->get_ok("/devices/apple.mobileconfig?t=$sess_token")
      ->status_is(401, 'the session secret stops being honoured once a key is pinned');
    my $pinned = issue_setup_token(secret => 'pinned-value',
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
