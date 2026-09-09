package Homelab::Common::Migrate;
use Mojo::Base -strict;
use Exporter 'import';

our @EXPORT_OK = qw(run_migrations);

# Applies any not-yet-applied migrations/NNN-description.sql files to
# $schema, in numeric order, each inside its own transaction — a bad
# migration rolls back cleanly (Postgres supports transactional DDL)
# rather than leaving the schema half-applied.
#
# $dbh is expected to come from Homelab::Common::DB::migrate_dbh — i.e.
# connected as the feature's DDL-capable <feature>_migrate role, direct
# to Postgres (bypassing pgbouncer). Never call this with a runtime-role
# connection; it doesn't have the grants and will fail loudly, which is
# the point (see CLAUDE.md's split-role design).
#
# The schema itself must already exist — homelab-bootstrap-app-role
# always creates it before a feature's migrate role is ever handed out,
# so this doesn't attempt `CREATE SCHEMA IF NOT EXISTS` itself. That's
# deliberate, not an oversight: CREATE SCHEMA requires database-level
# CREATE privilege in Postgres regardless of whether the schema already
# exists (IF NOT EXISTS only skips the actual creation, not the
# permission check) — granting that would widen the migrate role well
# beyond "manage the one schema it already owns," which is exactly the
# narrow scope the split-role design is trying to hold. Caught for real
# against the actual bootstrapped role during homelab-api's first
# install, not by the unit tests — those used an incidentally-superuser
# test role that had the privilege anyway and never exercised this path.
#
# %opts: dbh, schema, migrations_dir
# Returns the number of migrations actually applied this run (0 is the
# normal, expected result on a package upgrade with no new migrations).
sub run_migrations {
    my (%opts) = @_;
    my $dbh             = $opts{dbh}            // die "run_migrations(): dbh required\n";
    my $schema          = $opts{schema}          // die "run_migrations(): schema required\n";
    my $migrations_dir  = $opts{migrations_dir}  // die "run_migrations(): migrations_dir required\n";

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS "$schema".schema_migrations (
            version    INTEGER PRIMARY KEY,
            filename   TEXT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    });

    my $already_applied = $dbh->selectcol_arrayref(
        qq{SELECT version FROM "$schema".schema_migrations}
    );
    my %seen = map { $_ => 1 } @$already_applied;

    return 0 unless -d $migrations_dir;
    opendir(my $dh, $migrations_dir) or die "Cannot open $migrations_dir: $!\n";
    my @files = sort grep { /^\d+-.*\.sql$/ } readdir($dh);
    closedir($dh);

    my $applied_count = 0;
    for my $file (@files) {
        my ($version) = $file =~ /^(\d+)-/;
        $version = int($version);
        next if $seen{$version};

        open(my $fh, '<', "$migrations_dir/$file") or die "Cannot read $file: $!\n";
        local $/ = undef;
        my $sql = <$fh>;
        close($fh);

        $dbh->begin_work;
        my $ok = eval {
            $dbh->do($sql);
            $dbh->do(
                qq{INSERT INTO "$schema".schema_migrations (version, filename) VALUES (?, ?)},
                {}, $version, $file,
            );
            1;
        };
        if ($ok) {
            $dbh->commit;
            $applied_count++;
        }
        else {
            my $err = $@;
            $dbh->rollback;
            die "Migration $file failed, rolled back: $err\n";
        }
    }

    return $applied_count;
}

1;
