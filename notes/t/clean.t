use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Homelab::Notes::Clean qw(clean_html text_to_html safe_url);
use Homelab::Notes::Render qw(render_body excerpt);

# The allowlist sanitiser: what stays, what goes, and that nothing active
# survives whatever shape it arrives in.
sub keeps ($in, $want, $name) { is clean_html($in), $want, $name }
sub no_script ($in, $name) {
    my $out = clean_html($in);
    unlike $out, qr/<script|javascript:|onerror|onclick|onload|<iframe|<object|<embed|data:/i, $name;
    return $out;
}

keeps '<p>Hello <b>there</b></p>', '<p>Hello <b>there</b></p>', 'plain markup stays';
keeps '<h1>T</h1><ul><li>a</li></ul><table><tr><td>1</td></tr></table>', '<h1>T</h1><ul><li>a</li></ul><table><tr><td>1</td></tr></table>', 'structure stays';
keeps '<a href="https://example.test/x">x</a>', '<a href="https://example.test/x" rel="noopener noreferrer" target="_blank">x</a>', 'a web link gets rel and target';
keeps '<a href="mailto:a@b.test">m</a>', '<a href="mailto:a@b.test" rel="noopener noreferrer" target="_blank">m</a>', 'a mail link stays';
keeps '<a href="#top">t</a>', '<a href="#top">t</a>', 'a fragment stays, no new tab';
keeps '<a href="/n/4">n</a>', '<a href="/n/4">n</a>', 'a path on this site stays';
keeps '<a href="//evil.test/">x</a>', '<a>x</a>', 'a protocol-relative URL is dropped';
keeps '<a href="javascript:alert(1)">x</a>', '<a>x</a>', 'a javascript: link loses its href';
keeps "<a href=\"java\tscript:alert(1)\">x</a>", '<a>x</a>', '... with a tab inside the scheme too';
keeps '<a href="JAVASCRIPT:alert(1)">x</a>', '<a>x</a>', '... in capitals';
keeps '<a href="data:text/html,hi">x</a>', '<a>x</a>', 'a data: link is dropped';
keeps '<a href="vbscript:x">x</a>', '<a>x</a>', 'any other scheme is dropped';
keeps '<a href="ftp://x">x</a>', '<a>x</a>', '... ftp too';
keeps '<img src="https://example.test/i.png" alt="i">', '<img alt="i" loading="lazy" src="https://example.test/i.png">', 'an image over https stays, lazily';
keeps '<img src="data:image/png;base64,AAAA">', '<img loading="lazy">', 'a data: image loses its source';
keeps '<img src="/local.png">', '<img loading="lazy">', 'a relative image source is dropped (only the web)';
keeps '<img src="x" onerror="alert(1)">', '<img loading="lazy">', 'an event handler is dropped';
keeps '<p onclick="x()" style="color:red" class="a" id="b" title="ok">t</p>', '<p title="ok">t</p>', 'style, class, id and handlers go; title stays';
keeps '<code class="language-perl">x</code>', '<code class="language-perl">x</code>', 'the code language class stays';
keeps '<code class="evil language-perl">x</code>', '<code>x</code>', '... only when it is exactly that';
keeps '<span class="x" data-y="1">s</span>', '<span>s</span>', 'data attributes go';
keeps '<td colspan="2" rowspan="1" align="right" width="9">c</td>', '<td align="right" colspan="2" rowspan="1">c</td>', 'table cell attributes, allowed ones only';
keeps '<td colspan="2; drop">c</td>', '<td>c</td>', 'a non-number colspan goes';
keeps '<ol start="4"><li value="7">x</li></ol>', '<ol start="4"><li value="7">x</li></ol>', 'list numbering stays';
keeps '<input type="checkbox" checked disabled> t', '<input checked disabled type="checkbox"> t', 'a task box stays, disabled';
keeps '<input type="checkbox"> t', '<input disabled type="checkbox"> t', '... and is made disabled';
keeps '<input type="text" name="q">', '', 'any other input goes';
keeps '<details open><summary>s</summary>b</details>', '<details open><summary>s</summary>b</details>', 'details stays open';
keeps '<p lang="en-US" dir="rtl">t</p>', '<p dir="rtl" lang="en-US">t</p>', 'lang and dir stay when well formed';
keeps '<p lang="x y">t</p>', '<p>t</p>', '... and go when not';
keeps '<center>c</center><font color="red">f</font><u>u</u>', 'cf<u>u</u>', 'unknown tags are stripped, their text kept';
keeps '<html><head><title>T</title></head><body><p>b</p></body></html>', '<p>b</p>', 'a whole document is reduced to its body content';
keeps '<p>a<!-- c -->b</p>', '<p>ab</p>', 'comments go';
keeps '<script>alert(1)</script><p>x</p>', '<p>x</p>', 'script goes with its content';
keeps '<style>p{display:none}</style><p>x</p>', '<p>x</p>', 'style goes with its content';
keeps '<iframe src="https://x.test"></iframe>', '', 'iframe goes';
keeps '<object data="x"></object><embed src="x"><form><button>b</button></form>', '', 'object, embed, form go';
keeps '<svg onload="x()"><circle/></svg><math><mi>x</mi></math>', '', 'svg and math go with their content';
keeps '<p>a</p><noscript><img src="x" onerror="y"></noscript>', '<p>a</p>', 'noscript goes';
keeps '<template><script>x</script></template>', '', 'template goes';
keeps '<p>unclosed <b>bold', '<p>unclosed <b>bold</b></p>', 'unclosed tags are closed';
keeps '<p>1 &lt; 2 &amp; 3</p>', '<p>1 &lt; 2 &amp; 3</p>', 'entities survive a round trip';
keeps '<P>UPPER <B>case</B></P>', '<p>UPPER <b>case</b></p>', 'tag names are lowered';
keeps '<a HREF="https://e.test">x</a>', '<a href="https://e.test" rel="noopener noreferrer" target="_blank">x</a>', 'attribute names are lowered';
keeps '', '', 'nothing';

