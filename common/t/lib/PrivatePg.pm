package PrivatePg;

# A private, throwaway PostgreSQL for tests that must exercise real SQL
# WITHOUT going near the fleet's database: started in a temp directory,
# listening only on 127.0.0.1 at a random high port (pg_url() cannot
# express a unix-socket path), trust auth, stopped at exit.
#
#   my $pg = PrivatePg->start or plan skip_all => 'no PostgreSQL server binaries';
#   $pg->su->do(...);                  # superuser DBI handle
#   my %db = $pg->database;            # host/port/name/user/password for a config.yml
#
# Skips cleanly (start returns undef) where the server binaries are absent.

use strict;
use warnings;
use File::Temp qw(tempdir);
use DBI;

# Never inherit the caller's libpq settings: a workstation's PGHOST may
# point at a real server, and everything here is named explicitly.
delete @ENV{qw(PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGPASSWORD PGSERVICE PGSSLMODE)};

my @started;
END { system("$_->{bin}/pg_ctl -D $_->{dir}/data -m immediate stop >/dev/null 2>&1") for @started }

sub start {
    my ($class) = @_;
    my ($bin) = sort { $b cmp $a } glob('/usr/lib/postgresql/*/bin');
    return undef unless $bin && -x "$bin/initdb";
    my $dir  = tempdir(CLEANUP => 1);
    my $port = 40000 + int(rand(20000));
    system("$bin/initdb -D $dir/data -A trust -U postgres --no-sync >$dir/initdb.log 2>&1") == 0 or return undef;
    system("$bin/pg_ctl -D $dir/data -l $dir/server.log -w -o \"-k $dir -p $port -c listen_addresses=127.0.0.1 -c fsync=off\" start >/dev/null 2>&1") == 0
        or return undef;
    my $self = bless { bin => $bin, dir => $dir, port => $port }, $class;
    push @started, $self;
    return $self;
}

sub su {
    my ($self) = @_;
    $self->{su} ||= DBI->connect("dbi:Pg:dbname=postgres;host=127.0.0.1;port=$self->{port}", 'postgres', '',
                                 { RaiseError => 1, PrintError => 0, PrintWarn => 0 });
    return $self->{su};
}

sub database {
    my ($self) = @_;
    return (host => '127.0.0.1', port => $self->{port}, name => 'postgres', user => 'postgres', password => '');
}

# Applies every migration of one package, in order, as the superuser.
sub migrate {
    my ($self, $dir, $schema) = @_;
    my $su = $self->su;
    $su->do('SET client_min_messages = warning');
    $su->do("CREATE SCHEMA IF NOT EXISTS $schema") if $schema;
    for my $f (sort glob("$dir/*.sql")) {
        open my $fh, '<', $f or die "$f: $!";
        local $/;
        $su->do(scalar <$fh>);
    }
}

1;
