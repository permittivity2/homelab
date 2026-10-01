use strict;
use warnings;
use ExtUtils::MakeMaker;

# Config-only wrapper around the Ubuntu-archive prometheus-postgres-exporter:
# bootstraps a pg_monitor role + DSN and advertises the exporter into the
# fleet. No Perl of its own; Makefile.PL exists for uniform packaging.
WriteMakefile(
    NAME         => 'Homelab::PostgresExporter',
    VERSION      => '0.1.0',
    ABSTRACT     => 'PostgreSQL metrics exporter wiring for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-PostgresExporter-* *.deb *.changes *.buildinfo' },
);
