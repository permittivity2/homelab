package Homelab::Notes::Clean;
use Mojo::Base -strict, -signatures;
use Mojo::DOM;
use Exporter 'import';

our @EXPORT_OK = qw(clean_html text_to_html safe_url);

# The one gate between what a person typed and what a browser is given
# (post-cutover #71). An ALLOWLIST on Mojo::DOM, which every node already
# has: tags not listed are stripped (their text kept), a short list of
# active ones is removed with everything inside, attributes are kept only
# when the tag may have that one and its value passes, and every URL must
# be http, https, mailto, a fragment or a path on this site. No style, no
# class (but the code-language one), no id, no event handler, no data: URL.
#
# Belt and braces: the pages that show a body also carry a Content-Security-
# Policy with no inline script, so even a gap here could not run anything.

my %KEEP = map { $_ => 1 } qw(
    a abbr address article aside b blockquote br caption cite code dd del details dfn div dl dt em
    figcaption figure footer h1 h2 h3 h4 h5 h6 header hr i img input ins kbd li main mark nav ol p pre q
    s samp section small span strong sub summary sup table tbody td tfoot th thead time tr u ul var wbr
);
# Gone with their content: nothing inside them is text a reader meant to see.
my %DROP = map { $_ => 1 } qw(
    script style iframe object embed noscript template svg math head title meta link base form button
    select textarea option optgroup canvas audio video source track frame frameset applet xmp plaintext
    listing noembed noframes dialog slot portal
);
# What each tag may carry, and the rule its value must pass.
my %ATTR = (
    a          => { href => 'url', title => 'text' },
    img        => { src => 'imgurl', alt => 'text', title => 'text', width => 'int', height => 'int' },
    td         => { colspan => 'int', rowspan => 'int', align => 'align' },
    th         => { colspan => 'int', rowspan => 'int', align => 'align', scope => 'scope' },
    ol         => { start => 'int', reversed => 'flag' },
    li         => { value => 'int' },
    time       => { datetime => 'text' },
    abbr       => { title => 'text' },
    dfn        => { title => 'text' },
    blockquote => { cite => 'url' },
    q          => { cite => 'url' },
    details    => { open => 'flag' },
    code       => { class => 'codelang' },
    input      => { type => 'checkbox', checked => 'flag', disabled => 'flag' },
);
my %GLOBAL = (title => 'text', lang => 'lang', dir => 'dir');

sub clean_html ($html) {
    my $dom = Mojo::DOM->new($html // '');
    _walk($dom);
    return $dom->to_string;
}

sub _walk ($node) {
    for my $n (@{ $node->child_nodes }) {
        my $type = $n->type;
        if ($type eq 'tag') {
            my $tag = lc $n->tag;
            if ($DROP{$tag}) { $n->remove; next }
            unless ($KEEP{$tag}) { _walk($n); $n->strip; next }
            if ($tag eq 'input') {
                # Only a task box: a checkbox that cannot be changed.
                unless (lc($n->attr('type') // '') eq 'checkbox') { $n->remove; next }
                $n->attr(disabled => undef);
            }
            _attrs($n, $tag);
            _walk($n);
        }
        elsif ($type eq 'text') { next }
        else { $n->remove }    # comment, cdata, pi, doctype, raw
    }
    return;
}

sub _attrs ($n, $tag) {
    my $attrs = $n->attr;
    for my $name (keys %$attrs) {
        my $l = lc $name;
        my $rule = $ATTR{$tag}{$l} // $GLOBAL{$l};
        my $val = $attrs->{$name};
        if ($rule && _ok($rule, $val) && !($l =~ /\Aon/ || $l eq 'style' || $l eq 'id' || $l eq 'class' && $tag ne 'code')) {
            next if $name eq $l;
            $attrs->{$l} = $val;
        }
        delete $attrs->{$name};
    }
    if ($tag eq 'a' && defined $attrs->{href} && $attrs->{href} =~ /\A\s*(?:https?|mailto):/i) {
        $attrs->{rel} = 'noopener noreferrer';
        $attrs->{target} = '_blank';
    }
    $attrs->{loading} = 'lazy' if $tag eq 'img';
    return;
}

sub _ok ($rule, $v) {
    return 1 if $rule eq 'flag';                                   # presence is the value
    return 0 unless defined $v;
    return length($v) <= 2000 if $rule eq 'text';
    return safe_url($v) if $rule eq 'url';
    return ($v =~ s/[\x00-\x20\x7f-\x9f]//gr) =~ /\Ahttps?:/i ? 1 : 0 if $rule eq 'imgurl';
    return $v =~ /\A\d{1,5}\z/ ? 1 : 0 if $rule eq 'int';
    return $v =~ /\A(?:left|center|right|justify|char)\z/i ? 1 : 0 if $rule eq 'align';
    return $v =~ /\A(?:row|col|rowgroup|colgroup)\z/i ? 1 : 0 if $rule eq 'scope';
    return $v =~ /\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/ ? 1 : 0 if $rule eq 'lang';
    return $v =~ /\A(?:ltr|rtl|auto)\z/i ? 1 : 0 if $rule eq 'dir';
    return $v =~ /\Alanguage-[a-zA-Z0-9_+#.-]{1,30}\z/ ? 1 : 0 if $rule eq 'codelang';
    return lc($v) eq 'checkbox' ? 1 : 0 if $rule eq 'checkbox';
    return 0;
}

# A URL a note may point at: the web, mail, a place on the page, or a path on
# this site. Control characters and spaces are ignored for the test, so
# "java\tscript:" is read as what it is.
sub safe_url ($u) {
    return 0 unless defined $u;
    my $t = $u =~ s/[\x00-\x20\x7f-\x9f]//gr;
    return 0 unless length $t;
    return 1 if $t =~ /\A#/;
    return 1 if $t =~ m{\A/(?!/)};
    return 1 if $t =~ /\A(?:https?|mailto):/i;
    return 0;
}

# A plain-text note: escaped, line breaks kept, bare URLs made links.
sub text_to_html ($text) {
    $text //= '';
    $text =~ s/\r\n?/\n/g;
    my $out = '';
    for my $piece (split m{(https?://[^\s<]*[^\s<.,:;"'\)\]!?])}, $text) {
        if ($piece =~ m{\Ahttps?://}) {
            my $e = _esc($piece);
            $out .= qq{<a href="$e" rel="noopener noreferrer" target="_blank">$e</a>};
        } else {
            $out .= _esc($piece);
        }
    }
    return "<pre>$out</pre>";
}

sub _esc ($s) { $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; return $s }

1;