no_script '<a href="&#106;avascript:alert(1)">x</a>', 'an entity-encoded javascript: scheme';
no_script '<a href=" javascript:alert(1)">x</a>', 'a leading space';
no_script '<img src="x" ONERROR="alert(1)">', 'a capitalised handler';
no_script '<svg><script>alert(1)</script></svg>', 'script inside svg';
no_script '<p><img src="https://x.test" onerror=alert(1)></p>', 'an unquoted handler';
no_script '<a href="https://x.test" style="background:url(javascript:1)">x</a>', 'a style attribute';
no_script '<<script>script>alert(1)<</script>/script>', 'nested-looking script tags';
no_script '<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>', 'the mglyph trick';
no_script '<noscript><p title="</noscript><img src=x onerror=alert(1)>">', 'the noscript trick';
no_script '<iframe srcdoc="<script>alert(1)</script>"></iframe>', 'srcdoc';
no_script '<form><button formaction="javascript:alert(1)">x</button></form>', 'formaction';
no_script '<object data="data:text/html,<script>alert(1)</script>"></object>', 'object with data:';
no_script '<a href="javas&#99;ript:alert(1)">x</a>', 'a mixed-entity scheme';
no_script '<base href="javascript:x//">', 'base goes';
no_script '<meta http-equiv="refresh" content="0;url=javascript:alert(1)">', 'meta goes';
no_script '<link rel="stylesheet" href="https://x.test/evil.css">', 'link goes';

