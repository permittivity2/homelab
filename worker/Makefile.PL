use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Worker',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Centralized background-job engine for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious' => '9.0',
        'YAML::XS'    => '0.0',
        'Mojo::Pg'    => '4.0',
        'Archive::Zip' => '1.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
        'Test::Mojo' => '0.0',
    },
    EXE_FILES    => ['script/homelab-worker', 'script/homelab-worker-migrate'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Worker-* *.deb *.changes *.buildinfo' },
);
