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

# --- Self-scoping: a plain user sees only their own entries by
# default, and can't ask for someone else's on EITHER filter ---
$t->get_ok('/internal/v1/audit/log' => $auth)->status_is(200)->json_is('', []);
$t->get_ok("/internal/v1/audit/log?user=$stranger" => $auth)
  ->status_is(403, 'a non-capability caller cannot query another user\'s actor_email, even by name');
$t->get_ok("/internal/v1/audit/log?affecting=$stranger" => $auth)
  ->status_is(403, 'nor another user\'s affected_user -- same gating on both filters');

# --- The actual write->drain->read round trip: enqueue via
# AuditClient::enqueue (the same call every producing service makes),
# then invoke the consumer's drain method DIRECTLY rather than waiting
# on the real 5s wall-clock timer, then confirm it shows up correctly
# normalized in a real read. actor_email/affected_user genuinely differ
# here -- $email did something, $stranger's account is what it was
# about (the admin-on-behalf-of-another-account case). ---
enqueue(
    $t->app->pg->db, actor_email => $email, affected_user => $stranger, jti => 'test-jti-123', action => 'file.delete',
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
  ->json_is('/0/actor_email', $email)
  ->json_is('/0/jti', 'test-jti-123')
  ->json_is('/0/ip_address', '203.0.113.5')
  ->json_is('/0/detail/filename', 'secret-plans.pdf');

# --- The whole point of affected_user: $stranger never did anything
# themselves, but this entry is genuinely about their account, so it
# must surface under ?affecting=$stranger for a capability holder --
# the concrete proof of the redesign's actual goal 2 (incident
# response: "everything that touched this account, including admin
# actions on it"). Needs a real audit.view-capable account; $email
# itself has no capability, so this specific check happens later once
# one is available (see the "affecting=, with capability" section
# below) -- noted here only to keep the narrative next to the write it
# verifies. ---

# The stranger's own ?user= view is unaffected by the owner's entry --
# NOT asserted as empty: registering/logging in is itself a real
# audited action (by design, auth.login is one of the first-pass
# instrumented actions), so the stranger's own login legitimately
# produces an entry of their own (as BOTH actor and affected_user, a
# self-action) the moment anything drains the queue, `_drain_queue`
# above included (it drains every pending row, not just the owner's).
# What actually matters for cross-user isolation on ?user= is that the
# OWNER's file.delete entry (actor_email = $email) never leaks into the
# stranger's ?user= view, even though the stranger IS its affected_user.
$t->get_ok('/internal/v1/audit/log' => $stranger_auth)->status_is(200);
my $stranger_entries = $t->tx->res->json;
ok(!(grep { ($_->{resource_id} // '') eq '42' } @$stranger_entries),
    "stranger's own ?user= view never contains the owner's file.delete entry (that's an ?affecting= question, not a ?user= one)");

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
    { json => { actor_email => $email, affected_user => $email, source_service => 'homelab-drive' } },    # no `action`
);
enqueue(
    $t->app->pg->db, actor_email => $email, affected_user => $email, jti => 'test-jti-456', action => 'file.delete',
    resource_type => 'drive.file', resource_id => '43', source_service => 'homelab-drive',
);
$t->app->_drain_queue;

my $after_bad_row = $t->app->pg->db->query('SELECT count(*) AS n FROM audit.queue')->hash;
is($after_bad_row->{n}, 0, 'both rows removed from the queue even though one failed to normalize');

$t->get_ok('/internal/v1/audit/log' => $auth)
  ->status_is(200);
my $entries = $t->tx->res->json;
ok((grep { ($_->{resource_id} // '') eq '43' } @$entries), 'the GOOD row after the bad one still made it into audit.entries');

# --- Simplified redesign: list() no longer logs its OWN reads (that
# was the piece that overcomplicated the original design -- see the
# plan's "What's being removed" section). Confirm it's genuinely gone,
# not just untested: neither of the two `list()` calls made against
# $auth so far should have produced an 'audit.view' entry anywhere in
# $auth's own trail. ---
$t->app->_drain_queue;
$t->get_ok('/internal/v1/audit/log' => $auth)->status_is(200);
my $no_self_log_entries = $t->tx->res->json;
ok(!(grep { $_->{action} eq 'audit.view' } @$no_self_log_entries),
    'list() no longer enqueues its own reads -- the reverted self-referential logging stays reverted');

# --- ?affecting=, with real capability: the actual proof of goal 2.
# Grant $auth's own account (the "owner") the audit.view capability --
# this reaches into homelab-api's OWN `api` schema, which homelab-
# audit's narrowly-scoped runtime role has NO grant on at all (same
# schema isolation as everywhere else in this ecosystem -- confirmed
# for real: $t->app->pg->db, i.e. homelab_audit_runtime, gets "permission
# denied for schema api" if you try). OS-level peer auth via
# `sudo -u postgres psql` (list-form exec, no shell interpolation of
# the SQL) is the same fallback tier every bootstrap script in this
# repo already uses when a feature-scoped role isn't enough -- same
# pattern domain-admin/t/basic.t already uses for its own site_admin
# grant, just reached from this test file instead.
{
    my $role_name = 'e2e-audit-capability-' . time . '-' . $$;
    my $sql = "INSERT INTO api.roles (name, protected) VALUES ('$role_name', false) ON CONFLICT (name) DO NOTHING;\n"
        . "INSERT INTO api.permissions (name) VALUES ('audit.view') ON CONFLICT (name) DO NOTHING;\n"
        . "INSERT INTO api.role_permissions (role_id, permission_id) "
        . "SELECT r.id, p.id FROM api.roles r, api.permissions p WHERE r.name = '$role_name' AND p.name = 'audit.view' "
        . "ON CONFLICT DO NOTHING;\n"
        . "INSERT INTO api.user_roles (user_id, role_id) "
        . "SELECT u.id, r.id FROM api.users u, api.roles r WHERE u.email = '$email' AND r.name = '$role_name' "
        . "ON CONFLICT DO NOTHING;";
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
    die "could not grant audit.view to $email for testing (needs passwordless sudo to postgres) -- see t/basic.t\n" if $? != 0;
}

$t->get_ok("/internal/v1/audit/log?affecting=$stranger" => $auth)->status_is(200);
my $affecting_entries = $t->tx->res->json;
my ($affecting_hit) = grep { ($_->{resource_id} // '') eq '42' } @$affecting_entries;
ok($affecting_hit, '?affecting= (now with capability) surfaces the earlier entry where $stranger was the affected_user, even though $email was the actor')
    or diag explain $affecting_entries;
is($affecting_hit->{actor_email}, $email, 'that entry still correctly names $email as the actor');

$t->get_ok("/internal/v1/audit/log?user=$email" => $auth)->status_is(200);
my $user_entries = $t->tx->res->json;
ok((grep { ($_->{resource_id} // '') eq '42' } @$user_entries),
    '?user=$email (actor filter, now with capability, same as self-default) also finds it -- $email really was the actor');

$t->get_ok("/internal/v1/audit/log?user=$email&affecting=$email" => $auth)->status_is(200);
ok(!(grep { ($_->{resource_id} // '') eq '42' } @{ $t->tx->res->json }),
    'combining both filters as $email/$email correctly EXCLUDES the cross-account entry (its affected_user is $stranger, not $email)');

# --- The reliability contract this whole design rests on: enqueue()
# has no eval/best-effort wrapper anywhere -- a failure must propagate,
# not be swallowed. ---
eval {
    enqueue($t->app->pg->db, action => 'file.delete', source_service => 'homelab-drive', affected_user => 'x@example.com');    # missing required actor_email
};
like($@, qr/actor_email is required/, 'enqueue() dies on a missing required actor_email');

eval {
    enqueue($t->app->pg->db, action => 'file.delete', source_service => 'homelab-drive', actor_email => 'x@example.com');    # missing required affected_user
};
like($@, qr/affected_user is required/, 'enqueue() dies on a missing required affected_user');

done_testing();
