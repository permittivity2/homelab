use strict;
use warnings;
use Test::More;

# This exercises the REAL script end-to-end against a real local
# PostgreSQL cluster, via `sudo -u postgres psql` -- the same code path
# production uses. Requires passwordless sudo to the postgres user AND
# real, already-migrated api.users / domainadmin.domains /
# domainadmin.mail_aliases tables (homelab-api's and
# homelab-domain-admin's own migrations) -- see
# dovecot/t/dovecot-bootstrap-role.t for the identical pattern this is
# modeled on. Gated behind an explicit opt-in since it's not something
# arbitrary CI runners can do.
unless ($ENV{HOMELAB_POSTFIX_TEST_LIVE_BOOTSTRAP}) {
    plan skip_all => 'Set HOMELAB_POSTFIX_TEST_LIVE_BOOTSTRAP=1 to run this against a real local Postgres with homelab-api and homelab-domain-admin already migrated (needs passwordless sudo to postgres)';
}

my $script = 'script/homelab-postfix-bootstrap-role';
my $role   = 'homelab_postfix_runtime';

chomp(my $api_users_exists = `sudo -u postgres psql -d homelab -X -tAc "SELECT to_regclass('api.users')" 2>/dev/null`);
chomp(my $domains_exists   = `sudo -u postgres psql -d homelab -X -tAc "SELECT to_regclass('domainadmin.domains')" 2>/dev/null`);
chomp(my $aliases_exists   = `sudo -u postgres psql -d homelab -X -tAc "SELECT to_regclass('domainadmin.mail_aliases')" 2>/dev/null`);
unless ((defined $api_users_exists && length $api_users_exists)
     && (defined $domains_exists   && length $domains_exists)
     && (defined $aliases_exists   && length $aliases_exists)) {
    plan skip_all => 'api.users / domainadmin.domains / domainadmin.mail_aliases do not all exist yet -- install/migrate homelab-api and homelab-domain-admin on this Postgres first';
}

sub drop_role {
    my ($r) = @_;
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON api.users FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON SCHEMA api FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON domainadmin.domains FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON domainadmin.recipient_access FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON domainadmin.mail_aliases FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-d', 'homelab', '-c', qq{REVOKE ALL ON SCHEMA domainadmin FROM "$r"});
    system('sudo', '-u', 'postgres', 'psql', '-c', qq{DROP ROLE IF EXISTS "$r"});
}

# See dovecot/t/dovecot-bootstrap-role.t's identical END block comment:
# Perl compiles END blocks regardless of whether runtime ever reaches
# them, so this must be guarded by the same env var as the skip_all
# above and never touch anything but the roles THIS script created.
my $suffix        = 'testsuffix';
my $suffixed_role = "${role}_${suffix}";
END {
    if ($ENV{HOMELAB_POSTFIX_TEST_LIVE_BOOTSTRAP}) {
        drop_role($role);
        drop_role($suffixed_role);
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
is($creds{ROLE}, $role, 'role name matches the fixed homelab_postfix_runtime constant');

sub psql_as_role {
    my ($use_role, $password, @sql_and_args) = @_;
    local $ENV{PGPASSWORD} = $password;
    return system('psql', '-h', '127.0.0.1', '-p', '5432', '-U', $use_role, '-d', 'homelab', '-q', @sql_and_args);
}

is(
    psql_as_role($role, $creds{PASSWORD}, '-c', 'SELECT email, active FROM api.users LIMIT 1'),
    0,
    'runtime role can SELECT its granted columns on api.users',
);
is(
    psql_as_role($role, $creds{PASSWORD}, '-c', 'SELECT domain_name, mail_enabled, active FROM domainadmin.domains LIMIT 1'),
    0,
    'runtime role can SELECT its granted columns on domainadmin.domains',
);
is(
    psql_as_role($role, $creds{PASSWORD}, '-c', 'SELECT * FROM domainadmin.mail_aliases LIMIT 1'),
    0,
    'runtime role can SELECT domainadmin.mail_aliases',
);

# --role-suffix: each HA instance's own uniquely-named role (added
# after a real fleet rebuild found every 2nd/3rd homelab-postfix
# instance's install silently rotating ONE shared role's password out
# from under already-running siblings).
my $suffixed_output = `perl $script --db-host $hostname --role-suffix $suffix 2>/dev/null`;
is($? >> 8, 0, '--role-suffix: bootstrap script exits 0');

my %suffixed_creds;
for my $line (split /\n/, $suffixed_output) {
    my ($k, $v) = split /=/, $line, 2;
    $suffixed_creds{$k} = $v if defined $v;
}
is($suffixed_creds{ROLE}, $suffixed_role, '--role-suffix produces homelab_postfix_runtime_<suffix>, not the bare name');
isnt($suffixed_creds{ROLE}, $role, '--role-suffix role is a DIFFERENT role than the bare one bootstrapped above');

is(
    psql_as_role($suffixed_role, $suffixed_creds{PASSWORD}, '-c', 'SELECT email, active FROM api.users LIMIT 1'),
    0,
    '--role-suffix role can SELECT the same granted columns as the bare role',
);

# The actual point of this feature: bootstrapping the SUFFIXED role
# must not touch the ORIGINAL bare role's password.
is(
    psql_as_role($role, $creds{PASSWORD}, '-c', 'SELECT email FROM api.users LIMIT 1'),
    0,
    q{bootstrapping a --role-suffix role does NOT rotate the bare role's password out from under it},
);

done_testing;