# --- the URL rule on its own ---
ok safe_url('https://a.test/'), 'https';
ok safe_url('HTTP://a.test/'), 'http in capitals';
ok safe_url('mailto:a@b.test'), 'mailto';
ok safe_url('#x'), 'fragment';
ok safe_url('/path?x=1'), 'path';
ok !safe_url('//a.test/'), 'protocol-relative';
ok !safe_url('javascript:1'), 'javascript';
ok !safe_url("\x00javascript:1"), 'a null byte first';
ok !safe_url('data:text/plain,x'), 'data';
ok !safe_url(''), 'empty';
ok !safe_url(undef), 'undef';
ok !safe_url('   '), 'spaces only';

# --- text and the renderer ---
is text_to_html("a <b> & \"q\"\nline"), "<pre>a &lt;b&gt; &amp; &quot;q&quot;\nline</pre>", 'a text note is escaped, breaks kept';
is text_to_html('see https://e.test/x. done'), '<pre>see <a href="https://e.test/x" rel="noopener noreferrer" target="_blank">https://e.test/x</a>. done</pre>', 'a URL in a text note is a link';
is render_body('text', '<script>x</script>'), '<pre>&lt;script&gt;x&lt;/script&gt;</pre>', 'text: shown as typed';
is render_body('html', '<p onclick="x">h</p><script>y</script>'), '<p>h</p>', 'html: cleaned';
is render_body('markdown', "# T\n<script>y</script>\n\n**b**"), "<h1>T</h1>\n\n<p><strong>b</strong></p>", 'markdown: rendered then cleaned';
is render_body('markdown', '[x](javascript:alert(1))'), '<p><a>x</a></p>', 'a markdown link to javascript: loses its href';
is render_body('markdown', '![i](javascript:alert(1))'), '<p><img alt="i" loading="lazy"></p>', 'a markdown image to javascript: loses its source';
is render_body('markdown', "- [x] done"), '<ul>' . "\n" . '<li><input checked disabled type="checkbox"> done</li>' . "\n" . '</ul>', 'a task box end to end';
is render_body(undef, undef), '', 'nothing';

is excerpt('markdown', "# Title\n\nSome **bold** text and [a link](https://x.test) here."), 'Title Some bold text and a link here.', 'an excerpt loses the markup';
is excerpt('html', '<h1>T</h1><p>body <b>here</b></p>'), 'T body here', 'an html excerpt is the text';
is excerpt('text', "line one\nline two"), 'line one line two', 'a text excerpt joins lines';
is length(excerpt('text', 'x' x 500, 40)), 40, 'an excerpt is cut to size';

# --- links between notes (#93): exactly that class, nothing else ---
keeps '<a class="wikilink" href="/n/4">x</a>', '<a class="wikilink" href="/n/4">x</a>', 'the wikilink class stays on a path link';
keeps '<a class="wikilink evil" href="/n/4">x</a>', '<a href="/n/4">x</a>', '... only exactly that';
keeps '<span class="wikilink wikilink--missing" data-title="T &amp; U">t</span>', '<span class="wikilink wikilink--missing" data-title="T &amp; U">t</span>', 'a missing link keeps its class and title';
keeps '<span class="other" data-title="x" onclick="y">t</span>', '<span data-title="x">t</span>', 'any other class goes';
keeps '<p class="wikilink">t</p>', '<p>t</p>', 'the class means nothing on other tags';
is render_body('wiki', "== T ==\n'''b''' <script>x</script> [[Nope]]"), '<h2>T</h2>' . "\n" . '<p><strong>b</strong>  <span class="wikilink wikilink--missing" data-title="Nope">Nope</span></p>', 'wiki: rendered then cleaned';
is render_body('markdown', 'See [[Shopping]]', sub ($t) { '/n/1' }), '<p>See <a class="wikilink" href="/n/1">Shopping</a></p>', 'markdown: a resolver reaches the renderer';
is excerpt('wiki', "== Head ==\n'''bold''' [[Shopping|the list]] {{tpl}} [https://x.test site]"), 'Head bold the list site', 'a wiki excerpt loses the markup';
done_testing;
