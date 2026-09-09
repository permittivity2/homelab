package Homelab::Common::DB;
use Mojo::Base -strict;
use Mojo::Pg;
use Mojo::Util qw(url_escape);
use DBI;
use Exporter 'import';

our @EXPORT_OK = qw(pg_url runtime_pg migrate_dbh);

# Builds a postgresql:// URL from a config hash — the shape every
# package's config.yml `database:`/`database_migrate:` section already
# uses. User/password are percent-encoded since either may contain
# characters (@, :, /) that would otherwise corrupt the URL.
#
# %opts: host, port (default 5432), name, user, password
sub pg_url {
    my (%opts) = @_;
    my $host = $opts{host} // die "pg_url(): host required\n";
    my $name = $opts{name} // die "pg_url(): name required\n";
    my $user = $opts{user} // die "pg_url(): user required\n";
    my $pass = $opts{password} // '';
    my $port = $opts{port} // 5432;
    return sprintf(
        'postgresql://%s:%s@%s:%d/%s',
        url_escape($user), url_escape($pass), $host, $port, $name,
    );
}

# Mojo::Pg handle for RUNTIME use. By convention the config passed here
# is a feature's `database:` section, already pointed at pgbouncer
# (host/port 6432) — see CLAUDE.md's split-role design. This is the only
# DB handle the long-running service process should ever hold; it must
# connect as the narrow, DDL-less `<feature>_runtime` role.
sub runtime_pg {
    my (%opts) = @_;
    return Mojo::Pg->new(pg_url(%opts));
}

# Plain DBI handle for MIGRATION use. By convention the config passed
# here is a feature's `database_migrate:` section, which points DIRECTLY
# at Postgres — bypassing pgbouncer entirely, since this is a short-lived,
# infrequent connection with no pooling benefit to gain, and it sidesteps
# any pool-mode edge cases with DDL/multi-statement transactions. Must
# connect as the `<feature>_migrate` role (CRUD+DDL, same schema only) —
# see Homelab::Common::Migrate, which is what actually uses this.
# AutoCommit is on by default; Migrate explicitly wraps each file in its
# own transaction via begin_work/commit/rollback.
sub migrate_dbh {
    my (%opts) = @_;
    my $host = $opts{host} // die "migrate_dbh(): host required\n";
    my $name = $opts{name} // die "migrate_dbh(): name required\n";
    my $user = $opts{user} // die "migrate_dbh(): user required\n";
    my $pass = $opts{password} // '';
    my $port = $opts{port} // 5432;
    return DBI->connect(
        "dbi:Pg:host=$host;port=$port;dbname=$name",
        $user, $pass,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    );
}

1;
