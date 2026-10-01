use strict;
use warnings;
use ExtUtils::MakeMaker;

# This package ships no Perl of its own -- it is a thin fleet wrapper that
# Depends: prometheus-node-exporter (the real exporter, from the Ubuntu
# archive) and drops a homelab-agent service manifest. The Makefile.PL
# exists only so the whole ecosystem builds uniformly via
# `dh --buildsystem=perl_makemaker`; the real file placement is in
# debian/rules' override_dh_install.
WriteMakefile(
    NAME         => 'Homelab::NodeExporter',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Fleet host-metrics exporter (Prometheus node_exporter) for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-NodeExporter-* *.deb *.changes *.buildinfo' },
);
