use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::WebProxy',
    VERSION      => '0.1.0',
    ABSTRACT     => 'nginx + Let\'s Encrypt provisioning for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0' },
    EXE_FILES    => ['script/homelab-webproxy-apply-sites'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-WebProxy-* *.deb *.changes *.buildinfo' },
);
