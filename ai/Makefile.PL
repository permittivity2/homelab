use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::AI',
    VERSION      => '0.1.2',
    ABSTRACT     => 'Internal AI service for the homelab-* ecosystem: the one Anthropic client, usage and budgets',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious' => '9.0',
        'YAML::XS'    => '0.0',
        'Mojo::Pg'    => '4.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
        'Test::Mojo' => '0.0',
    },
    EXE_FILES    => ['script/homelab-ai', 'script/homelab-ai-migrate'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-AI-* *.deb *.changes *.buildinfo' },
);
