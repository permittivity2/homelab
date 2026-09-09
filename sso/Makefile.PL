use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::SSO',
    VERSION      => '0.1.0',
    ABSTRACT     => 'OIDC-style single sign-on provider for the homelab-* ecosystem',
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
    EXE_FILES    => ['script/homelab-sso', 'script/homelab-sso-migrate'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-SSO-* *.deb *.changes *.buildinfo' },
);
