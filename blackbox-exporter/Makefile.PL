use strict;
use warnings;
use ExtUtils::MakeMaker;

# Config-only wrapper around the Ubuntu-archive prometheus-blackbox-exporter:
# ships the fleet's prober modules + public-vhost probe target list and
# advertises the exporter. No Perl of its own.
WriteMakefile(
    NAME         => 'Homelab::BlackboxExporter',
    VERSION      => '0.1.0',
    ABSTRACT     => 'External (blackbox) probe wiring for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-BlackboxExporter-* *.deb *.changes *.buildinfo' },
);
