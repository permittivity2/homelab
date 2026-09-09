use strict;
use warnings;
use Test::More;

use lib 'lib';
use Homelab::Common::DB qw(pg_url runtime_pg migrate_dbh);

# pg_url() is pure string-building — fully testable with no live DB.
is(
    pg_url(host => 'db.example.com', name => 'homelab', user => 'homelab_drive', password => 'plainpass'),
    'postgresql://homelab_drive:plainpass@db.example.com:5432/homelab',
    'pg_url defaults port to 5432',
);

is(
    pg_url(host => 'db.example.com', port => 6432, name => 'homelab', user => 'u', password => 'p'),
    'postgresql://u:p@db.example.com:6432/homelab',
    'pg_url respects an explicit port',
);

# Regression test: a password containing URL-special characters must not
# corrupt the resulting URL (this is exactly the class of bug percent-
# encoding exists to prevent — verified explicitly, not just trusted).
is(
    pg_url(host => 'db.example.com', name => 'homelab', user => 'u', password => 'p@ss:w/rd'),
    'postgresql://u:p%40ss%3Aw%2Frd@db.example.com:5432/homelab',
    'pg_url percent-encodes special characters in the password',
);

for my $missing (qw(host name user)) {
    my %opts = (host => 'h', name => 'n', user => 'u', password => 'p');
    delete $opts{$missing};
    eval { pg_url(%opts) };
    like($@, qr/\Q$missing\E required/, "pg_url dies clearly when $missing is missing");
}

SKIP: {
    skip 'Set HOMELAB_COMMON_TEST_DB_HOST (+ _NAME/_USER/_PASSWORD) to test real connections', 2
        unless $ENV{HOMELAB_COMMON_TEST_DB_HOST};

    my %opts = (
        host     => $ENV{HOMELAB_COMMON_TEST_DB_HOST},
        port     => $ENV{HOMELAB_COMMON_TEST_DB_PORT} // 5432,
        name     => $ENV{HOMELAB_COMMON_TEST_DB_NAME},
        user     => $ENV{HOMELAB_COMMON_TEST_DB_USER},
        password => $ENV{HOMELAB_COMMON_TEST_DB_PASSWORD},
    );

    my $pg = runtime_pg(%opts);
    is($pg->db->query('SELECT 1 AS ok')->hash->{ok}, 1, 'runtime_pg opens a working Mojo::Pg connection');

    my $dbh = migrate_dbh(%opts);
    is($dbh->selectrow_array('SELECT 1'), 1, 'migrate_dbh opens a working DBI connection');
}

done_testing;
