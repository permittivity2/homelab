use strict;
use warnings;
use Test::More;

# This exercises the REAL script end-to-end against a real local
# PostgreSQL cluster, via `sudo -u postgres psql` -- the same code path
# production uses. Requires passwordless sudo to the postgres user AND a
# real, already-migrated api.users table (homelab-api's own migration --
# unlike homelab-common's generic t/bootstrap-role.t, which creates its
# own disposable schema, this script targets a REAL table owned by a
# different feature entirely, so this test can't fabricate its
# precondition). Gated behind an explicit opt-in since it's not
# something arbitrary CI runners can do.
unless ($ENV{HOMELAB_DOVECOT_TEST_LIVE_BOOTSTRAP}) {
    plan skip_all => 'Set HOMELAB_DOVECOT_TEST_LIVE_BOOTSTRAP=1 to run this against a real local Postgres with homelab-api already migrated (needs passwordless sudo to postgres)';
}

my $script = 'script/homelab-dovecot-bootstrap-role';
my $role   = 'homelab_dovecot_runtime';

chomp(my $api_users_exists = `sudo -u postgres psql -d homelab -X -tAc "SELECT to_regclass('api.users')" 2>/dev/null`);
unless (defined $api_users_exists && length $api_users_exists) {
    plan skip_all => 'api.users does not exist yet -- install/migrate homelab-api on this Postgres first';
}

# Perl compiles END blocks regardless of whether runtime execution ever
# reaches them -- see homelab-common's t/bootstrap-role.t for the real
# CI failure this caused once already this session. Guard on the same
# env var the skip_all checks above use, and never touch api.users or
# the api schema itself in teardown -- only the role this script itself
# creates.
END {
    if ($ENV{HOMELAB_DOVECOT_TEST_LIVE_BOOTSTRAP}) {
        # Revoke before dropping -- a role holding live grants (exactly
        # what this script itself just gave it) can't be dropped
        # directly ("role ... cannot be dropped because some objects
        # depend on it"). A real, if cosmetic, bug caught running this
        # for the first time against a live host (2026-09-09): every
        # assertion passed, but the script's own OS exit code went
        # non-zero from THIS system() call's unchecked failure, which
        # `prove` correctly treats as a failing test file regardless of
        # the 12/12 subtests -- discarding the return value here would
        # silence the symptom without fixing the actual leftover-grant
        # cleanup bug.
        system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON api.users FROM "$role"});
        system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON SCHEMA api FROM "$role"});
        system('sudo', '-u', 'postgres', 'psql', '-c', qq{DROP ROLE IF EXISTS "$role"});
    }
}

chomp(my $hostname = `hostname`);
my $output = `perl $script --db-host $hostname 2>/dev/null`;
is($? >> 8, 0, 'bootstrap script exits 0');

my %creds;
for my $line (split /\n/, $output) {
    my ($k, $v) = split /=/, $line, 2;
    $creds{$k} = $v if defined $v;
}

for my $key (qw(ROLE PASSWORD SCRAM_SECRET)) {
    ok(defined $creds{$key} && length $creds{$key}, "output includes $key");
}
is($creds{ROLE}, $role, 'role name matches the fixed homelab_dovecot_runtime constant');

sub psql_as {
    my ($password, @sql_and_args) = @_;
    local $ENV{PGPASSWORD} = $password;
    return system('psql', '-h', '127.0.0.1', '-U', $role, '-d', 'homelab', '-q', @sql_and_args);
}

is(
    psql_as($creds{PASSWORD}, '-c', 'SELECT email, password_hash, active FROM api.users LIMIT 1'),
    0,
    'runtime role can SELECT the three granted columns',
);

# The test that actually proves the grant is column-scoped, not a
# full-table grant that happens to satisfy the three columns above --
# "id" was deliberately never granted.
isnt(
    psql_as($creds{PASSWORD}, '-c', 'SELECT id FROM api.users LIMIT 1'),
    0,
    'runtime role cannot SELECT the "id" column -- the grant is column-scoped, not full-table',
);

isnt(
    psql_as($creds{PASSWORD}, '-c', q{INSERT INTO api.users (email, password_hash) VALUES ('dovecot-bootstrap-role-test@example.com', 'x')}),
    0,
    'runtime role cannot INSERT into api.users -- read-only',
);
isnt(
    psql_as($creds{PASSWORD}, '-c', q{UPDATE api.users SET active = active}),
    0,
    'runtime role cannot UPDATE api.users -- read-only',
);
isnt(
    psql_as($creds{PASSWORD}, '-c', q{DELETE FROM api.users WHERE email = 'nonexistent-dovecot-bootstrap-role-test@example.com'}),
    0,
    'runtime role cannot DELETE from api.users -- read-only',
);

# Idempotency: running bootstrap again must not fail (matches a package
# reinstall/upgrade calling this again). The script always rotates the
# password on every run (same as homelab-bootstrap-app-role does) -- the
# real assertion is that the NEW password works afterward, not just that
# the exit code is 0.
my $output2 = `perl $script --db-host $hostname 2>/dev/null`;
is($? >> 8, 0, 'bootstrap script is idempotent -- re-running succeeds');

my %creds2;
for my $line (split /\n/, $output2) {
    my ($k, $v) = split /=/, $line, 2;
    $creds2{$k} = $v if defined $v;
}
is(
    psql_as($creds2{PASSWORD}, '-c', 'SELECT email FROM api.users LIMIT 1'),
    0,
    'after re-running, the NEW (rotated) password works',
);

done_testing;
