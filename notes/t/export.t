use Mojo::Base -strict, -signatures;
use Test::More;
use lib 'lib';
use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojolicious::Lite;
use Homelab::Notes::Export qw(source_ext export_name plain_text standalone_html inline_images_p pdf_ready_html public_image_ok);

# A note as a file (post-cutover #101): names, plain text, the standalone
# page, what goes to the worker, and the image inlining against a local
# server. Pure; runs in CI.

# --- names ------------------------------------------------------------------
is(source_ext('markdown'), 'md', 'markdown as written is .md');
is(source_ext('wiki'), 'txt', 'wiki as written is .txt');
is(source_ext('html'), 'html', 'html as written is .html');
is(source_ext('text'), 'txt', 'text is .txt');
is(export_name('Groceries', 'pdf'), 'Groceries.pdf', 'a plain title');
is(export_name('  Plan: 2026/27 "draft" <v2>?  ', 'md'), 'Plan 2026 27 draft v2.md', 'the characters a file system chokes on become spaces');
is(export_name('', 'txt'), 'Untitled note.txt', 'an empty title');
is(length(export_name('x' x 200, 'txt')), 84, 'cut to 80 characters');
is(export_name("Caf\x{e9} \x{1F600}", 'txt'), "Caf\x{e9} \x{1F600}.txt", 'non-ASCII is kept');

# --- plain text ---------------------------------------------------------------
my $html = '<h1>Groceries</h1><p>For <strong>Saturday</strong>, from <a href="https://shop.example/list">the shop</a> and <a href="https://x.example">https://x.example</a>.</p>'
         . '<ul><li>Eggs</li><li>Milk<ul><li>whole</li><li>oat</li></ul></li></ul><ol><li>first</li><li>second</li></ol>'
         . "<h2>Notes</h2><blockquote><p>quoted</p></blockquote><pre><code>sudo apt install\n  weasyprint</code></pre>"
         . '<p><input type="checkbox" checked> done<br><input type="checkbox"> not yet</p><hr><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>'
         . '<p><img src="https://x.example/p.png" alt="the plan"> and <a class="wikilink" href="/n/7">Other note</a></p>';
my $text = plain_text($html);
is($text, <<'TEXT', 'the rendered note, flattened');
Groceries
=========

