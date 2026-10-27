use strict;
use warnings;
use ExtUtils::MakeMaker;

# homelab-certsync is the CONSUMER half of the fleet certificate pipeline: it
# fetches this host's certificates from homelab-api's certificate store,
# decrypts them locally with the shared KEK, installs them atomically and
# reloads the service. Separate package from homelab-cert-server on purpose --
# it runs on 9 hosts that must NOT be able to issue anything.
WriteMakefile(
    NAME         => 'Homelab::CertSync',
    VERSION      => '0.1.0',
    ABSTRACT     => 'Pull fleet TLS certificates from the certificate store and install them',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'YAML::XS' => '0.0', 'Mojolicious' => '0.0' },
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-CertSync-* *.deb *.changes *.buildinfo' },
);
