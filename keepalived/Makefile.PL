use strict;
use warnings;
use ExtUtils::MakeMaker;

# homelab-keepalived is a thin fleet wrapper that Depends: keepalived (the
# real VRRP daemon, from the Ubuntu archive) and ships a config generator
# (homelab-keepalived-apply) plus a service-health check script. The
# Makefile.PL exists only so the whole ecosystem builds uniformly via
# `dh --buildsystem=perl_makemaker`; the auxiliary file placement is in
# debian/rules' override_dh_install.
WriteMakefile(
    NAME         => 'Homelab::Keepalived',
    VERSION      => '0.1.0',
    ABSTRACT     => 'VRRP virtual-IP failover (keepalived) for the homelab-* edge',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0' },
    EXE_FILES    => ['script/homelab-keepalived-apply'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Keepalived-* *.deb *.changes *.buildinfo' },
);
