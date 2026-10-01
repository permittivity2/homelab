use strict;
use warnings;
use ExtUtils::MakeMaker;

# Provisioning-only package: ships Grafana datasource + dashboard
# provisioning for the homelab fleet. The Grafana server itself comes from
# the (separately staged) upstream grafana package this Depends: on --
# Grafana is not in the Ubuntu archive, so its .deb is installed directly
# on the monitoring host first. No Perl of its own; Makefile.PL exists so
# the ecosystem builds uniformly via dh --buildsystem=perl_makemaker.
WriteMakefile(
    NAME         => 'Homelab::Grafana',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Grafana dashboard/datasource provisioning for the homelab-* ecosystem',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Grafana-* *.deb *.changes *.buildinfo' },
);
