use strict; use warnings; use ExtUtils::MakeMaker;
WriteMakefile(
    NAME => 'Homelab::NginxExporter', VERSION => '0.1.0',
    ABSTRACT => 'nginx metrics exporter wiring for the homelab-* ecosystem',
    AUTHOR => 'Jeff Gardner <mailmasker-api01@forge.name>', LICENSE => 'agpl_3',
    INSTALLDIRS => 'vendor', EXE_FILES => [], DIR => [],
    dist => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean => { FILES => 'Homelab-NginxExporter-* *.deb *.changes *.buildinfo' },
);
