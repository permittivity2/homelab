use strict;
use warnings;
use Test::More;
use Test::Mojo;

# Full end-to-end integration test against a real Postgres AND a real,
# reachable homelab-api -- point HOMELAB_AUDIT_CONFIG at a real,
# already-deployed config.yml (matches worker/t/basic.t's own
# convention; no mocks).
unless ($ENV{HOMELAB_AUDIT_CONFIG}) {
    plan skip_all => 'Set HOMELAB_AUDIT_CONFIG to a real config.yml to run integration tests';
}

use lib 'lib';
use Mojo::UserAgent;

# NOT a top-level `use` -- Homelab::Common::AuditClient only exists via
# the separately-packaged homelab-common (not installed on a bare CI
# runner, which never sets HOMELAB_AUDIT_CONFIG and always takes the
# skip_all above). `use` is processed at compile time regardless of its
# position relative to that runtime skip check, so it would still try
# to load the module and abort the whole file before skip_all's exit
# ever ran -- same class of bug already hit once with `use Archive::Zip`
# in worker/t/basic.t. Every other package's own t/basic.t avoids this
# the same way: nothing Homelab::Common::* is ever `use`d at the top of
# the file, only reached via Test::Mojo->new('ClassName')'s runtime
# string-based require, which never executes in the skipped case either.
require Homelab::Common::AuditClient;
Homelab::Common::AuditClient->import(qw(enqueue));

my $t = Test::Mojo->new('Homelab::Audit::App');
my $api_base = $t->app->api_base;
my $ua       = Mojo::UserAgent->new;

sub _register_and_login {
    my ($label) = @_;
    my $email    = "e2e-audit-$label-" . time . '-' . $$ . '@test.mailmasker.org';
    my $password = 'AuditTest1Aa!!';
    $ua->post("$api_base/api/v1/auth/register" => json => { email => $email, password => $password });
    my $login_tx = $ua->post("$api_base/api/v1/auth/login" => json => { email => $email, password => $password });
    my $jwt = $login_tx->res->json('/token');
    ok($jwt, "got a real JWT for $label") or BAIL_OUT('cannot continue without a real login');
    return ($email, { Authorization => "Bearer $jwt" }, $jwt);
}

my ($email,    $auth)     = _register_and_login('owner');
my ($stranger, $stranger_auth) = _register_and_login('stranger');

# --- Auth required ---
$t->get_ok('/internal/v1/audit/log')->status_is(401, 'no Authorization header -> 401');

# --- Self-scoping: a plain user sees only their own entries, and can't
# ask for someone else's ---
$t->get_ok('/internal/v1/audit/log' => $auth)->status_is(200)->json_is('', []);
$t->get_ok("/internal/v1/audit/log?user=$stranger" => $auth)
  ->status_is(403, 'a non-capability caller cannot query another user, even by name');

# --- The actual write->drain->read round trip: enqueue via
# AuditClient::enqueue (the same call every producing service makes),
# then invoke the consumer's drain method DIRECTLY rather than waiting
# on the real 5s wall-clock timer, then confirm it shows up correctly
# normalized in a real read. ---
enqueue(
    $t->app->pg->db, user_email => $email, jti => 'test-jti-123', action => 'file.delete',
    resource_type => 'drive.file', resource_id => '42', source_service => 'homelab-drive',
    ip_address => '203.0.113.5', user_agent => 'homelab-cli/9.9.9 (Test)',
    detail => { filename => 'secret-plans.pdf' },
);

my $queued = $t->app->pg->db->query('SELECT count(*) AS n FROM audit.queue')->hash;
ok($queued->{n} >= 1, 'enqueue() landed a real row in audit.queue');

$t->app->_drain_queue;

my $drained = $t->app->pg->db->query('SELECT count(*) AS n FROM audit.queue')->hash;
is($drained->{n}, 0, 'drain cleared the queue');

$t->get_ok('/internal/v1/audit/log' => $auth)
  ->status_is(200)
  ->json_is('/0/action', 'file.delete')
  ->json_is('/0/resource_type', 'drive.file')
  ->json_is('/0/resource_id', '42')
  ->json_is('/0/user_email', $email)
  ->json_is('/0/jti', 'test-jti-123')
  ->json_is('/0/ip_address', '203.0.113.5')
  ->json_is('/0/detail/filename', 'secret-plans.pdf');

# The stranger's own view is unaffected by the owner's entry -- NOT
# asserted as empty: registering/logging in is itself a real audited
# action (by design, auth.login is one of the first-pass instrumented
# actions), so the stranger's own login legitimately produces an entry
# of their own the moment anything drains the queue, `_drain_queue`
# above included (it drains every pending row, not just the owner's).
# What actually matters for cross-user isolation is that the OWNER's
# file.delete entry never leaks into the stranger's view.
$t->get_ok('/internal/v1/audit/log' => $stranger_auth)->status_is(200);
my $stranger_entries = $t->tx->res->json;
ok(!(grep { ($_->{resource_id} // '') eq '42' } @$stranger_entries),
    "stranger's view never contains the owner's file.delete entry");

# --- Drain resilience: a malformed queue row (missing the required
# `action` field _find_or_create_id needs) must not wedge the whole
# batch -- the plan's own design explicitly calls for per-row isolation
# via a SAVEPOINT, not a Perl eval{} alone (which would NOT be enough:
# a failed INSERT aborts the whole surrounding Postgres transaction,
# silently killing every other row in the same batch including ones
# that already succeeded). Insert a bad row directly (bypassing
# AuditClient's own validation, which would refuse this) to prove the
# consumer itself is robust even if something else eventually feeds it
# a bad payload. ---
$t->app->pg->db->query(
    q{INSERT INTO audit.queue (payload) VALUES (?)},
    { json => { user_email => $email, source_service => 'homelab-drive' } },    # no `action`
);
enqueue(
    $t->app->pg->db, user_email => $email, jti => 'test-jti-456', action => 'file.delete',
    resource_type => 'drive.file', resource_id => '43', source_service => 'homelab-drive',
);
$t->app->_drain_queue;

my $after_bad_row = $t->app->pg->db->query('SELECT count(*) AS n FROM audit.queue')->hash;
is($after_bad_row->{n}, 0, 'both rows removed from the queue even though one failed to normalize');

$t->get_ok('/internal/v1/audit/log' => $auth)
  ->status_is(200);
my $entries = $t->tx->res->json;
ok((grep { ($_->{resource_id} // '') eq '43' } @$entries), 'the GOOD row after the bad one still made it into audit.entries');

done_testing();
