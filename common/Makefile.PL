use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Common',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Shared config/DB/registry/queue/migration/health foundation for every homelab-* feature',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious' => '9.0',
        'YAML::XS'    => '0.0',
        'Mojo::Pg'    => '4.0',
        'DBI'         => '0.0',
        'DBD::Pg'     => '0.0',
        'Minion'      => '10.0',
    },
    TEST_REQUIRES => {
        'Test::More'  => '1.3',
        'Test::Mojo'  => '0.0',
    },
    # Both bootstrap scripts live here (not in homelab-database/
    # homelab-pgbouncer) so any feature can depend on the lightweight
    # CLIENT tool without pulling in an entire local Postgres/pgbouncer
    # server install — see CLAUDE.md.
    EXE_FILES    => [
        'script/homelab-bootstrap-app-role',
        'script/homelab-bootstrap-pgbouncer-entry',
    ],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Common-* *.deb *.changes *.buildinfo' },
);
