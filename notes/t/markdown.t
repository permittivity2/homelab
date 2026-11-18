use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Homelab::Notes::Markdown qw(markdown_to_html);

# The Markdown subset, case by case. Whitespace between blocks is not the
# point, so it is squeezed before comparing.
sub md ($in, $want, $name) {
    my $got = markdown_to_html($in);
    for ($got, $want) { s/>\s+</></g; s/\s*\n\s*</</g; s/\A\s+|\s+\z//g }
    is $got, $want, $name;
}

# --- blocks -------------------------------------------------------------------
md "Hello", '<p>Hello</p>', 'a paragraph';
md "one\ntwo", "<p>one\ntwo</p>", 'lines of one paragraph stay one paragraph';
md "one\n\ntwo", '<p>one</p><p>two</p>', 'a blank line separates paragraphs';
md "one  \ntwo", "<p>one<br>\ntwo</p>", 'two trailing spaces make a break';
md "one\\\ntwo", "<p>one<br>\ntwo</p>", 'a backslash makes a break';
md "# Title", '<h1>Title</h1>', 'an ATX heading';
md "### Three ###", '<h3>Three</h3>', 'closing hashes dropped';
md "####### seven", '<p>####### seven</p>', 'seven hashes are text';
md "#nospace", '<p>#nospace</p>', 'a hash without a space is text';
md "Title\n=====", '<h1>Title</h1>', 'an underlined heading, level 1';
md "Title\n---", '<h2>Title</h2>', '... level 2';
md "---", '<hr>', 'a rule';
md "* * *", '<hr>', 'a starry rule is not a list';
md "> quoted\n> more", "<blockquote><p>quoted\nmore</p></blockquote>", 'a quote';
md "> a\n>\n> b", '<blockquote><p>a</p><p>b</p></blockquote>', 'two paragraphs in a quote';
md "> # Head\n> - item", '<blockquote><h1>Head</h1><ul><li>item</li></ul></blockquote>', 'blocks inside a quote';
md "```\ncode <here>\n```", "<pre><code>code &lt;here&gt;\n</code></pre>", 'fenced code, escaped';
md "```perl\nmy \$x;\n```", "<pre><code class=\"language-perl\">my \$x;\n</code></pre>", 'the info string becomes a language class';
md "~~~\n**not bold**\n~~~", "<pre><code>**not bold**\n</code></pre>", 'tilde fence; no inline inside';
md "````\n```\n````", "<pre><code>```\n</code></pre>", 'a longer fence contains a shorter one';
md "```\nopen", "<pre><code>open\n</code></pre>", 'an unclosed fence runs to the end';
md "    indented\n    code", "<pre><code>indented\ncode\n</code></pre>", 'indented code';
md "- a\n- b", '<ul><li>a</li><li>b</li></ul>', 'a bullet list, tight';
md "* a\n* b", '<ul><li>a</li><li>b</li></ul>', 'stars too';
md "1. a\n2. b", '<ol><li>a</li><li>b</li></ol>', 'a numbered list';
md "3. a\n4. b", '<ol start="3"><li>a</li><li>b</li></ol>', '... starting at 3';
md "- a\n\n- b", '<ul><li><p>a</p></li><li><p>b</p></li></ul>', 'a loose list wraps items in paragraphs';
md "- a\n  - b\n  - c\n- d", '<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>', 'a nested list';
md "- a\n  continued", "<ul><li>a\ncontinued</li></ul>", 'an indented continuation line';
md "- a\ncontinued", "<ul><li>a\ncontinued</li></ul>", 'a lazy continuation line';
md "- [ ] todo\n- [x] done", '<ul><li><input type="checkbox" disabled> todo</li><li><input type="checkbox" disabled checked> done</li></ul>', 'task boxes';
md "- item\n\n  second paragraph", '<ul><li><p>item</p><p>second paragraph</p></li></ul>', 'two paragraphs in one item';
md "para\n- a\n- b", '<p>para</p><ul><li>a</li><li>b</li></ul>', 'a bullet interrupts a paragraph';
md "- a\n\npara", '<ul><li>a</li></ul><p>para</p>', 'a blank line then text ends the list';
md "| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |",
   '<table><thead><tr><th>a</th><th align="center">b</th></tr></thead><tbody><tr><td>1</td><td align="center">2</td></tr><tr><td>3</td><td align="center">4</td></tr></tbody></table>', 'a pipe table with alignment';
md "a | b\n--- | ---:\n1 | 2", '<table><thead><tr><th>a</th><th align="right">b</th></tr></thead><tbody><tr><td>1</td><td align="right">2</td></tr></tbody></table>', 'a table without outer pipes';
md "| a | b |\n|---|---|\n| x \\| y | z |", '<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>x | y</td><td>z</td></tr></tbody></table>', 'an escaped pipe stays in its cell';
md "a | b\nnot a table", "<p>a | b\nnot a table</p>", 'a pipe without a delimiter row is just text';
md "<div class=\"x\">\n<b>raw</b>\n</div>", "<div class=\"x\">\n<b>raw</b>\n</div>", 'an HTML block passes through (Clean decides later)';
md "<!-- a comment -->\ntext", "<!-- a comment --><p>text</p>", 'a comment block passes through';
md "<script>alert(1)</script>", '<script>alert(1)</script>', 'a script block passes through to Clean, which drops it';

# --- inline -------------------------------------------------------------------
md "**bold** and __bold__", '<p><strong>bold</strong> and <strong>bold</strong></p>', 'strong';
md "*em* and _em_", '<p><em>em</em> and <em>em</em></p>', 'emphasis';
md "snake_case_name", '<p>snake_case_name</p>', 'underscores inside a word are not emphasis';
md "2 * 3 * 4", '<p>2 * 3 * 4</p>', 'spaced stars are not emphasis';
md "~~gone~~", '<p><del>gone</del></p>', 'strikethrough';
md "a `code <span>` b", '<p>a <code>code &lt;span&gt;</code> b</p>', 'a code span, escaped';
md "`` a ` b ``", '<p><code>a ` b</code></p>', 'a double-backtick span holds a backtick';
md "`**not**`", '<p><code>**not**</code></p>', 'no emphasis inside code';
md "[text](https://example.test/a?b=1&c=2 \"Title\")", '<p><a href="https://example.test/a?b=1&amp;c=2" title="Title">text</a></p>', 'a link with a title';
md "[**bold** text](/x)", '<p><a href="/x"><strong>bold</strong> text</a></p>', 'emphasis inside a link';
md "![alt text](https://example.test/i.png)", '<p><img src="https://example.test/i.png" alt="alt text"></p>', 'an image';
md "<https://example.test/x>", '<p><a href="https://example.test/x">https://example.test/x</a></p>', 'an autolink';
md q{<someone@example.test>}, '<p><a href="mailto:someone@example.test">someone@example.test</a></p>', 'an email autolink';
md "see https://example.test/p?q=1, ok", '<p>see <a href="https://example.test/p?q=1">https://example.test/p?q=1</a>, ok</p>', 'a bare URL, trailing comma left out';
md "(https://example.test/)", '<p>(<a href="https://example.test/">https://example.test/</a>)</p>', 'a bare URL in brackets';
md "a <b>raw</b> tag", '<p>a <b>raw</b> tag</p>', 'inline HTML passes through';
md "1 < 2 and 3 > 2 & more", '<p>1 &lt; 2 and 3 &gt; 2 &amp; more</p>', 'loose angle brackets and ampersands are escaped';
md "&copy; 2026 &#169; &amp;", '<p>&copy; 2026 &#169; &amp;</p>', 'entities typed on purpose stay';
md "\\*not em\\* and \\# not a heading", '<p>*not em* and # not a heading</p>', 'backslash escapes';
md "<img src=x onerror=alert(1)>", '<img src=x onerror=alert(1)>', 'a dangerous tag on its own line is an HTML block, passed to Clean unchanged (Clean strips the handler)';
md "a <img src=x onerror=alert(1)> b", '<p>a <img src=x onerror=alert(1)> b</p>', '... and inline too';
md "", '', 'nothing in, nothing out';
md "\n\n", '', 'blank lines only';
md "a\r\nb", "<p>a\nb</p>", 'CRLF is fine';

done_testing;
