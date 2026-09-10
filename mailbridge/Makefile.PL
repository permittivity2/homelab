use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::MailBridge',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Internal IMAP/SMTP relay behind homelab-api\'s /api/v1/mail gateway',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {
        'Mojolicious'      => '9.0',
        'YAML::XS'         => '0.0',
        'Mail::IMAPClient' => '0.0',
        'Email::MIME'      => '0.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '1.3',
        'Test::Mojo' => '0.0',
    },
    EXE_FILES    => ['script/homelab-mailbridge'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-MailBridge-* *.deb *.changes *.buildinfo' },
);
