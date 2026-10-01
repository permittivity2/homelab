use strict; use warnings; use ExtUtils::MakeMaker;
WriteMakefile(
    NAME => 'Homelab::PostfixExporter', VERSION => '0.1.0',
    ABSTRACT => 'Postfix metrics exporter wiring for the homelab-* ecosystem',
    AUTHOR => 'Jeff Gardner <mailmasker-api01@forge.name>', LICENSE => 'agpl_3',
    INSTALLDIRS => 'vendor', EXE_FILES => [], DIR => [],
    dist => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean => { FILES => 'Homelab-PostfixExporter-* *.deb *.changes *.buildinfo' },
);
