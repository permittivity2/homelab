package Homelab::Common::QRCode;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(qr_svg qr_available);

# QR codes, rendered as SVG, for handing a URL from a screen to a phone.
#
# The one job here is the cross-device moment: someone finishes creating
# an account on a laptop, and the thing that has to happen next -- adding
# the mailbox -- happens on a phone they are holding. A link is useless
# across that gap and a 60-character URL is worse than useless to retype.
#
# SVG, not PNG, on purpose. It stays sharp on every display, it is a few
# hundred bytes, it needs no image library, and it can be inlined straight
# into a page. The one place SVG is NOT safe is email -- Gmail and Outlook
# both strip it -- which is why no mail this fleet sends embeds a QR code:
# the mails carry a link, and the page that link opens carries the code.
#
# Text::QRCode is loaded LAZILY and its absence is not fatal. homelab-common
# is installed on every host in the fleet; a hard dependency here would put
# libqrencode on fifty machines to serve two. The two packages that actually
# render codes (homelab-invite, homelab-accountmanage) declare the dependency
# themselves, and everywhere else qr_svg() simply returns undef -- callers
# fall back to showing the link, which is the correct degraded behaviour
# anyway.

my $CHECKED;
my $ENCODER;

sub _encoder () {
    return $ENCODER if $CHECKED;
    $CHECKED = 1;
    $ENCODER = eval { require Text::QRCode; Text::QRCode->new };
    return $ENCODER;
}

# True if this host can actually render a code. Lets a template decide
# between "here is a QR code" and "here is a link" without calling the
# renderer and testing for undef.
sub qr_available () { return _encoder() ? 1 : 0 }

# qr_svg($text, %opts) -> SVG string, or undef if unavailable/too long.
#
#   module  px per QR module in the rendered size      (default 6)
#   quiet   quiet-zone width in modules                (default 4)
#   dark    colour of the set modules                  (default #000)
#   light   background colour                          (default #fff)
#   title   accessible title element text
#
# The quiet zone defaults to 4 modules because that is the minimum the QR
# spec requires for reliable acquisition. It is tempting to trim it to
# make the image smaller on a crowded card; don't -- a code with no
# margin against a dark page background is the classic reason a scan that
# "looks fine" never fires.
sub qr_svg ($text, %opts) {
    return undef unless defined $text && length $text;
    my $enc = _encoder() or return undef;

    my $rows = eval { $enc->plot($text) };
    return undef unless $rows && ref $rows eq 'ARRAY' && @$rows;

    my $module = $opts{module} // 6;
    my $quiet  = $opts{quiet}  // 4;
    my $dark   = $opts{dark}   // '#000000';
    my $light  = $opts{light}  // '#ffffff';

    my $n    = scalar @$rows;
    my $side = $n + 2 * $quiet;
    my $px   = $side * $module;

    # One <path> of horizontal runs rather than one <rect> per module: a
    # 29x29 code is up to 841 elements as rects and typically well under
    # a hundred subpaths as runs, which is the difference between an
    # inline SVG that bloats the page and one that does not.
    my @d;
    for my $y (0 .. $n - 1) {
        my $row = $rows->[$y];
        my $x = 0;
        my $cols = scalar @$row;
        while ($x < $cols) {
            unless (defined $row->[$x] && $row->[$x] eq '*') { $x++; next }
            my $start = $x;
            $x++ while $x < $cols && defined $row->[$x] && $row->[$x] eq '*';
            my $run = $x - $start;
            push @d, sprintf('M%d %dh%dv1h-%dz', $start + $quiet, $y + $quiet, $run, $run);
        }
    }
    return undef unless @d;

    my $title = $opts{title};
    my $title_el = (defined $title && length $title)
        ? '<title>' . _esc($title) . '</title>' : '';

    # viewBox in MODULE units with width/height in px: the browser scales
    # it, so the same string can be rendered at any size, and
    # shape-rendering=crispEdges keeps module edges from being
    # antialiased into grey at small sizes (which is what makes a scaled
    # QR code fail to scan).
    return sprintf(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
        . 'shape-rendering="crispEdges" role="img">%s'
        . '<rect width="%d" height="%d" fill="%s"/>'
        . '<path fill="%s" d="%s"/></svg>',
        $px, $px, $side, $side, $title_el,
        $side, $side, _esc($light),
        _esc($dark), join('', @d),
    );
}

sub _esc ($s) {
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

1;

__END__

=head1 NAME

Homelab::Common::QRCode - render a QR code as inline SVG

=head1 SYNOPSIS

    use Homelab::Common::QRCode qw(qr_svg qr_available);

    my $svg = qr_svg('https://example.org/setup', module => 7);

=head1 DESCRIPTION

Wraps Text::QRCode and renders the result as a compact SVG. Returns undef
rather than dying when Text::QRCode is not installed, so callers on hosts
without it degrade to showing a plain link.

=cut
