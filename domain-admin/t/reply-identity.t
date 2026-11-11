use strict;
use warnings;
use Test::More;
use Test::Mojo;

# #67: the per-user "reply from the alias" switch. Integration test against
# a real deployment, same gate and same real-login pattern as t/basic.t.
unless ($ENV{HOMELAB_DOMAIN_ADMIN_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DOMAIN_ADMIN_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
use FindBin;
use lib "$FindBin::Bin/../../common/t/lib";
use TestAccounts qw(track_account);
use Mojo::UserAgent;

my $t        = Test::Mojo->new('Homelab::DomainAdmin::App');
my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;
my $email    = 'e2e-reply-identity-' . time . '-' . $$ . '@test.mailmasker.org';
track_account(undef, $email);
my $password = 'ReplyIdentityTest1Aa!!';
$ua->post("$api_base/api/v1/auth/register" => json => { email => $email, password => $password });
my $jwt = $ua->post("$api_base/api/v1/auth/login" => json => { email => $email, password => $password })->res->json('/token');
ok($jwt, 'got a real JWT from homelab-api') or BAIL_OUT('cannot continue without a real login');
my $auth = { Authorization => "Bearer $jwt" };

$t->get_ok('/internal/v1/domains/mail-reply-identity/mine')->status_is(401, 'no token -> 401');
$t->put_ok('/internal/v1/domains/mail-reply-identity/mine' => json => { reply_from_alias => \1 })->status_is(401, 'PUT without token -> 401');

$t->get_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth)
  ->status_is(200, 'a plain (non site_admin) user reads their own setting')
  ->json_is('/reply_from_alias', 0, 'off by default: no row at all')
  ->json_is('/updated_at', undef, 'no updated_at before the first write');

$t->put_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth => json => {})
  ->status_is(400, 'missing reply_from_alias -> 400');
$t->put_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth => json => { reply_from_alias => undef })
  ->status_is(400, 'null reply_from_alias -> 400 (no three-state setting here)');

$t->put_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth => json => { reply_from_alias => \1 })
  ->status_is(200)->json_is('/reply_from_alias', 1, 'switched on');
$t->get_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth)
  ->status_is(200)->json_is('/reply_from_alias', 1, 'and it reads back on')
  ->json_like('/updated_at', qr/^\d{4}-\d\d-\d\d/, 'updated_at set');

$t->put_ok('/internal/v1/domains/mail-reply-identity/mine' => $auth => json => { reply_from_alias => \0 })
  ->status_is(200)->json_is('/reply_from_alias', 0, 'switched off again');

my $row = $t->app->pg->db->query(
    'SELECT reply_from_alias FROM domainadmin.mail_reply_identity WHERE user_email = ?', $email)->hash;
ok($row, 'the row persists after switching off (explicit false, not deleted)');
ok(!$row->{reply_from_alias}, '... and says false');

$t->app->pg->db->query('DELETE FROM domainadmin.mail_reply_identity WHERE user_email = ?', $email);

done_testing;
