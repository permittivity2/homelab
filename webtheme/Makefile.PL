use strict;
use warnings;
use ExtUtils::MakeMaker;

# homelab-webtheme ships the SHARED CHROME for the homelab Mojolicious apps:
# a Mojolicious plugin plus the header/footer/head partials. The stylesheet
# itself is NOT here -- it is served from static.mailmasker.org so a visual
# change restyles every app with no rebuild. Only the server-rendered markup
# ships, because the header displays the signed-in address.
WriteMakefile(
    NAME         => 'Homelab::WebTheme',
    VERSION_FROM => 'lib/Homelab/WebTheme.pm',
    ABSTRACT     => 'Shared header, footer and theme for homelab web apps',
    AUTHOR       => 'Jeff Gardner <mailmasker-api01@forge.name>',
    LICENSE      => 'agpl_3',
    INSTALLDIRS  => 'vendor',
    PREREQ_PM    => { 'Mojolicious' => '0.0' },
    EXE_FILES    => [],
    DIR          => [],
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => '.gz' },
    clean        => { FILES    => 'Homelab-WebTheme-* *.deb *.changes *.buildinfo' },
);
