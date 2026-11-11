use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::PostfixBlockLink',
    VERSION      => '0.2.2',
    ABSTRACT     => 'Postfix milter add-on: click-to-block link on inbound mail; replies go out from the alias they were sent to',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious'       => '9.0',
        'YAML::XS'          => '0.0',
        'Mojo::Pg'          => '4.0',
        'Sendmail::PMilter' => '1.0',
        'Email::MIME'       => '1.9',
        'Email::Address::XS' => '1.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
    },
    EXE_FILES    => ['script/homelab-postfix-block-link', 'script/homelab-postfix-block-link-bootstrap-role'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-PostfixBlockLink-* *.deb *.changes *.buildinfo' },
);
