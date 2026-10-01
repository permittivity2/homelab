use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Prometheus',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Prometheus monitoring host (fleet-discovered scrape targets) for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0', 'Mojolicious' => '0.0' },
    EXE_FILES    => ['script/homelab-prometheus-pull'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Prometheus-* *.deb *.changes *.buildinfo' },
);
