use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Homelab::Notes::Wikitext qw(wikitext_to_html);

# The wiki subset, case by case (post-cutover #93). Whitespace between
# blocks is not the point, so it is squeezed before comparing.
my $resolver = sub ($t) { return lc $t eq 'shopping' ? '/n/42' : lc $t eq 'plan b' ? '/n/7' : undef };   # the real one looks titles up with case ignored
sub wt ($in, $want, $name) {
    my $got = wikitext_to_html($in, $resolver);
    for ($got, $want) { s/>\s+</></g; s/\s*\n\s*</</g; s/\A\s+|\s+\z//g }
    is $got, $want, $name;
}

# --- blocks ---------------------------------------------------------------
wt "Hello", '<p>Hello</p>', 'a paragraph';
wt "one\ntwo", "<p>one\ntwo</p>", 'single newlines join a paragraph';
wt "one\n\ntwo", '<p>one</p><p>two</p>', 'a blank line separates paragraphs';
wt "== Title ==", '<h2>Title</h2>', 'a level-2 heading';
wt "= Top =", '<h1>Top</h1>', 'a level-1 heading';
wt "====== Six ======", '<h6>Six</h6>', 'level 6';
wt "==Tight==", '<h2>Tight</h2>', 'no spaces needed';
wt "----", '<hr>', 'a rule';
wt "--------", '<hr>', '... of any length over four';
wt "* a\n* b", '<ul><li>a</li><li>b</li></ul>', 'a bullet list';
wt "# a\n# b", '<ol><li>a</li><li>b</li></ol>', 'a numbered list';
wt "* a\n** b\n** c\n* d", '<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>', 'a nested list';
wt "* a\n*# one\n*# two", '<ul><li>a<ol><li>one</li><li>two</li></ol></li></ul>', 'numbers inside bullets';
wt "; term : definition", '<dl><dt>term</dt><dd>definition</dd></dl>', 'a definition on one line';
wt "; term\n: definition", '<dl><dt>term</dt><dd>definition</dd></dl>', '... and on two';
wt ": indented", '<dl><dd>indented</dd></dl>', 'a bare colon indents';
wt "{|\n! A !! B\n|-\n| 1 || 2\n|-\n| 3\n| 4\n|}", '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table>', 'a table, cells on one line and on their own';
wt "{| class=\"wikitable\"\n|+ The caption\n|-\n! h\n|-\n| style=\"color:red\" | styled cell\n|}", '<table><caption>The caption</caption><tr><th>h</th></tr><tr><td>styled cell</td></tr></table>', 'caption; attributes before a cell dropped';
wt " preformatted\n ''still'' wiki", "<pre>preformatted\n<em>still</em> wiki\n</pre>", 'leading-space lines are preformatted, markup still applies';
wt "<pre>\n''raw'' <b>x</b>\n</pre>", "<pre>''raw'' &lt;b&gt;x&lt;/b&gt;</pre>", 'a pre block is verbatim';
wt "a <nowiki>''not em''</nowiki> b", "<p>a ''not em'' b</p>", 'nowiki is verbatim';
wt "text {{Template|x=1}} more", '<p>text  more</p>', 'a template is dropped';
wt "text {{a|{{b}}}} more", '<p>text  more</p>', '... even nested';
wt "fact<ref>Source</ref> more<ref name=\"x\"/>", '<p>fact more</p>', 'refs are dropped';
wt "__TOC__\ntext ~~~~", '<p>text</p>', 'magic words and signatures are dropped';
wt "<!-- hidden -->shown", '<p>shown</p>', 'comments are dropped';
wt "<div class=\"x\">\n<b>raw</b>\n</div>", "<div class=\"x\">\n<b>raw</b>\n</div>", 'an HTML block passes through (Clean decides later)';
wt "<script>alert(1)</script>", '<p><script>alert(1)</script></p>', 'a script tag passes through to Clean, which drops it';

# --- inline ---------------------------------------------------------------
wt "'''bold''' and ''italic'' and '''''both'''''", '<p><strong>bold</strong> and <em>italic</em> and <strong><em>both</em></strong></p>', 'emphasis';
wt "it''s not", "<p>it''s not</p>", "a lone pair of quotes with a space after is not emphasis";
wt "See [[Shopping]].", '<p>See <a class="wikilink" href="/n/42">Shopping</a>.</p>', 'a link to a note that exists';
wt "See [[Shopping|the list]].", '<p>See <a class="wikilink" href="/n/42">the list</a>.</p>', '... shown as something else';
wt "[[Shopping]]s", '<p><a class="wikilink" href="/n/42">Shoppings</a></p>', 'letters after ]] join the link';
wt "See [[Nothing here]].", '<p>See <span class="wikilink wikilink--missing" data-title="Nothing here">Nothing here</span>.</p>', 'a link to a note that does not exist is marked missing';
wt "[[plan b]]", '<p><a class="wikilink" href="/n/7">plan b</a></p>', 'the resolver decides case';
wt "[[File:x.png|thumb]] text [[Category:Y]]", '<p> text </p>', 'file and category links are dropped';
wt "[https://example.test/x the site]", '<p><a href="https://example.test/x">the site</a></p>', 'an external link with text';
wt "[https://example.test/x]", '<p><a href="https://example.test/x">https://example.test/x</a></p>', '... without';
wt "see https://example.test/p?q=1, ok", '<p>see <a href="https://example.test/p?q=1">https://example.test/p?q=1</a>, ok</p>', 'a bare URL';
wt "1 < 2 & 3 > 2", '<p>1 &lt; 2 &amp; 3 &gt; 2</p>', 'loose angle brackets and ampersands are escaped';
wt "&copy; 2026", '<p>&copy; 2026</p>', 'entities typed on purpose stay';
wt "line<br>break", '<p>line<br>break</p>', 'an inline tag passes through';
wt "a [[x|<b>raw</b>]] b", '<p>a <span class="wikilink wikilink--missing" data-title="x"><b>raw</b></span> b</p>', 'inline HTML inside link text passes through to Clean';
wt "", '', 'nothing in, nothing out';
wt "== H ==\n\n* [[Shopping]]\n* ''x''\n\n{|\n| c\n|}", '<h2>H</h2><ul><li><a class="wikilink" href="/n/42">Shopping</a></li><li><em>x</em></li></ul><table><tr><td>c</td></tr></table>', 'blocks in sequence';
is wikitext_to_html("[[Shopping]]"), '<p><span class="wikilink wikilink--missing" data-title="Shopping">Shopping</span></p>', 'without a resolver every link is missing';

done_testing;
