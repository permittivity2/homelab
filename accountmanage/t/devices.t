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

done_testing();
