package Homelab::Notes::Export;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Mojo::DOM;
use Mojo::Promise;
use Mojo::Util qw(xml_escape b64_encode);

our @EXPORT_OK = qw(source_ext export_name plain_text standalone_html inline_images_p pdf_ready_html public_image_ok);

# A note as a file (post-cutover #101): the body as written, the rendered
# note as plain text, one self-contained web page, and the same page laid out
# for paper (the PDF itself is made by homelab-worker from that page).
# Everything here is pure and takes the controller's cleaned HTML; nothing
# of a note reaches a file without having been through Clean.pm first.

# The extension of the body as typed.
sub source_ext ($format) {
    return 'md'   if ($format // '') eq 'markdown';
    return 'html' if ($format // '') eq 'html';
    return 'txt';
}

# A file name from a title: the characters a file system or a browser would
# choke on become spaces, 80 characters at most, never empty.
sub export_name ($title, $ext) {
    my $t = $title // '';
    $t =~ s/[\x00-\x1f\x7f"\\\/:*?<>|]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A\s+|\s+\z//g;
    $t = 'Untitled note' unless length $t;
    if (length($t) > 80) { $t = substr($t, 0, 80); $t =~ s/\s+\z//; }
    return "$t.$ext";
}

# The rendered note flattened to readable text: headings on their own lines,
# a blank line between blocks, "- " and "1. " for lists (nested ones
# indented), "text (url)" for links, "[image: alt]" for pictures, code kept
# as it is, table cells separated by two spaces.
sub plain_text ($html) {
    my $out = '';
    _walk(Mojo::DOM->new($html // ''), \$out, []);
    $out =~ s/[ \t]+$//mg;
    $out =~ s/\n{3,}/\n\n/g;
    $out =~ s/\A\n+//;
    $out =~ s/\s+\z//;
    return length $out ? "$out\n" : '';
}

my %BLOCK = map { $_ => 1 } qw(p div section article aside header footer main nav figure figcaption blockquote details summary dl dd dt address table thead tbody tfoot);
my %HEAD  = (h1 => '=', h2 => '-');

sub _block ($out) { $$out .= "\n" unless $$out eq '' || $$out =~ /\n\z/; $$out .= "\n" unless $$out eq '' || $$out =~ /\n\n\z/ }
sub _line  ($out) { $$out .= "\n" unless $$out eq '' || $$out =~ /\n\z/ }

sub _walk ($node, $out, $lists) {
    for my $n ($node->child_nodes->each) {
        my $type = $n->type;
        if ($type eq 'text' || $type eq 'raw') {
            my $t = $n->content;
            $t =~ s/\s+/ /g;
            $t =~ s/\A // if $$out eq '' || $$out =~ /[\s(]\z/;    # never two spaces at a join
            $$out .= $t;
            next;
        }
        next unless $type eq 'tag';
        my $tag = lc $n->tag;
        if ($tag eq 'br') { $$out .= "\n" }
        elsif ($tag eq 'hr') { _block($out); $$out .= "----"; _block($out) }
        elsif ($tag eq 'pre') {
            _block($out);
            my $code = join '', map { $_->content } $n->descendant_nodes->grep(sub { $_->type eq 'text' || $_->type eq 'raw' })->each;
            $code =~ s/\s+\z//;
            $$out .= $code;
            _block($out);
        }
        elsif ($tag =~ /\Ah([1-6])\z/) {
            my $level = $1;
            _block($out);
            my $start = length $$out;
            _walk($n, $out, $lists);
            my $text = substr($$out, $start) =~ s/\A\s+|\s+\z//gr;
            substr($$out, $start) = $text;
            $$out .= "\n" . ($HEAD{"h$level"} x length $text) if $HEAD{"h$level"} && length $text;
            _block($out);
        }
        elsif ($tag eq 'ul' || $tag eq 'ol') {
            _line($out) if @$lists; _block($out) unless @$lists;
            push @$lists, { tag => $tag, n => 0 };
            _walk($n, $out, $lists);
            pop @$lists;
            _line($out) if @$lists; _block($out) unless @$lists;
        }
        elsif ($tag eq 'li') {
            _line($out);
            my $l = $lists->[-1] // { tag => 'ul', n => 0 };
            my $pad = '  ' x (@$lists ? @$lists - 1 : 0);
            $$out .= $pad . ($l->{tag} eq 'ol' ? ++$l->{n} . '. ' : '- ');
            _walk($n, $out, $lists);
            _line($out);
        }
        elsif ($tag eq 'tr') { _line($out); _walk($n, $out, $lists); $$out =~ s/[ ]+\z//; _line($out) }
        elsif ($tag eq 'td' || $tag eq 'th') { _walk($n, $out, $lists); $$out .= '  ' }
        elsif ($tag eq 'a') {
            my $start = length $$out;
            _walk($n, $out, $lists);
            my $text = substr($$out, $start);
            my $href = $n->attr('href') // '';
            $$out .= " ($href)" if $href =~ m{\Ahttps?://}i && $text !~ /\Q$href\E/;
        }
        elsif ($tag eq 'img') { my $alt = $n->attr('alt') // ''; $$out .= length $alt ? "[image: $alt]" : '[image]' }
        elsif ($tag eq 'input') { $$out .= (exists $n->attr->{checked} ? '[x] ' : '[ ] ') if ($n->attr('type') // '') eq 'checkbox' }
        elsif ($tag eq 'dt') { _line($out); _walk($n, $out, $lists); _line($out) }
        elsif ($tag eq 'dd') { _line($out); $$out .= '  '; _walk($n, $out, $lists); _line($out) }
        elsif ($BLOCK{$tag}) { _block($out); _walk($n, $out, $lists); _block($out) }
        elsif ($tag eq 'script' || $tag eq 'style') { }
        else { _walk($n, $out, $lists) }
    }
    return;
}

# One self-contained web page: the title, a line saying where it came from,
# the cleaned body, a small stylesheet, no script. With for_pdf the same page
# gets its paper rules (Letter, numbered pages). Site-relative links ([[wiki
# links]] come as /n/ID) are made absolute with base.
sub standalone_html (%a) {
    my $title = length($a{title} // '') ? $a{title} : 'Untitled note';
    my $body  = $a{html} // '';
    if (my $base = $a{base}) {
        $base =~ s{/\z}{};
        my $dom = Mojo::DOM->new($body);
        $dom->find('a[href^="/"]')->each(sub { $_->attr(href => $base . $_->attr('href')) });
        $body = "$dom";
    }
    my @meta;
    push @meta, 'From the notebook ' . xml_escape($a{notebook}) if length($a{notebook} // '');
    push @meta, 'last changed ' . xml_escape($a{updated})       if length($a{updated} // '');
    push @meta, '<a href="' . xml_escape($a{url}) . '">' . xml_escape($a{url} =~ s{\Ahttps?://}{}r) . '</a>' if length($a{url} // '');
    my $paper = $a{for_pdf} ? '@page { size: Letter; margin: 2cm 1.9cm 2.2cm; @bottom-right { content: counter(page) " / " counter(pages); font: 9pt Inter, "DejaVu Sans", sans-serif; color: #777 } @bottom-left { content: "' . _css_string($title) . '"; font: 9pt Inter, "DejaVu Sans", sans-serif; color: #777; max-width: 70% } }' . "\n" : '';
    return '<!doctype html>' . "\n" . '<html lang="en">' . "\n" . '<head>' . "\n"
         . '<meta charset="utf-8">' . "\n" . '<meta name="viewport" content="width=device-width, initial-scale=1">' . "\n"
         . '<title>' . xml_escape($title) . '</title>' . "\n"
         . '<style>' . "\n" . $paper . _css() . '</style>' . "\n" . '</head>' . "\n"
         . '<body>' . "\n" . '<header>' . "\n" . '<h1>' . xml_escape($title) . '</h1>' . "\n"
         . (@meta ? '<p class="meta">' . join(' &middot; ', @meta) . '</p>' . "\n" : '')
         . '</header>' . "\n" . '<main class="note-body">' . "\n" . $body . "\n" . '</main>' . "\n" . '</body>' . "\n" . '</html>' . "\n";
}

sub _css_string ($s) { return $s =~ s/\\/\\\\/gr =~ s/"/\\"/gr =~ s/[\r\n]+/ /gr }

sub _css { return <<'CSS' }
body { font-family: Inter, "DejaVu Sans", "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.55; color: #16181c; background: #fff; max-width: 46rem; margin: 2rem auto; padding: 0 1.2rem }
header { border-bottom: 1px solid #d8dbe0; padding-bottom: .8rem; margin-bottom: 1.4rem }
h1 { font-size: 1.9rem; line-height: 1.2; margin: 0 0 .4rem; letter-spacing: -.01em } .meta { color: #6b7280; font-size: .85rem; margin: 0 } .meta a { color: inherit }
h2 { font-size: 1.35rem; margin: 1.6em 0 .5em } h3 { font-size: 1.12rem; margin: 1.4em 0 .4em } h4, h5, h6 { font-size: 1rem; margin: 1.2em 0 .3em }
p, ul, ol, blockquote, pre, table, figure, dl { margin: 0 0 .9em } li { margin: .15em 0 } li > ul, li > ol { margin-bottom: 0 }
a { color: #1a56db } a.wikilink { text-decoration: none; border-bottom: 1px dotted #1a56db } .wikilink--missing { color: #9ca3af; border-bottom: 1px dotted #9ca3af }
code, kbd, samp { font-family: "DejaVu Sans Mono", Menlo, Consolas, "Liberation Mono", monospace; font-size: .92em; background: #f3f4f6; padding: .1em .3em; border-radius: 3px }
pre { background: #f3f4f6; padding: .8em 1em; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; line-height: 1.45 } pre code { background: none; padding: 0; font-size: .9em }
blockquote { border-left: 3px solid #cbd5e1; margin-left: 0; padding: .1em 0 .1em 1em; color: #4b5563 }
table { border-collapse: collapse; width: 100%; font-size: .95em } th, td { border: 1px solid #d1d5db; padding: .35em .6em; text-align: left; vertical-align: top } th { background: #f3f4f6 }
img { max-width: 100%; height: auto } figcaption { color: #6b7280; font-size: .85em } hr { border: 0; border-top: 1px solid #d8dbe0; margin: 1.5em 0 }
input[type=checkbox] { margin-right: .4em } .task { font-family: "DejaVu Sans", "Segoe UI Symbol", sans-serif; margin-right: .3em } .img-missing { color: #9ca3af; font-style: italic }
mark { background: #fde68a } del, s { color: #6b7280 }
@media print { body { margin: 0; max-width: none; padding: 0 } a { color: #1a3f9e } pre, blockquote, table, img { page-break-inside: avoid } h1, h2, h3 { page-break-after: avoid } }
CSS

# Which of a note's images this app fetches for the PDF: https to a public
# name only, never an IP address or a fleet-internal name (the same rule as
# the worker's zip job, post-cutover #53).
sub public_image_ok ($url) {
    my ($scheme, $host) = ($url // '') =~ m{\A([a-z][a-z0-9+.-]*)://(?:[^/@]*@)?(\[[^\]]*\]|[^/:?#]*)}i;
    return 0 unless defined $host && length $host;
    $host = lc $host;
    return 0 unless lc $scheme eq 'https';
    return 0 if $host =~ /\A\[|\A[\d.]+\z/;
    return 0 if $host !~ /\./ || $host =~ /(?:\A|\.)(?:localhost|svc\.homelab|homelab|internal|local|lan|home\.arpa)\z/;
    return 1;
}

# Fetches the images of a note and puts them into the page as data: URLs, so
# the worker that lays out the PDF never fetches anything. At most max_images
# (10), each at most max_bytes (3 MB; checked here on the body, the agent's
# own max_response_size being a backstop); an image that cannot be had is
# left for pdf_ready_html to replace with its alt text. Resolves to the
# rewritten HTML; never rejects.
sub inline_images_p ($html, $ua, %o) {
    my $max   = $o{max_images} // 10;
    my $bytes = $o{max_bytes} // 3 * 1024 * 1024;
    my $dom = Mojo::DOM->new($html // '');
    my @imgs = grep { ($_->attr('src') // '') =~ m{\Ahttps?://}i } $dom->find('img[src]')->each;
    return Mojo::Promise->resolve("$dom") unless @imgs;
    my @fetch = grep { public_image_ok($_->attr('src')) } @imgs[0 .. ($#imgs < $max - 1 ? $#imgs : $max - 1)];
    return Mojo::Promise->resolve("$dom") unless @fetch;
    my @p = map {
        my $img = $_;
        $ua->get_p($img->attr('src'))->then(sub ($tx) {
            my $res = $tx->res;
            # $tx->error, not only the status: one over the size cap is a 200
            # with a cut body and "Maximum message size exceeded" as its error.
            return if $tx->error || !$res->is_success;
            return if length($res->body) > $bytes;
            my $type = $res->headers->content_type // '';
            return unless $type =~ m{\Aimage/[a-z0-9.+-]+}i;
            ($type) = $type =~ m{\A(image/[a-z0-9.+-]+)}i;
            $img->attr(src => "data:$type;base64," . b64_encode($res->body, ''));
            return;
        })->catch(sub { return });
    } @fetch;
    return Mojo::Promise->all_settled(@p)->then(sub { return "$dom" });
}

# What goes to the worker: nothing that would make it fetch. An image that is
# not inlined becomes its alt text; elements that load are dropped.
sub pdf_ready_html ($html) {
    my $dom = Mojo::DOM->new($html // '');
    $dom->find('link, script, style, object, embed, iframe, frame, base, form, video, audio, source')->each(sub { $_->remove });
    $dom->find('img')->each(sub {
        my $src = $_->attr('src') // '';
        return if $src =~ /\A\s*data:/i;
        my $alt = $_->attr('alt') // '';
        $_->replace('<span class="img-missing">' . xml_escape(length $alt ? "[image: $alt]" : '[image]') . '</span>');
    });
    $dom->find('[style]')->each(sub { delete $_->attr->{style} });
    $dom->find('[srcset], [poster], [background]')->each(sub { delete @{ $_->attr }{qw(srcset poster background)} });
    # A task's checkbox as a glyph: WeasyPrint draws an <input> as a form
    # field that breaks the line, and a box on paper is a box.
    $dom->find('input[type="checkbox"]')->each(sub {
        $_->replace('<span class="task">' . (exists $_->attr->{checked} ? "\x{2611}" : "\x{2610}") . '</span>');
    });
    return "$dom";
}

1;
