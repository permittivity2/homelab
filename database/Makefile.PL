use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Database',
    VERSION      => '0.1.0',
    ABSTRACT     => 'PostgreSQL provisioning substrate for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {},
    EXE_FILES    => ['script/homelab-bootstrap-app-role'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Database-* *.deb *.changes *.buildinfo' },
);
