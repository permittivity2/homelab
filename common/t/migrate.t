use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
use Homelab::Common::DB qw(migrate_dbh);
use Homelab::Common::Migrate qw(run_migrations);

unless ($ENV{HOMELAB_COMMON_TEST_DB_HOST}) {
    plan skip_all => 'Set HOMELAB_COMMON_TEST_DB_HOST (+ _NAME/_USER/_PASSWORD) to run migration tests against a real Postgres';
}

my $dbh = migrate_dbh(
    host     => $ENV{HOMELAB_COMMON_TEST_DB_HOST},
    port     => $ENV{HOMELAB_COMMON_TEST_DB_PORT} // 5432,
    name     => $ENV{HOMELAB_COMMON_TEST_DB_NAME},
    user     => $ENV{HOMELAB_COMMON_TEST_DB_USER},
    password => $ENV{HOMELAB_COMMON_TEST_DB_PASSWORD},
);

# A throwaway schema per test run so repeated runs never collide.
my $schema = 'test_migrate_' . time . '_' . $$;
$dbh->do(qq{DROP SCHEMA IF EXISTS "$schema" CASCADE});

END {
    $dbh->do(qq{DROP SCHEMA IF EXISTS "$schema" CASCADE}) if $dbh;
}

my $dir = tempdir(CLEANUP => 1);
write_file("$dir/001-create-widgets.sql", qq{CREATE TABLE "$schema".widgets (id SERIAL PRIMARY KEY, name TEXT)});
write_file("$dir/002-add-widget-color.sql", qq{ALTER TABLE "$schema".widgets ADD COLUMN color TEXT});

my $applied = run_migrations(dbh => $dbh, schema => $schema, migrations_dir => $dir);
is($applied, 2, 'run_migrations applies both migration files on first run');

my $cols = $dbh->selectcol_arrayref(
    q{SELECT column_name FROM information_schema.columns WHERE table_schema = ? AND table_name = 'widgets' ORDER BY column_name},
    {}, $schema,
);
is_deeply($cols, ['color', 'id', 'name'], 'both migrations actually took effect on the table');

# Idempotency: running again applies nothing new — this is the exact
# scenario a package upgrade with no new migrations hits every time.
my $applied_again = run_migrations(dbh => $dbh, schema => $schema, migrations_dir => $dir);
is($applied_again, 0, 're-running with no new files applies nothing');

# A new file added later (simulating a future version bump) gets picked
# up on the next run without re-applying the earlier ones.
write_file("$dir/003-add-widget-qty.sql", qq{ALTER TABLE "$schema".widgets ADD COLUMN qty INTEGER});
my $applied_third = run_migrations(dbh => $dbh, schema => $schema, migrations_dir => $dir);
is($applied_third, 1, 'a newly-added migration file is picked up on the next run');

# A bad migration rolls back cleanly instead of leaving a half-applied
# schema — this is the whole point of wrapping each file in a transaction.
write_file("$dir/004-broken.sql", q{ALTER TABLE widgets THIS IS NOT VALID SQL});
eval { run_migrations(dbh => $dbh, schema => $schema, migrations_dir => $dir) };
like($@, qr/failed, rolled back/, 'a broken migration dies with a clear rollback message');

my $tracked = $dbh->selectcol_arrayref(qq{SELECT version FROM "$schema".schema_migrations WHERE version = 4});
is(scalar @$tracked, 0, 'the broken migration was NOT recorded as applied');

sub write_file {
    my ($path, $sql) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!\n";
    print $fh $sql;
    close($fh);
}

done_testing;
