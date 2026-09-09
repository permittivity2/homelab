use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Homelab::Pgbouncer',
    VERSION      => '0.1.0',
    ABSTRACT     => 'PgBouncer connection pooler in front of the shared homelab database',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => {},
    EXE_FILES    => ['script/homelab-bootstrap-pgbouncer-entry'],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-Pgbouncer-* *.deb *.changes *.buildinfo' },
);