For Saturday, from the shop (https://shop.example/list) and https://x.example.

- Eggs
- Milk
  - whole
  - oat

1. first
2. second

Notes
-----

quoted

sudo apt install
  weasyprint

[x] done
[ ] not yet

----

a  b
1  2

[image: the plan] and Other note
TEXT
is(plain_text(''), '', 'nothing in, nothing out');
is(plain_text('<p>a</p><p>b</p>'), "a\n\nb\n", 'paragraphs are separated by a blank line');
is(plain_text("<p>a &amp; b &lt; c</p>"), "a & b < c\n", 'entities are text');

# --- the standalone page --------------------------------------------------
my $page = standalone_html(title => 'Groceries <b>', html => '<p>x <a href="/n/7">Other</a></p>', notebook => 'Home & garden',
    updated => '2026-11-22 10:04', url => 'https://notes.mailmasker.org/n/42', base => 'https://notes.mailmasker.org/');
like($page, qr{\A<!doctype html>\n<html lang="en">}, 'a whole document');
like($page, qr{<title>Groceries &lt;b&gt;</title>}, 'the title, escaped');
like($page, qr{<h1>Groceries &lt;b&gt;</h1>}, '... as the heading');
like($page, qr{From the notebook Home &amp; garden &middot; last changed 2026-11-22 10:04 &middot; <a href="https://notes.mailmasker.org/n/42">notes.mailmasker.org/n/42</a>}, 'the line saying where it came from');
like($page, qr{<a href="https://notes.mailmasker.org/n/7">Other</a>}, 'a site-relative link is made absolute');
unlike($page, qr{<script|<link}, 'no script, nothing loaded from outside');
unlike($page, qr{\@page}, 'no paper rules for the web page');
my $paper = standalone_html(title => 'A "quoted" title', html => '<p>x</p>', for_pdf => 1);
like($paper, qr{\@page \{ size: Letter;.*counter\(pages\)}s, 'the PDF page has paper rules and page numbers');
like($paper, qr{content: "A \\"quoted\\" title"}, 'the title in the footer, escaped for CSS');

# --- what goes to the worker -----------------------------------------------
my $ready = pdf_ready_html('<p><img src="data:image/png;base64,AAA" alt="ok"><img src="https://x.example/a.png" alt="the plan"><img src="https://y.example/b.png"></p>'
    . '<link rel="stylesheet" href="https://x.example/a.css"><script>1</script><p style="color:red" srcset="x">y</p><video poster="https://x.example/p.jpg"></video>');
like($ready, qr{<img alt="ok" src="data:image/png;base64,AAA">}, 'an inlined image stays');
like($ready, qr{<span class="img-missing">\[image: the plan\]</span>}, 'an image that could not be inlined becomes its alt text');
like($ready, qr{<span class="img-missing">\[image\]</span>}, '... or [image] without one');
unlike($ready, qr{<link|<script|<video|style=|srcset=}, 'nothing that loads, no style attributes');
is(pdf_ready_html('<li><input disabled type="checkbox"> a task</li><li><input checked disabled type="checkbox"> done</li>'),
   "<li><span class=\"task\">\x{2610}</span> a task</li><li><span class=\"task\">\x{2611}</span> done</li>", 'a task\'s checkbox becomes a glyph (a form field breaks the line in WeasyPrint)');

# --- which images are fetched -------------------------------------------------
ok(public_image_ok('https://drive.mailmasker.org/files/1/thumb'), 'a public https image');
ok(!public_image_ok('http://x.example/a.png'), 'not plain http');
ok(!public_image_ok('https://10.50.2.150/x'), 'not an IP address');
ok(!public_image_ok('https://notes/x'), 'not a bare name');
ok(!public_image_ok('https://pdns.svc.homelab/x'), 'not a fleet name');
ok(!public_image_ok('data:image/png;base64,AAA'), 'not data: (nothing to fetch)');

# --- inlining, against a local server ----------------------------------------
my $gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;";
get '/ok.gif'  => sub ($c) { $c->res->headers->content_type('image/gif'); $c->render(data => $gif) };
get '/big.gif' => sub ($c) { $c->res->headers->content_type('image/gif'); $c->render(data => 'x' x 5000) };
get '/page'    => sub ($c) { $c->render(text => '<html>not an image</html>') };
my $ua = Mojo::UserAgent->new(ioloop => Mojo::IOLoop->singleton, max_response_size => 4000);
$ua->server->app(app);
my $port = $ua->server->url->port;
# public_image_ok wants https to a public name; the test server is plain
# http on a loopback, so the rule is exercised above and bypassed here.
{
    no warnings 'redefine';
    local *Homelab::Notes::Export::public_image_ok = sub { 1 };
    my $src = "<p><img src=\"http://127.0.0.1:$port/ok.gif\" alt=\"a\"><img src=\"http://127.0.0.1:$port/big.gif\" alt=\"b\"><img src=\"http://127.0.0.1:$port/page\" alt=\"c\"><img src=\"http://127.0.0.1:$port/missing.gif\" alt=\"d\"><img src=\"data:image/gif;base64,R0lG\" alt=\"e\"></p>";
    my $got;
    inline_images_p($src, $ua, max_bytes => 4000)->then(sub ($h) { $got = $h })->wait;
    like($got, qr{<img alt="a" src="data:image/gif;base64,R0lGOD}, 'a small image is inlined');
    like($got, qr{<img alt="b" src="http://127\.0\.0\.1:$port/big\.gif">}, 'one over the size cap is left as it was');
    like($got, qr{<img alt="c" src="http://127\.0\.0\.1:$port/page">}, 'a page that is not an image is left');
    like($got, qr{<img alt="d" src="http://127\.0\.0\.1:$port/missing\.gif">}, 'a missing one is left');
    like($got, qr{<img alt="e" src="data:image/gif;base64,R0lG">}, 'an already inline one is untouched');
    my $pdf = pdf_ready_html($got);
    is(scalar(() = $pdf =~ /img-missing/g), 3, '... and the three that could not be inlined become their alt text for the PDF');
    my $many = join '', map { "<img src=\"http://127.0.0.1:$port/ok.gif\" alt=\"$_\">" } 1 .. 12;
    inline_images_p($many, $ua, max_images => 3)->then(sub ($h) { $got = $h })->wait;
    is(scalar(() = $got =~ /data:image/g), 3, 'at most max_images are fetched');
}

done_testing;
