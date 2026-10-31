use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Search',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Indexed search over the fleet mail and drive stores',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious'        => '9.0',
        'YAML::XS'           => '0.0',
        'Mojo::Pg'           => '4.0',
        'Email::MIME'        => '1.9',
        'Email::Address::XS' => '1.04',
        'HTTP::Date'         => '6.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
    },
    EXE_FILES    => ['script/homelab-search-indexer', 'script/homelab-search-migrate'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Search-* *.deb *.changes *.buildinfo' },
);
