use strict;
use warnings;
use ExtUtils::MakeMaker;

# homelab-cert-server owns TLS issuance for the fleet: certbot + DNS-01 hooks
# that solve challenges through homelab-api's narrow ACME endpoint, plus the
# publisher that envelope-encrypts each renewed certificate into the shared
# certificate store. Auxiliary file placement is in debian/rules.
WriteMakefile(
    NAME         => 'Homelab::CertServer',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Fleet TLS certificate issuance (DNS-01) + publication to the certificate store',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0', 'Mojolicious' => '0.0' },
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-CertServer-* *.deb *.changes *.buildinfo' },
);
