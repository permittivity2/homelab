use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Homelab::Common::QRCode qw(qr_svg qr_available);

# A QR code cannot be eyeballed, and there is no QR decoder in this
# fleet's test environment to check one against. What CAN be checked, and
# is where the bugs actually live, is the rendering layer this module
# owns: the run-length packing of modules into SVG subpaths, the quiet
# zone offset, and the viewBox arithmetic. So the SVG is parsed back into
# a matrix and compared module-for-module with what the encoder produced.
# The encoder itself is libqrencode and is not this module's to verify.

unless (qr_available()) {
    plan skip_all => 'Text::QRCode (libtext-qrcode-perl) not installed';
}

my $URL = 'https://invite.mailmasker.org/setup/apple?t=v1.YUBiLm9yZw.1793261999.abcdef';

# Rebuild the module matrix from the rendered SVG: parse every
# "M<x> <y>h<w>v1h-<w>z" subpath back into filled cells.
sub matrix_from_svg ($svg, $side) {
    my ($d) = $svg =~ /<path fill="[^"]*" d="([^"]*)"/ or die "no path in svg\n";
    my @m = map { [ (0) x $side ] } 1 .. $side;
    while ($d =~ /M(\d+) (\d+)h(\d+)v1h-(\d+)z/g) {
        my ($x, $y, $w, $back) = ($1, $2, $3, $4);
        die "run width and return width disagree\n" unless $w == $back;
        $m[$y][$x + $_] = 1 for 0 .. $w - 1;
    }
    return \@m;
}

my $quiet  = 4;
my $module = 6;
my $svg    = qr_svg($URL, module => $module, quiet => $quiet, title => 'Scan me');
ok defined $svg, 'a code was rendered';

my $plot = Text::QRCode->new->plot($URL);
my $n    = scalar @$plot;
my $side = $n + 2 * $quiet;

subtest 'svg envelope' => sub {
    like $svg, qr/^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/, 'is an SVG element';
    like $svg, qr/viewBox="0 0 $side $side"/,  'viewBox is in module units including the quiet zone';
    my $px = $side * $module;
    like $svg, qr/width="$px" height="$px"/,   'pixel size is side * module';
    like $svg, qr/shape-rendering="crispEdges"/,
        'crispEdges -- antialiased module edges are what make a scaled code fail to scan';
    like $svg, qr/<title>Scan me<\/title>/,    'accessible title';
    like $svg, qr/<rect width="$side" height="$side" fill="#ffffff"\/>/,
        'opaque light background -- the page behind it is dark';
};

subtest 'every module survives the round trip' => sub {
    my $m = matrix_from_svg($svg, $side);
    my ($set, $mismatch) = (0, 0);
    for my $y (0 .. $n - 1) {
        for my $x (0 .. $n - 1) {
            my $want = ($plot->[$y][$x] // ' ') eq '*' ? 1 : 0;
            $set++ if $want;
            $mismatch++ if $want != $m->[$y + $quiet][$x + $quiet];
        }
    }
    ok $set > 0, "the encoder produced a non-empty matrix ($set dark modules)";
    is $mismatch, 0, 'rendered SVG matches the encoder matrix exactly';
};

subtest 'the quiet zone is actually empty' => sub {
    # A code drawn flush to the edge of its background scans unreliably
    # against a dark page. This asserts the margin is really blank rather
    # than just that the viewBox is bigger.
    my $m = matrix_from_svg($svg, $side);
    my $dirty = 0;
    for my $y (0 .. $side - 1) {
        for my $x (0 .. $side - 1) {
            next if $x >= $quiet && $x < $quiet + $n && $y >= $quiet && $y < $quiet + $n;
            $dirty++ if $m->[$y][$x];
        }
    }
    is $dirty, 0, "all $quiet modules of margin are clear on every side";
};

subtest 'finder patterns are where a scanner will look for them' => sub {
    # Independent of the round-trip check above: this verifies the
    # geometry is the right way up and not transposed or mirrored, which
    # a symmetric comparison against the same source would not catch.
    my $m = matrix_from_svg($svg, $side);
    for my $corner ([0, 0, 'top-left'], [$n - 7, 0, 'top-right'], [0, $n - 7, 'bottom-left']) {
        my ($ox, $oy, $name) = @$corner;
        my $ok = 1;
        for my $dy (0 .. 6) {
            for my $dx (0 .. 6) {
                # 7x7 finder: solid border ring, one-module gap, 3x3 core.
                my $edge  = ($dx == 0 || $dx == 6 || $dy == 0 || $dy == 6);
                my $core  = ($dx >= 2 && $dx <= 4 && $dy >= 2 && $dy <= 4);
                my $want  = ($edge || $core) ? 1 : 0;
                $ok = 0 if $m->[$oy + $dy + $quiet][$ox + $dx + $quiet] != $want;
            }
        }
        ok $ok, "$name finder pattern is correct";
    }
};

subtest 'options and edge cases' => sub {
    my $small = qr_svg('x', module => 3, quiet => 0);
    like $small, qr/viewBox="0 0 (\d+) \1"/, 'zero quiet zone still renders a square';
    my $dark = qr_svg('x', dark => '#112233', light => '#eeddcc');
    like $dark, qr/fill="#eeddcc"/, 'light colour applied to the background';
    like $dark, qr/fill="#112233"/, 'dark colour applied to the modules';

    is qr_svg(undef),  undef, 'undef input renders nothing';
    is qr_svg(''),     undef, 'empty input renders nothing';
    # Past libqrencode's capacity. Must come back undef so the caller can
    # fall back to a plain link, not die inside a page render.
    is qr_svg('x' x 10000), undef, 'an over-long payload degrades to undef rather than dying';
};

subtest 'markup injection through the options' => sub {
    my $svg = qr_svg('x', title => '</title><script>alert(1)</script>');
    unlike $svg, qr/<script>/, 'title is escaped';
    my $c = qr_svg('x', dark => '"/><script>bad()</script><path d="');
    unlike $c, qr/<script>/, 'colour is escaped';
};

done_testing();
