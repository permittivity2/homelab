use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Accountmanage',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Account self-service + administration web UI for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious' => '9.0',
        'YAML::XS'    => '0.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
        'Test::Mojo' => '0.0',
    },
    EXE_FILES    => ['script/homelab-accountmanage'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Accountmanage-* *.deb *.changes *.buildinfo' },
);
