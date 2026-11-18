package Homelab::Notes::Markdown;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(markdown_to_html);

# Markdown to HTML, the GitHub-flavoured subset a note needs, in pure Perl
# (post-cutover #71): headings (# and underlined), paragraphs with hard
# breaks, bullet and numbered lists with nesting and task boxes, quotes,
# fenced and indented code, rules, pipe tables, links, images, bare URLs,
# emphasis, strong, strikethrough, code spans, backslash escapes, and HTML
# typed into the note passed through as it is.
#
# THE OUTPUT IS NOT SAFE BY ITSELF: typed HTML comes through untouched, so
# every rendered body goes through Homelab::Notes::Clean after this (see
# Render.pm). That is the one gate, so this module can stay simple.
#
# Not CommonMark-complete on purpose: reference-style links, setext headings
# over several lines, lazy continuation inside quotes in lists, and the
# finer emphasis rules are left out. A note is written by its own reader.

# Text that goes between tags: entities typed on purpose (&copy; &#169;)
# stay, everything else is escaped.
sub _esc ($s) {
    $s //= '';
    $s =~ s/&(?![a-zA-Z][a-zA-Z0-9]{1,31};|#\d{1,7};|#[xX][0-9a-fA-F]{1,6};)/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}
sub _attr ($s) { my $t = _esc($s); $t =~ s/"/&quot;/g; return $t }

sub markdown_to_html ($text) {
    $text //= '';
    $text =~ s/\r\n?/\n/g;
    $text =~ s/\t/    /g;
    my @lines = split /\n/, $text, -1;
    pop @lines while @lines && $lines[-1] !~ /\S/;
    return _blocks(\@lines);
}

# --------------------------------------------------------------------- blocks

my $RE_FENCE   = qr/\A {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*\z/;
my $RE_ATX     = qr/\A {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*(?:[ \t]#+)?[ \t]*\z/;
my $RE_HR      = qr/\A {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*\z/;
my $RE_QUOTE   = qr/\A {0,3}>/;
my $RE_BULLET  = qr/\A( {0,3})([-+*])( +|\z)(.*)\z/;
my $RE_ORDERED = qr/\A( {0,3})(\d{1,9})([.)])( +|\z)(.*)\z/;
my $RE_TABLE_D = qr/\A {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*\z/;
my $RE_HTML    = qr{\A {0,3}<(?:/?(?:address|article|aside|blockquote|details|dialog|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|iframe|li|main|nav|ol|p|pre|script|section|style|summary|table|tbody|td|tfoot|th|thead|tr|ul|video|audio|img|center|font)(?:[\s/>]|\z)|!--)}i;

sub _blank ($l) { return !defined $l || $l !~ /\S/ }

# A line that starts a block other than a paragraph (what may interrupt one).
sub _starts_block ($l) {
    return 0 if _blank($l);
    return 1 if $l =~ $RE_FENCE || $l =~ $RE_ATX || $l =~ $RE_HR || $l =~ $RE_QUOTE || $l =~ $RE_HTML;
    return 1 if $l =~ $RE_BULLET && length $4 || ($l =~ $RE_BULLET && $3 eq '');
    return 1 if $l =~ $RE_ORDERED && $2 == 1;
    return 0;
}

sub _blocks ($lines) {
    my @out;
    my $i = 0;
    my $n = @$lines;
    while ($i < $n) {
        my $l = $lines->[$i];
        if (_blank($l)) { $i++; next }

        # Fenced code.
        if ($l =~ $RE_FENCE) {
            my ($fence, $info) = ($1, $2);
            my $ch = substr $fence, 0, 1;
            my $len = length $fence;
            my @code;
            $i++;
            while ($i < $n) {
                my $c = $lines->[$i];
                last if $c =~ /\A {0,3}\Q$ch\E{$len,}[ \t]*\z/;
                push @code, $c;
                $i++;
            }
            $i++;    # the closing fence (or EOF)
            my $cls = length $info ? ' class="language-' . _attr($info) . '"' : '';
            push @out, "<pre><code$cls>" . _esc(join("\n", @code)) . (@code ? "\n" : '') . "</code></pre>";
            next;
        }

        # ATX heading.
        if ($l =~ $RE_ATX) {
            my $level = length $1;
            push @out, "<h$level>" . _inline($2 // '') . "</h$level>";
            $i++;
            next;
        }

        # Rule (before lists: "* * *" is a rule, not a list).
        if ($l =~ $RE_HR) { push @out, '<hr>'; $i++; next }

        # Quote: strip one marker level from every line of the run and recurse.
        if ($l =~ $RE_QUOTE) {
            my @inner;
            while ($i < $n && !_blank($lines->[$i]) && ($lines->[$i] =~ $RE_QUOTE || !_starts_block($lines->[$i]))) {
                my $q = $lines->[$i];
                $q =~ s/\A {0,3}> ?//;
                push @inner, $q;
                $i++;
            }
            push @out, "<blockquote>\n" . _blocks(\@inner) . "\n</blockquote>";
            next;
        }

        # Lists.
        if ($l =~ $RE_BULLET || $l =~ $RE_ORDERED) {
            my ($html, $next) = _list($lines, $i);
            push @out, $html;
            $i = $next;
            next;
        }

        # Pipe table: a header line with a pipe, then the delimiter row.
        if ($l =~ /\|/ && $i + 1 < $n && $lines->[$i + 1] =~ $RE_TABLE_D && !_starts_block($l)) {
            my @head = _cells($l);
            my @delim = _cells($lines->[$i + 1]);
            if (@head && @delim >= @head) {
                my @align = map { /\A:-+:\z/ ? 'center' : /-:\z/ ? 'right' : /\A:-/ ? 'left' : '' } @delim;
                my $th = join '', map { my $a = $align[$_] ? qq{ align="$align[$_]"} : ''; "<th$a>" . _inline($head[$_]) . '</th>' } 0 .. $#head;
                my @rows;
                $i += 2;
                while ($i < $n && !_blank($lines->[$i]) && !_starts_block($lines->[$i])) {
                    my @c = _cells($lines->[$i]);
                    push @c, '' while @c < @head;
                    push @rows, '<tr>' . join('', map { my $a = $align[$_] ? qq{ align="$align[$_]"} : ''; "<td$a>" . _inline($c[$_]) . '</td>' } 0 .. $#head) . '</tr>';
                    $i++;
                }
                push @out, "<table>\n<thead><tr>$th</tr></thead>" . (@rows ? "\n<tbody>\n" . join("\n", @rows) . "\n</tbody>" : '') . "\n</table>";
                next;
            }
        }

        # Indented code.
        if ($l =~ /\A {4}/) {
            my @code;
            while ($i < $n && ($lines->[$i] =~ /\A {4}/ || _blank($lines->[$i]))) {
                my $c = $lines->[$i];
                $c =~ s/\A {4}//;
                push @code, $c;
                $i++;
            }
            pop @code while @code && _blank($code[-1]);
            push @out, '<pre><code>' . _esc(join("\n", @code)) . "\n</code></pre>";
            next;
        }

        # A block of HTML as typed: through to Clean, which decides what stays.
        if ($l =~ $RE_HTML) {
            my @raw;
            if ($l =~ /\A {0,3}<!--/) {
                while ($i < $n) { push @raw, $lines->[$i]; last if $lines->[$i++] =~ /-->/ }
            } else {
                while ($i < $n && !_blank($lines->[$i])) { push @raw, $lines->[$i++] }
            }
            push @out, join("\n", @raw);
            next;
        }

        # Paragraph, possibly a setext heading (one line underlined).
        my @para = ($l);
        $i++;
        while ($i < $n && !_blank($lines->[$i])) {
            my $c = $lines->[$i];
            if (@para == 1 && $c =~ /\A {0,3}(=+|-+)[ \t]*\z/) {
                my $level = substr($1, 0, 1) eq '=' ? 1 : 2;
                push @out, "<h$level>" . _inline($para[0]) . "</h$level>";
                @para = ();
                $i++;
                last;
            }
            last if _starts_block($c);
            push @para, $c;
            $i++;
        }
        push @out, '<p>' . _inline(join("\n", map { s/\A\s+//r } @para)) . '</p>' if @para;
    }
    return join "\n", @out;
}

# One list starting at $start: returns (html, index after the list).
sub _list ($lines, $start) {
    my $n = @$lines;
    my $first = $lines->[$start];
    my $ordered = $first =~ $RE_ORDERED ? 1 : 0;
    my ($marker_re, $startno, $delim);
    if ($ordered) { $first =~ $RE_ORDERED; $startno = $2 + 0; $delim = $3; $marker_re = qr/\A( {0,3})(\d{1,9})(\Q$delim\E)( +|\z)(.*)\z/ }
    else          { $first =~ $RE_BULLET;  my $m = $2; $marker_re = qr/\A( {0,3})(\Q$m\E)( +|\z)(.*)\z/ }

    my @items;      # each: arrayref of content lines (indentation removed)
    my $loose = 0;
    my $i = $start;
    my $blank_before = 0;
    while ($i < $n) {
        my $l = $lines->[$i];
        if (_blank($l)) {
            # A blank line ends the list unless another item or an indented
            # continuation follows.
            my $j = $i;
            $j++ while $j < $n && _blank($lines->[$j]);
            last if $j >= $n;
            my $nx = $lines->[$j];
            if ($nx =~ $marker_re || $nx =~ /\A {2,}\S/) {
                push @{ $items[-1] }, '' if @items;    # keep the gap inside the item
                $loose = 1 if $nx =~ $marker_re || $i + 1 < $j || 1;
                $i = $j;
                $blank_before = 1;
                next;
            }
            last;
        }
        if (@items && $l =~ /\A {$items[-1][0]{col}}/) {               # indented at least to the item: its continuation (a nested list, a paragraph)
            push @{ $items[-1] }, substr($l, $items[-1][0]{col});
            $i++;
            next;
        }
        if ($l =~ $marker_re) {
            my $indent = length $1;
            my $marker = $ordered ? "$2$3" : $2;
            my ($sp, $rest) = $ordered ? ($4, $5) : ($3, $4);
            my $col = $indent + length($marker) + (length($sp) > 4 || $sp eq '' ? 1 : length $sp);
            $rest = ' ' x (length($sp) - 1) . $rest if length($sp) > 4;
            push @items, [ { col => $col, loose => $blank_before }, $rest ];
            $blank_before = 0;
            $i++;
            next;
        }
        last unless @items;
        # Lazy continuation of the item's paragraph; anything else ends the list.
        last if _starts_block($l) || $l =~ $RE_BULLET || $l =~ $RE_ORDERED;
        last if @{ $items[-1] } > 1 && _blank($items[-1][-1]);
        push @{ $items[-1] }, $l =~ s/\A\s+//r;
        $i++;
    }

    my @li;
    for my $it (@items) {
        my $meta = shift @$it;
        $loose = 1 if $meta->{loose} || grep { _blank($_) } @$it[0 .. $#$it - 1];
    }
    for my $it (@items) {
        pop @$it while @$it > 1 && _blank($it->[-1]);
        my $task = '';
        if (@$it && $it->[0] =~ s/\A\[([ xX])\] +//) {
            $task = '<input type="checkbox" disabled' . ($1 eq ' ' ? '' : ' checked') . '> ';
        }
        my $html = _blocks($it);
        $html =~ s{<p>(.*?)<\/p>}{$1}gs unless $loose;    # tight: paragraphs are bare text
        push @li, "<li>$task$html</li>";
    }
    my $tag = $ordered ? 'ol' : 'ul';
    my $attr = ($ordered && $startno != 1) ? qq{ start="$startno"} : '';
    return ("<$tag$attr>\n" . join("\n", @li) . "\n</$tag>", $i);
}

# The cells of a table row, pipes escaped with a backslash kept as pipes.
sub _cells ($row) {
    $row =~ s/\A\s*\|?//;
    $row =~ s/\|?\s*\z//;
    my @c = split /(?<!\\)\|/, $row, -1;
    return map { s/\A\s+|\s+\z//gr =~ s/\\\|/|/gr } @c;
}

# --------------------------------------------------------------------- inline

my $RE_TAG = qr{</?[a-zA-Z][a-zA-Z0-9-]*(?:\s+[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>|<!--.*?-->}s;
my $RE_URL = qr{https?://[^\s<]*[^\s<.,:;"'\)\]!?*_~]};

sub _inline ($text) {
    my @ph;
    my $put = sub ($html) { push @ph, $html; return "\x01" . $#ph . "\x02" };

    # Backslash escapes first: an escaped character takes part in nothing below.
    $text =~ s/\\([\\`*_{}\[\]()#+\-.!|~<>"'])/$put->(_esc($1))/ge;
    # Code spans: equal runs of backticks.
    $text =~ s/(`+)(?!`)(.+?)(?<!`)\1(?!`)/$put->('<code>' . _esc($2 =~ s{\A | \z}{}gr) . '<\/code>')/gse;
    # Autolinks in angle brackets.
    $text =~ s/<((?:https?|mailto):[^\s<>]+)>/$put->('<a href="' . _attr($1) . '">' . _esc($1 =~ s{\Amailto:}{}r) . '<\/a>')/ge;
    $text =~ s/<([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})>/$put->('<a href="mailto:' . _attr($1) . '">' . _esc($1) . '<\/a>')/ge;
    # HTML typed into the note, through to Clean as it is.
    $text =~ s/($RE_TAG)/$put->($1)/ge;

    $text = _esc($text);

    # Images, then links (a link's text may carry emphasis), then bare URLs.
    $text =~ s/!\[([^\]]*)\]\(\s*((?:[^\s()]|\([^\s()]*\))+)(?:\s+"([^"]*)")?\s*\)/$put->('<img src="' . _attr($2) . '" alt="' . _attr($1) . '"' . (defined $3 ? ' title="' . _attr($3) . '"' : '') . '>')/ge;
    $text =~ s/\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*((?:[^\s()]|\([^\s()]*\))+)(?:\s+"([^"]*)")?\s*\)/$put->('<a href="' . _attr($2) . '"' . (defined $3 ? ' title="' . _attr($3) . '"' : '') . '>' . _spans($1) . '<\/a>')/ge;
    $text =~ s/(?<![\w\/"=])($RE_URL)/$put->('<a href="' . _attr($1) . '">' . $1 . '<\/a>')/ge;

    $text = _spans($text);

    1 while $text =~ s/\x01(\d+)\x02/$ph[$1]/g;
    return $text;
}

# Emphasis, strong, strikethrough and hard breaks on escaped text.
sub _spans ($t) {
    $t =~ s/\*\*(?=\S)(.+?)(?<=\S)\*\*/<strong>$1<\/strong>/gs;
    $t =~ s/(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])/<strong>$1<\/strong>/gs;
    $t =~ s/\*(?=[^\s*])(.+?)(?<=[^\s*])\*/<em>$1<\/em>/gs;
    $t =~ s/(?<![\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w])/<em>$1<\/em>/gs;
    $t =~ s/~~(?=\S)(.+?)(?<=\S)~~/<del>$1<\/del>/gs;
    $t =~ s/(?: {2,}|\\)\n/<br>\n/g;
    return $t;
}

1;
