use strict;
use warnings;
use ExtUtils::MakeMaker;

# homelab-svc-hosts ships a single generator (homelab-svc-hosts-apply) that
# seeds a managed block in /etc/hosts from /etc/homelab/svc-hosts/hosts.yml,
# mapping stable internal service names (api.svc.homelab, ...) to their 10.50
# service-plane VIP/host addresses. The Makefile.PL exists only so the whole
# ecosystem builds uniformly via `dh --buildsystem=perl_makemaker`; auxiliary
# file placement is in debian/rules' override_dh_install.
WriteMakefile(
    NAME         => 'Homelab::SvcHosts',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Internal service-name resolution for the homelab-* fleet',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0' },
    EXE_FILES    => ['script/homelab-svc-hosts-apply'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-SvcHosts-* *.deb *.changes *.buildinfo' },
);
