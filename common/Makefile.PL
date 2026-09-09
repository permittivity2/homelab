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
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Common-* *.deb *.changes *.buildinfo' },
);
