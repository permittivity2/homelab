use strict;
use warnings;
use Test::More;

# This exercises the REAL script end-to-end against a real local
# PostgreSQL cluster, via `sudo -u postgres psql` — the same code path
# production uses. Requires passwordless sudo to the postgres user and a
# `homelab` database to already exist (matches homelab-database's own
# postinst having run). Gated behind an explicit opt-in since it's not
# something arbitrary CI runners can do.
unless ($ENV{HOMELAB_COMMON_TEST_LIVE_BOOTSTRAP}) {
    plan skip_all => 'Set HOMELAB_COMMON_TEST_LIVE_BOOTSTRAP=1 to run this against a real local Postgres (needs passwordless sudo to postgres)';
}

my $feature = 'homelab_bootstraptest_' . $$;
my $schema  = $feature;
my $script  = 'script/homelab-bootstrap-app-role';

# Perl compiles END blocks regardless of whether runtime execution ever
# reaches them — the plan skip_all above exits before $feature/$schema
# are assigned, but this block still ran on the way out, interpolating
# undef into the DROP statements (dropping a role literally named
# "_runtime"/"_migrate") and logging "uninitialized value" warnings.
# Harmless against a real Postgres (IF EXISTS on a bogus name is a
# no-op) but caused a hard failure in CI, where no local Postgres/socket
# exists at all for `sudo -u postgres psql` to even reach — guard on the
# same env var the skip_all check uses, so this is a true no-op when
# skipped, not just usually-harmless.
END {
    if ($ENV{HOMELAB_COMMON_TEST_LIVE_BOOTSTRAP}) {
        system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{DROP SCHEMA IF EXISTS "$schema" CASCADE});
        system('sudo', '-u', 'postgres', 'psql', '-c', qq{DROP ROLE IF EXISTS "${feature}_runtime"});
        system('sudo', '-u', 'postgres', 'psql', '-c', qq{DROP ROLE IF EXISTS "${feature}_migrate"});
    }
}

chomp(my $hostname = `hostname`);
my $output = `perl $script --feature $feature --schema $schema --db-host $hostname 2>/dev/null`;
is($? >> 8, 0, 'bootstrap script exits 0');

my %creds;
for my $line (split /\n/, $output) {
    my ($k, $v) = split /=/, $line, 2;
    $creds{$k} = $v if defined $v;
}

for my $key (qw(RUNTIME_ROLE RUNTIME_PASSWORD RUNTIME_SCRAM_SECRET MIGRATE_ROLE MIGRATE_PASSWORD MIGRATE_SCRAM_SECRET)) {
    ok(defined $creds{$key} && length $creds{$key}, "output includes $key");
}

sub psql_as {
    my ($role, $password, @sql_and_args) = @_;
    local $ENV{PGPASSWORD} = $password;
    return system('psql', '-h', '127.0.0.1', '-U', $role, '-d', 'homelab', '-q', @sql_and_args);
}

# The exact bug this test exists to catch: a table created by the
# migrate role AFTER bootstrap must be immediately usable by the
# runtime role — this only works if the bootstrap SQL's default
# privileges are granted `FOR ROLE <migrate_role>`, not just run as
# postgres (which only covers objects postgres itself creates later).
is(
    psql_as($creds{MIGRATE_ROLE}, $creds{MIGRATE_PASSWORD}, '-c', qq{CREATE TABLE "$schema".widgets (id SERIAL PRIMARY KEY, name TEXT)}),
    0,
    'migrate role can create a table',
);
is(
    psql_as($creds{RUNTIME_ROLE}, $creds{RUNTIME_PASSWORD}, '-c', qq{INSERT INTO "$schema".widgets (name) VALUES ('x')}),
    0,
    'runtime role can INSERT into a table the migrate role just created (the split-role default-privileges bug)',
);
is(
    psql_as($creds{RUNTIME_ROLE}, $creds{RUNTIME_PASSWORD}, '-c', qq{SELECT * FROM "$schema".widgets}),
    0,
    'runtime role can SELECT from it too',
);

# And the other half of the property: runtime role must NOT be able to
# do DDL, even on its own schema.
isnt(
    psql_as($creds{RUNTIME_ROLE}, $creds{RUNTIME_PASSWORD}, '-c', qq{CREATE TABLE "$schema".hacked (id INT)}),
    0,
    'runtime role cannot CREATE TABLE (no DDL rights)',
);
isnt(
    psql_as($creds{RUNTIME_ROLE}, $creds{RUNTIME_PASSWORD}, '-c', qq{DROP TABLE "$schema".widgets}),
    0,
    'runtime role cannot DROP TABLE',
);

# Idempotency: running bootstrap again with the same feature must not
# fail (matches a package reinstall/upgrade calling this again).
my $output2 = `perl $script --feature $feature --schema $schema --db-host $hostname 2>/dev/null`;
is($? >> 8, 0, 'bootstrap script is idempotent — re-running succeeds');

done_testing;
