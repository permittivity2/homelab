use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::HAProxy',
    VERSION      => '0.1.0',
    ABSTRACT     => 'HAProxy TCP-passthrough edge provisioning for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0' },
    EXE_FILES    => ['script/homelab-haproxy-apply-backends'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-HAProxy-* *.deb *.changes *.buildinfo' },
);
