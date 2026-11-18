package Homelab::Notes::Wikitext;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Homelab::Notes::Links qw(wikilink_html);

our @EXPORT_OK = qw(wikitext_to_html);

# MediaWiki markup to HTML, the subset a note needs, in pure Perl (post-
# cutover #93): headings (= to ======), paragraphs, '''bold''' and
# ''italic'', * and # lists nested by repeating the marker, ; and :
# definition lists and : indents, ---- rules, [[links]] to other notes
# ([[Title|shown as]]; File:/Image:/Category: links dropped), [http://…
# text] and bare web links, {| |} tables, leading-space preformatted lines,
# <pre> and <nowiki> verbatim, HTML typed into the note passed through.
# Templates {{…}}, <ref>…</ref>, signatures (~~~~), magic words (__TOC__)
# and comments are dropped: a note has none of what they need.
#
# THE OUTPUT IS NOT SAFE BY ITSELF: typed HTML comes through untouched, so
# every rendered body goes through Homelab::Notes::Clean after this (see
# Render.pm). That is the one gate, so this module can stay simple.

sub _esc ($s) {
    $s //= '';
    $s =~ s/&(?![a-zA-Z][a-zA-Z0-9]{1,31};|#\d{1,7};|#[xX][0-9a-fA-F]{1,6};)/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}
sub _attr ($s) { my $t = _esc($s); $t =~ s/"/&quot;/g; return $t }

sub wikitext_to_html ($text, $resolver = undef) {
    $text //= '';
    $text =~ s/\r\n?/\n/g;
    my @ph;
    my $put = sub ($html) { push @ph, $html; return "\x01" . $#ph . "\x02" };

    # Verbatim first, so nothing below looks inside it.
    $text =~ s{<nowiki>(.*?)</nowiki>}{ $put->(_esc($1)) }gse;
    $text =~ s{<nowiki\s*/>}{}g;
    $text =~ s{<pre(?:\s[^>]*)?>(.*?)</pre>}{ "\n" . $put->('<pre>' . _esc($1 =~ s/\A\n//r) . '</pre>') . "\n" }gse;
    # Dropped: nothing a note needs, and nothing a reader should see.
    $text =~ s{<!--.*?-->}{}gs;
    $text =~ s{<ref\b[^>]*/>}{}g;
    $text =~ s{<ref\b[^>]*>.*?</ref>}{}gs;
    $text =~ s{<references\s*/>}{}g;
    1 while $text =~ s{\{\{[^{}]*\}\}}{}g;
    $text =~ s{__[A-Z]+__}{}g;
    $text =~ s{~{3,5}}{}g;

    my @lines = split /\n/, $text, -1;
    pop @lines while @lines && $lines[-1] !~ /\S/;
    my $html = _blocks(\@lines, $resolver, $put);
    1 while $html =~ s/\x01(\d+)\x02/$ph[$1]/g;
    return $html;
}

# ---------------------------------------------------------------------- blocks

my $RE_HEAD  = qr/\A\s*(={1,6})\s*(.+?)\s*=+\s*\z/;
my $RE_HR    = qr/\A\s*-{4,}\s*\z/;
my $RE_LIST  = qr/\A([*#;:]+)\s*(.*)\z/;
my $RE_TABLE = qr/\A\s*\{\|/;
my $RE_PH    = qr/\A\s*(\x01\d+\x02)\s*\z/;
my $RE_HTML  = qr{\A\s*<(?:/?(?:address|article|aside|blockquote|details|dd|div|dl|dt|figcaption|figure|footer|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|summary|table|tbody|td|tfoot|th|thead|tr|ul|center|font|gallery|poem|code|source|syntaxhighlight)(?:[\s/>]|\z))}i;

sub _blank ($l) { return !defined $l || $l !~ /\S/ }
sub _starts_block ($l) {
    return 0 if _blank($l);
    return 1 if $l =~ $RE_HEAD || $l =~ $RE_HR || $l =~ $RE_LIST || $l =~ $RE_TABLE || $l =~ $RE_PH || $l =~ $RE_HTML || $l =~ /\A /;
    return 0;
}

sub _blocks ($lines, $resolver, $put) {
    my @out;
    my $i = 0;
    my $n = @$lines;
    while ($i < $n) {
        my $l = $lines->[$i];
        if (_blank($l)) { $i++; next }

        if ($l =~ $RE_PH) { push @out, $1; $i++; next }
        if ($l =~ $RE_HEAD) {
            my $level = length $1;
            push @out, "<h$level>" . _inline($2, $resolver, $put) . "</h$level>";
            $i++;
            next;
        }
        if ($l =~ $RE_HR) { push @out, '<hr>'; $i++; next }

        if ($l =~ $RE_LIST) {
            my @items;
            while ($i < $n && $lines->[$i] =~ $RE_LIST) { push @items, [$1, $2]; $i++ }
            push @out, _list(\@items, $resolver, $put);
            next;
        }

        if ($l =~ $RE_TABLE) {
            my @t;
            while ($i < $n) { my $r = $lines->[$i++]; last if $r =~ /\A\s*\|\}/; push @t, $r }
            shift @t;    # the {| line itself
            push @out, _table(\@t, $resolver, $put);
            next;
        }

        # Leading-space lines are preformatted; wiki markup still applies inside.
        if ($l =~ /\A / ) {
            my @pre;
            while ($i < $n && ($lines->[$i] =~ /\A / || _blank($lines->[$i]))) { push @pre, $lines->[$i] =~ s/\A //r; $i++ }
            pop @pre while @pre && _blank($pre[-1]);
            push @out, '<pre>' . join("\n", map { _inline($_, $resolver, $put) } @pre) . "\n</pre>";
            next;
        }

        if ($l =~ $RE_HTML) {
            my @raw;
            while ($i < $n && !_blank($lines->[$i])) { push @raw, $lines->[$i++] }
            push @out, join("\n", @raw);
            next;
        }

        # A paragraph: single newlines join, as the wiki has it.
        my @para = ($l);
        $i++;
        while ($i < $n && !_blank($lines->[$i]) && !_starts_block($lines->[$i])) { push @para, $lines->[$i++] }
        push @out, '<p>' . _inline(join("\n", map { s/\A\s+|\s+\z//gr } @para), $resolver, $put) . '</p>';
    }
    return join "\n", @out;
}

# Lists nested by their marker prefix: * bullet, # numbered, ; term, : definition
# (a bare : is an indent, which the wiki renders as a definition without a term).
my %LIST = ('*' => 'ul', '#' => 'ol', ';' => 'dl', ':' => 'dl');
my %ITEM = ('*' => 'li', '#' => 'li', ';' => 'dt', ':' => 'dd');
sub _same_list ($a, $b) { return $LIST{$a} eq $LIST{$b} }

sub _list ($items, $resolver, $put) {
    my @open;    # [ list tag, item tag ] per level
    my $html = '';
    for my $it (@$items) {
        my ($pfx, $body) = @$it;
        my @chars = split //, $pfx;
        my $common = 0;
        $common++ while $common < @open && $common < @chars && _same_list($open[$common][2], $chars[$common]);
        # Close the levels we are leaving.
        while (@open > $common) { my $o = pop @open; $html .= "</$o->[1]></$o->[0]>" }
        if (@open && @open == @chars) {
            # Same level: close the previous item, open the next (its tag may differ: ; then :).
            my $o = $open[-1];
            $html .= "</$o->[1]>";
            $o->[1] = $ITEM{ $chars[-1] };
            $o->[2] = $chars[-1];
            $html .= "<$o->[1]>";
        }
        # Open the new levels.
        for my $k (scalar(@open) .. $#chars) {
            my $c = $chars[$k];
            $html .= "<$LIST{$c}><$ITEM{$c}>";
            push @open, [ $LIST{$c}, $ITEM{$c}, $c ];
        }
        # ; term : definition on one line.
        if ($chars[-1] eq ';' && $body =~ /\A(.*?)\s+:\s+(.*)\z/s) {
            my ($term, $def) = ($1, $2);
            $html .= _inline($term, $resolver, $put) . '</dt><dd>' . _inline($def, $resolver, $put);
            $open[-1][1] = 'dd';
        } else {
            $html .= _inline($body, $resolver, $put);
        }
    }
    while (@open) { my $o = pop @open; $html .= "</$o->[1]></$o->[0]>" }
    $html =~ s/<\/li><ul>/<ul>/g; $html =~ s/<\/li><ol>/<ol>/g;    # a sublist belongs inside its item
    return $html;
}

# {| ... |}: |+ caption, |- row, ! header cells (!! on one line), | cells (|| on
# one line); an attribute part before a lone | in a cell is dropped.
sub _table ($rows, $resolver, $put) {
    my ($caption, @trs, @cur);
    my $flush = sub { push @trs, '<tr>' . join('', @cur) . '</tr>' if @cur; @cur = () };
    my $cell = sub ($tag, $raw) {
        my $c = $raw;
        $c = $2 if $c =~ /\A\s*([^|\[\]{}]*?=[^|\[\]{}]*?)\s*\|(?!\|)(.*)\z/s;    # attrs | content
        return "<$tag>" . _inline($c =~ s/\A\s+|\s+\z//gr, $resolver, $put) . "</$tag>";
    };
    for my $r (@$rows) {
        next if _blank($r);
        if    ($r =~ /\A\s*\|\+\s*(.*)\z/)     { $caption = _inline($1, $resolver, $put) }
        elsif ($r =~ /\A\s*\|-/)               { $flush->() }
        elsif ($r =~ /\A\s*!\s?(.*)\z/)        { push @cur, map { $cell->('th', $_) } split /\s*!!\s*/, $1 }
        elsif ($r =~ /\A\s*\|\s?(.*)\z/)       { push @cur, map { $cell->('td', $_) } split /\s*\|\|\s*/, $1 }
        else { push @cur, $cell->('td', $r) }
    }
    $flush->();
    return "<table>\n" . (defined $caption ? "<caption>$caption</caption>\n" : '') . join("\n", @trs) . "\n</table>";
}

# ---------------------------------------------------------------------- inline

my $RE_TAG = qr{</?[a-zA-Z][a-zA-Z0-9-]*(?:\s+[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>};
my $RE_URL = qr{https?://[^\s<\]]*[^\s<.,:;"'\)\]!?*_~]};

sub _inline ($text, $resolver, $put) {
    $text //= '';
    $text =~ s{<nowiki>(.*?)</nowiki>}{ $put->(_esc($1)) }gse;
    $text =~ s/($RE_TAG)/$put->($1)/ge;
    $text = _esc($text);

    # Links to notes; a link to a file, picture or category is a wiki thing
    # with no meaning here and is dropped. Letters right after ]] join the link.
    $text =~ s{\[\[([^\[\]|]+?)(?:\|([^\[\]]*?))?\]\]([a-zA-Z]*)}{ my ($t, $x, $trail) = ($1, $2, $3); $t =~ m{\A\s*(?:File|Image|Category|Media|Special):}i ? '' : $put->(wikilink_html($t, (defined $x && length $x ? $x : $t) . $trail, $resolver)) }ge;
    # External links: [url text], [url], and bare URLs.
    $text =~ s/\[((?:https?|mailto):[^\s\]]+)(?:\s+([^\]]*))?\]/$put->('<a href="' . _attr($1) . '">' . ((defined $2 && length $2) ? $2 : $1) . '<\/a>')/ge;
    $text =~ s/(?<![\w\/"=])($RE_URL)/$put->('<a href="' . _attr($1) . '">' . $1 . '<\/a>')/ge;

    # Emphasis: five quotes, three, two.
    $text =~ s/'''''(?=\S)(.+?)(?<=\S)'''''/<strong><em>$1<\/em><\/strong>/gs;
    $text =~ s/'''(?=\S)(.+?)(?<=\S)'''/<strong>$1<\/strong>/gs;
    $text =~ s/''(?=\S)(.+?)(?<=\S)''/<em>$1<\/em>/gs;
    return $text;
}

1;
