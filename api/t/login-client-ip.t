use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin;
use File::Temp qw(tempdir);

# Which address a failed login is COUNTED and RECORDED under -- against a
# private, throwaway PostgreSQL loaded with this package's own migrations,
# never the fleet's database.
#
# Browser logins reach homelab-api server-to-server from homelab-sso, so
# the connection address is the SSO host's. Before this, every browser
# login through one SSO host shared one 10-failures/15-minutes lockout
# (one attacker locked everyone out) and login_attempts named the SSO
# host. Now the caller's client_ip is used when -- and only when -- the
# caller holds a live system_agent session, as _register already did.

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../common/lib", "$FindBin::Bin/../../common/t/lib";
use PrivatePg;

my $pg = PrivatePg->start or plan skip_all => 'no PostgreSQL server binaries';
$pg->migrate("$FindBin::Bin/../migrations", 'api');
# a successful login also queues an audit entry (homelab-audit owns that table)
$pg->migrate("$FindBin::Bin/../../audit/migrations", 'audit');
my $su = $pg->su;

# derived, not a literal: gitleaks flags any high-entropy token after the
# word "secret" (see .gitleaksignore)
my $SECRET = join '', ('abcd1234') x 5;
my $dir = tempdir(CLEANUP => 1);
my %db = $pg->database;
open my $cfg, '>', "$dir/config.yml" or die;
print {$cfg} "database:\n" . join('', map { "  $_: '$db{$_}'\n" } sort keys %db)
           . "jwt:\n  secret: '$SECRET'\n  expiry_seconds: 900\n  refresh_expiry_days: 30\n";
close $cfg;
$ENV{HOMELAB_API_CONFIG} = "$dir/config.yml";

require Homelab::API::Auth;
Homelab::API::Auth->import(qw(hash_password generate_jwt generate_jti));
my $t = Test::Mojo->new('Homelab::API::App');

# --- identities -----------------------------------------------------------------
sub user_with_session {
    my ($email, %a) = @_;
    my $id = $su->selectrow_array('INSERT INTO api.users (email, password_hash) VALUES (?, ?) RETURNING id',
        undef, $email, hash_password($a{password} // 'unused-password'));
    $su->do(q{INSERT INTO api.user_roles (user_id, role_id) SELECT ?, id FROM api.roles WHERE name = 'system_agent'}, undef, $id)
        if $a{agent};
    my $jti = generate_jti();
    $su->do(q{INSERT INTO api.sessions (jti, user_id, revoked, expires_at) VALUES (?, ?, ?, NOW() + INTERVAL '1 hour')},
        undef, $jti, $id, $a{revoked} ? 1 : 0);
    my ($jwt) = generate_jwt($email, secret => $SECRET, expires_in => 900, jti => $jti);
    return $jwt;
}
my $agent   = user_with_session('agent@homelab.test', agent => 1);
my $revoked = user_with_session('revoked-agent@homelab.test', agent => 1, revoked => 1);
my $plain   = user_with_session('plain-user@homelab.test');
user_with_session('alice@test.mailmasker.org', password => 'right-password');

sub recorded_ip {
    my ($email) = @_;
    return $su->selectrow_array('SELECT ip FROM api.login_attempts WHERE email = ? ORDER BY attempted_at DESC LIMIT 1', undef, $email);
}
sub fail_login {
    my ($email, $client_ip, $bearer) = @_;
    my %h = $bearer ? (Authorization => "Bearer $bearer") : ();
    return $t->post_ok('/api/v1/auth/login' => \%h => json => { email => $email, password => 'wrong', client_ip => $client_ip });
}

# --- whose address is recorded --------------------------------------------------
fail_login('case1@test.mailmasker.org', '198.51.100.5')->status_is(401);
is recorded_ip('case1@test.mailmasker.org'), '127.0.0.1', 'no credential: client_ip is ignored (a public caller cannot pick its bucket)';

fail_login('case2@test.mailmasker.org', '198.51.100.5', $agent)->status_is(401);
is recorded_ip('case2@test.mailmasker.org'), '198.51.100.5', 'a system agent (homelab-sso): the browser\'s address is recorded';

fail_login('case3@test.mailmasker.org', '2001:db8::5', $agent)->status_is(401);
is recorded_ip('case3@test.mailmasker.org'), '2001:db8::5', '...IPv6 too';

fail_login('case4@test.mailmasker.org', '198.51.100.5', $plain)->status_is(401);
is recorded_ip('case4@test.mailmasker.org'), '127.0.0.1', 'an ordinary user\'s token is not enough';

fail_login('case5@test.mailmasker.org', '198.51.100.5', $revoked)->status_is(401);
is recorded_ip('case5@test.mailmasker.org'), '127.0.0.1', 'a revoked agent session is not enough';

fail_login('case6@test.mailmasker.org', '198.51.100.5', 'not-a-jwt')->status_is(401);
is recorded_ip('case6@test.mailmasker.org'), '127.0.0.1', 'a garbage token falls back, without an error';

fail_login('case7@test.mailmasker.org', "1.2.3.4'; DROP TABLE api.users; --", $agent)->status_is(401);
is recorded_ip('case7@test.mailmasker.org'), '127.0.0.1', 'an invalid client_ip falls back to the connection address';
fail_login('case8@test.mailmasker.org', '300.1.1.1', $agent)->status_is(401);
is recorded_ip('case8@test.mailmasker.org'), '127.0.0.1', 'an out-of-range address falls back too';

# --- the lockout is per person now -----------------------------------------------
$su->do('DELETE FROM api.login_attempts');
fail_login("burst$_\@test.mailmasker.org", '203.0.113.66', $agent)->status_is(401) for 1 .. 10;
fail_login('burst11@test.mailmasker.org', '203.0.113.66', $agent)->status_is(429, 'the attacker\'s 11th failure is locked out');
$t->post_ok('/api/v1/auth/login' => { Authorization => "Bearer $agent" }
    => json => { email => 'alice@test.mailmasker.org', password => 'right-password', client_ip => '203.0.113.77' })
  ->status_is(200, 'someone else logging in through the same SSO host is NOT locked out');
is recorded_ip('alice@test.mailmasker.org'), '203.0.113.77', 'and her success is recorded under her own address';

# without the credential, everything through the SSO host shares one counter (the old behaviour)
$t->post_ok('/api/v1/auth/login' => json => { email => 'alice@test.mailmasker.org', password => 'right-password', client_ip => '203.0.113.77' })
  ->status_is(200, 'a login without the credential still works (only the counting differs)');

done_testing;
