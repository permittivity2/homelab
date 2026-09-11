use strict;
use warnings;
use Test::More;
use Test::Mojo;
use File::Temp qw(tempfile);

# Full end-to-end integration test -- needs a real config.yml AND real,
# already-running homelab-drive, homelab-mailbridge, and
# homelab-domain-admin that have all actually registered themselves
# (see their own README.md files). The forwarding LOGIC itself (path
# stripping, header/body passthrough, 502 on an unregistered feature)
# is unit-tested in isolation in common/t/proxy.t with fakes -- this
# test exists specifically to prove the real wiring: that homelab-api's
# hardcoded 'homelab-drive'/'homelab-mailbridge'/'homelab-domain-admin'
# feature names actually resolve to real services and real data comes
# back through the gateway, not just that the forwarding mechanism is
# theoretically correct.
unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'Set HOMELAB_API_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
my $t = Test::Mojo->new('Homelab::API::App');

my $email    = 'e2e-api-gateway-' . time . '-' . $$ . '@test.mailmasker.org';
my $password = 'ApiGatewayTest1Aa!!';

$t->post_ok('/api/v1/auth/register' => json => { email => $email, password => $password })
  ->status_is(201);
$t->post_ok('/api/v1/auth/login' => json => { email => $email, password => $password })
  ->status_is(200);
my $jwt = $t->tx->res->json('/token');
ok($jwt, 'got a real JWT');
my $auth = { Authorization => "Bearer $jwt" };

# --- Drive gateway: /api/v1/drive/* -> homelab-drive's own /api/v1/*
$t->get_ok('/api/v1/drive/files' => $auth)
  ->status_is(200, 'gateway resolved homelab-drive via the registry and forwarded successfully')
  ->json_is('' => [], 'a brand-new account has no files yet, but the call itself succeeded end to end');

my ($fh, $path) = tempfile(SUFFIX => '.txt');
print $fh "gateway round trip $$\n";
close($fh);
$t->post_ok('/api/v1/drive/files' => $auth => form => { file => { file => $path, filename => 'gw.txt' } })
  ->status_is(201, 'file upload forwarded through the gateway (multipart body + auth header both survived the hop)');
my $file_id = $t->tx->res->json('/id');
ok($file_id, 'drive returned a real file id through the gateway');

$t->get_ok('/api/v1/drive/files' => $auth)
  ->status_is(200)
  ->json_is('/0/filename', 'gw.txt', 'the uploaded file shows up in a subsequent gateway call');

$t->delete_ok("/api/v1/drive/files/$file_id" => $auth)->status_is(200);

# --- Auth still applies through the gateway, same as any other route.
$t->get_ok('/api/v1/drive/files')->status_is(401, 'no Authorization header -> 401, not a forwarded 200');

# --- Mail gateway: /api/v1/mail/* -> homelab-mailbridge, unprefixed.
# Not asserting on real message content here (that needs an
# already-provisioned mailbox, see mailbridge/t/basic.t) -- just that
# the gateway itself resolves and forwards correctly, which a fresh
# throwaway account's (empty, but real) inbox proves just as well.
$t->get_ok('/api/v1/mail/messages' => $auth)
  ->status_is(200, 'gateway resolved homelab-mailbridge via the registry and forwarded successfully');

# --- Domains gateway: /api/v1/domains/* -> homelab-domain-admin's own
# /internal/v1/* (strip_prefix + backend_prefix, same shape as drive's
# route, different reason -- see api/README.md). A throwaway,
# mail-only, dns_managed=false domain avoids touching real PowerDNS
# state from this test.
#
# Every homelab-domain-admin route requires site_admin (Phase 5) -- the
# forwarded Authorization header passes through unchanged, so the
# gateway itself can't grant this, the account behind $jwt actually
# needs the role. Same direct-SQL grant as api/t/admin.t's own test
# account, since this app owns the api schema directly.
{
    my $user_id = $t->app->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash->{id};
    my $role_id = $t->app->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'site_admin'})->hash->{id};
    $t->app->pg->db->query('INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING', $user_id, $role_id);
}

my $domain = 'e2e-api-gateway-domain-' . time . '-' . $$ . '.invalid';
$t->post_ok('/api/v1/domains' => $auth => json => { domain_name => $domain, dns_managed => \0 })
  ->status_is(201, 'gateway resolved homelab-domain-admin via the registry and forwarded successfully')
  ->json_is('/domain_name', $domain);

$t->get_ok('/api/v1/domains' => $auth)
  ->status_is(200)
  ->json_has('/0', 'the domain shows up in a subsequent gateway call');

$t->delete_ok("/api/v1/domains/$domain" => $auth)->status_is(200);

$t->get_ok('/api/v1/domains')->status_is(401, 'no Authorization header -> 401, not a forwarded 200');

done_testing;
