package Homelab::Search::Serve;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(serve_mode viewable);

# THE RENDERING CONTRACT, in ONE place.
#
# It lives here rather than in the controller because the template needs the
# same answer: the page decides whether to offer an "Open" link and the server
# decides whether to honour it. Those were written twice, briefly, and two
# copies of a security rule is one copy too many -- they drift, and the drift
# shows up as either a link that silently downloads or a file you cannot view
# that you should be able to.
#
# Returns ($mode, $content_type) where $mode is 'inline' or 'download'.
#
# THE RULE THAT MATTERS: a user-uploaded text/html file -- or an SVG, which is
# an image type that executes script -- served `inline` from this origin is
# stored XSS against the search session. Those are download-only, always.
# Everything textual is served as text/plain rather than its own subtype for
# the same reason, so an HTML document that arrives as .txt or
# application/json cannot execute either. `nosniff` on the response is what
# stops the browser second-guessing that back into HTML.

my %INLINE_AS = (
    'application/pdf'  => 'application/pdf',
    'text/plain'       => 'text/plain; charset=utf-8',
    'text/csv'         => 'text/plain; charset=utf-8',
    'application/json' => 'text/plain; charset=utf-8',
);

# Never inline, whatever else matches.
my $NEVER_INLINE = qr{^(?:text/html|application/xhtml\+xml|image/svg\+xml|text/xml|application/xml)$};

sub serve_mode ($mime = undef) {
    my $m = lc($mime // '');
    $m =~ s/;.*$//;
    $m =~ s/\s+//g;

    return ('download', 'application/octet-stream') if $m =~ $NEVER_INLINE;
    return ('inline', $INLINE_AS{$m})               if $INLINE_AS{$m};
    # Any other text/* is still text: inline, but reduced to text/plain.
    return ('inline', 'text/plain; charset=utf-8')  if $m =~ m{^text/};
    # Media the browser renders natively and cannot execute.
    return ('inline', $m)                           if $m =~ m{^(?:image|audio|video)/};
    return ('download', 'application/octet-stream');
}

# What the page uses to decide whether to offer "Open" at all.
sub viewable ($mime = undef) {
    my ($mode) = serve_mode($mime);
    return $mode eq 'inline' ? 1 : 0;
}

1;
