package Homelab::Worker::JobType::HtmlPdf;
use Mojo::Base -strict, -signatures;

use File::Spec;
use Mojo::DOM;
use Mojo::File qw(path);

# One HTML document in, one PDF out, laid out by WeasyPrint (post-cutover
# #101, for a note's "Download as PDF"). Generic: the caller sends a complete,
# self-contained document; this knows nothing about notes. $input shape:
#   { output_name => "Groceries.pdf", html => "<!doctype html>..." }
# Runs inside Homelab::Worker::App's forked subprocess child and returns the
# PDF's local path (inside $workdir), or dies with the job's error_message.
use constant MAX_HTML_BYTES => 4 * 1024 * 1024;

# May this document be laid out here? WeasyPrint fetches whatever a document
# references (images, stylesheets, fonts), from THIS node, so a document that
# points at anything is refused: every src must be a data: URL, no element
# that loads a resource, no url() or @import in a style. The caller inlines
# what it wants shown (homelab-notes fetches a note's images itself, to a
# cap, before it submits). Defence in depth, like Zip's url_refusal; checked
# at submission too (Controller::Jobs::create). Returns a message, or ''.
sub html_refusal ($html) {
    return 'html must be a string' unless defined $html && !ref $html;
    return 'html is empty' unless $html =~ /\S/;
    return 'html is too large (4 MB at most)' if length($html) > MAX_HTML_BYTES;
    my $dom = Mojo::DOM->new($html);
    for my $tag (qw(link script object embed iframe frame applet base form)) {
        return "a <$tag> element is not allowed" if $dom->at($tag);
    }
    for my $e ($dom->find('*')->each) {
        for my $attr (qw(src srcset poster data background xlink:href)) {
            my $v = $e->attr($attr);
            next unless defined $v;
            return "$attr may only be a data: URL (got '" . substr($v, 0, 60) . "')" unless $v =~ /\A\s*data:/i;
        }
        my $style = $e->attr('style');
        return 'a style attribute may not load anything' if defined $style && _style_loads($style);
    }
    for my $s ($dom->find('style')->each) {
        return 'a stylesheet in the document may not load anything' if _style_loads($s->all_text);
    }
    return '';
}

sub _style_loads ($css) {
    return 1 if $css =~ /\@import/i;
    while ($css =~ /url\s*\(\s*(["']?)\s*([^"')\s]*)/gi) {
        return 1 unless $2 =~ /\Adata:/i;
    }
    return 0;
}

sub run ($input, $workdir, $progress_cb = undef, @) {
    my $html = $input->{html};
    my $why  = html_refusal($html);
    die "html_pdf job: $why\n" if $why;

    my $in  = File::Spec->catfile($workdir, 'in.html');
    my $out = File::Spec->catfile($workdir, 'out.pdf');
    path($in)->spew($html, 'UTF-8');
    $progress_cb->(0, 1) if $progress_cb;

    # WeasyPrint and fontconfig want a home to cache in; the job's own scratch
    # dir is that, and goes with it. `timeout` bounds a runaway layout well
    # inside the engine's own no-progress reclaim. stderr (a missing font, an
    # image it could not decode) goes to the journal with the service's log.
    local $ENV{HOME}           = $workdir;
    local $ENV{XDG_CACHE_HOME} = "$workdir/.cache";
    my @cmd = ('timeout', '120', 'weasyprint', '--encoding', 'utf-8', '--media-type', 'print', $in, $out);
    my $rc = system(@cmd);
    if ($rc != 0) {
        my $what = $rc == -1 ? "could not run weasyprint: $!"
                 : ($rc >> 8) == 124 ? 'weasyprint timed out after 120 s'
                 : 'weasyprint exited ' . ($rc >> 8);
        die "html_pdf job: $what\n";
    }
    die "html_pdf job: weasyprint wrote no PDF\n" unless -s $out;
    $progress_cb->(1, 1) if $progress_cb;
    return $out;
}

1;
