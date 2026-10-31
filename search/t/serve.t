use strict;
use warnings;
use Test::More;
use lib 'lib';
use Homelab::Search::Serve qw(serve_mode viewable);

# The rendering contract. The rows that matter are the ones that must NEVER be
# inline: a user-uploaded HTML file, or an SVG (an image type that executes
# script), served inline from this origin is stored XSS against the search
# session.
my @never_inline = (
    'text/html', 'TEXT/HTML', 'text/html; charset=utf-8',
    'application/xhtml+xml', 'image/svg+xml', 'text/xml', 'application/xml',
);
for my $m (@never_inline) {
    my ($mode, $ct) = serve_mode($m);
    is $mode, 'download', "$m is download-only";
    is $ct, 'application/octet-stream', "$m is served as octet-stream";
    ok !viewable($m), "$m is not offered as viewable";
}

# Text is viewable but always reduced to text/plain, so an HTML document
# arriving as .txt or as application/json still cannot execute.
for my $m ('text/plain', 'text/csv', 'application/json', 'text/markdown') {
    my ($mode, $ct) = serve_mode($m);
    is $mode, 'inline', "$m is inline";
    like $ct, qr{^text/plain}, "$m is served as text/plain, not its own type";
    ok viewable($m), "$m is offered as viewable";
}

# Media the browser renders and cannot execute keeps its own type.
for my $m ('image/jpeg', 'image/png', 'audio/mpeg', 'video/mp4') {
    my ($mode, $ct) = serve_mode($m);
    is $mode, 'inline', "$m is inline";
    is $ct, $m, "$m keeps its own content type";
}

# PDF opens in the browser viewer.
my ($pm, $pc) = serve_mode('application/pdf');
is $pm, 'inline', 'pdf is inline';
is $pc, 'application/pdf', 'pdf keeps its type';

# Anything unknown, binary, or absent is download-only.
for my $m ('application/octet-stream', 'application/zip', 'application/x-dosexec',
           'application/vnd.hp-HPGL', undef, '', 'nonsense') {
    my ($mode, $ct) = serve_mode($m);
    is $mode, 'download', (defined $m && length $m ? "$m" : '(empty)') . ' is download-only';
}

# Parameters and case must not be a way past the rule.
is( (serve_mode('image/svg+xml; charset=utf-8'))[0], 'download', 'svg with a charset param is still download-only' );
is( (serve_mode('  TEXT/HTML  '))[0],                'download', 'padded, upper-case text/html is still download-only' );

done_testing();
