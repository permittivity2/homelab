use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(from_json);
use Mojo::Util qw(decode);
use Homelab::Developer::Reference qw(load_reference public_areas);
use Homelab::Developer::Site qw(build_site md_to_html);

# The site as it is built (post-cutover item 49): every page there, every
# link in it going somewhere, the shared chrome on every page, and the files
# for tools (Markdown, llms.txt, JSON, the Claude Code skill) complete and
# well formed. A broken page here would ship, since nothing renders it later.

my $root = path($FindBin::Bin)->dirname;
my $out  = tempdir->child('site');
my $r = eval { build_site(root => "$root", out => "$out", version => '9.9.9', time => 1793850130) };
ok($r, 'the site builds') or BAIL_OUT("the build failed: $@");

my @all = map { @{ $_->{abilities} } } @{ public_areas(load_reference($root->child('reference'))) };
my $file = sub ($name) { my $f = $out->child(split m{/}, $name); -f $f ? decode('UTF-8', $f->slurp) : undef };

# --- every page, for people and for tools ---------------------------------
for my $name (qw(index.html 404.html claude-code.html getting-started.md claude-code.md
                 reference.md reference.json llms.txt skill/SKILL.md robots.txt)) {
    ok(defined $file->($name), "$name is built");
}
is((grep { !defined $file->("$_->{id}.html") || !defined $file->("$_->{id}.md") } @all), 0,
   'every ability has its page, as HTML and as Markdown (' . scalar(@all) . ')');
my @fleet = grep { $_->{who} eq 'fleet' } map { @{ $_->{abilities} } } @{ load_reference($root->child('reference'))->{areas} };
ok(@fleet, 'the reference has fleet-only routes...');
is((grep { -e $out->child("$_->{id}.html") } @fleet), 0, '... and none of them gets a page');

# --- the HTML ---------------------------------------------------------------
my @html = grep { /\.html\z/ } $out->list_tree->map('to_string')->each;
my (%bad_link, @no_chrome, @leftover);
for my $f (@html) {
    my $text = decode('UTF-8', path($f)->slurp);
    my $rel = path($f)->to_rel($out);
    push @no_chrome, $rel unless $text =~ /class="topbar"/ && $text =~ m{static\.mailmasker\.org/theme/v1/theme\.css} && $text =~ /class="appfoot"/;
    push @leftover, $rel if $text =~ /```|\{(?:me|domain|site|api|version|built|skill)\}/;
    for my $href ($text =~ /href="(\/[^"#?]*)"/g) {
        # nginx's try_files: the file, then name.html, then a directory's index.
        my $p = $href =~ s{\A/}{}r;
        my $ok = $p eq '' || -f $out->child($p) || -f $out->child("$p.html") || -f $out->child($p, 'index.html');
        $bad_link{"$rel -> $href"}++ unless $ok;
    }
}
is(scalar(@no_chrome), 0, 'every page has the shared header, stylesheet and footer') or diag "@no_chrome";
is(scalar(keys %bad_link), 0, 'every link within the site goes to a page or file that exists')
    or diag join "\n", sort keys %bad_link;
is(scalar(@leftover), 0, 'no page shows raw Markdown fences or an unfilled {placeholder}') or diag "@leftover";

my $home = $file->('index.html');
like($home, qr{<h1>Getting started</h1>}, 'the home page is Getting started');
like($home, qr{class="ref-code".*curl -s -X POST &#39;https://api\.mailmasker\.org/api/v1/auth/login&#39;}s,
     '... with the sign-in example beside it');
like($home, qr/export TOKEN=&#39;…&#39;/, '... in UTF-8 (the ellipsis survives)');

my ($admin) = grep { $_->{who} eq 'site-admin' } @all;
my $page = $file->("$admin->{id}.html");
like($page, qr{Who can use this: <strong>Site admins</strong>}, 'an admin ability says who may use it, in words');
like($page, qr{<pre data-lang="curl">curl -s}, '... and has its examples, as every page does');
like($page, qr{class="current" aria-current="page"><span class="m m-\Q$admin->{method}\E">}, '... and is marked in the menu');

my ($with_code) = grep { ($_->{description} // '') =~ /`[^`]+`/ } @all;
like($file->("$with_code->{id}.html"), qr{<code>[^<]+</code>}, '`code` in an entry is shown as code');
like($file->('404.html'), qr{<h1>Not found</h1>}, 'the Not found page');

# --- for tools -------------------------------------------------------------
my $llms = $file->('llms.txt');
like($llms, qr/\A# The MailMasker API\n\n> \S/, 'llms.txt: a title, then a one-line summary (llmstxt.org)');
is((grep { index($llms, "](https://developer.mailmasker.org/$_->{id}.md)") < 0 } @all), 0, '... linking every ability');
my %twice; $twice{$_}++ for $llms =~ m{\]\((https://[^)]+)\)}g;
is((grep { $twice{$_} > 1 } keys %twice), 0, '... once each');

my $whole = $file->('reference.md');
is((grep { $whole !~ /^### \Q$_->{title}\E$/m } @all), 0, 'reference.md has every ability, as a ### heading');
like($whole, qr/^## Getting started$/m, '... after Getting started');
unlike($whole, qr{\]\(/}, '... and every link in it is a full address');

my $json = eval { from_json($file->('reference.json')) };
ok($json, 'reference.json parses');
is(scalar(map { @{ $_->{abilities} } } @{ $json->{areas} // [] }), scalar(@all), '... with every ability');
is($json->{version}, '9.9.9', '... and says which version it is');

my $md = $file->('sign-in.md');
like($md, qr{\A# Sign in\n\n`POST https://api\.mailmasker\.org/api/v1/auth/login`}, 'an ability as Markdown: title, then the call');
like($md, qr/^\| `email` \| body \| yes \|/m, '... its parameters as a table');
like($md, qr/^```bash\ncurl -s -X POST/m, '... its examples as code');

# --- the Claude Code skill -----------------------------------------------------
my $skill = $file->('skill/SKILL.md');
my ($front) = $skill =~ /\A---\n(.*?)\n---\n/s;
ok($front, 'SKILL.md starts with its frontmatter');
my ($name) = ($front // '') =~ /^name: (\S+)$/m;
my ($desc) = ($front // '') =~ /^description: (.+)$/m;
is($name, 'mailmasker-api', 'the skill is mailmasker-api');
ok($name && $name =~ /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ && length($name) <= 64, '... a name Claude Code accepts');
ok($desc && length($desc) <= 1024, 'its description fits (' . length($desc // '') . ' of 1024 characters)');
like($skill, qr{https://developer\.mailmasker\.org/llms\.txt}, 'it reads llms.txt');
unlike($skill, qr/\{(?:site|api)\}/, 'its addresses are filled in');
like($file->('claude-code.html'), qr{name: mailmasker-api}, 'the Claude Code page shows the skill itself');

# --- the Markdown the pages are written in ------------------------------------
is(md_to_html("# T\n\nA `<b>` and [x](/y) and **z**.\n\n- one\n  more\n- two\n\n```\n<x> & y\n```"),
   join("\n", '<h1>T</h1>', '<p>A <code>&lt;b&gt;</code> and <a href="/y">x</a> and <strong>z</strong>.</p>',
        '<ul class="ref-notes"><li>one more</li><li>two</li></ul>',
        '<div class="ref-snippet"><pre>&lt;x&gt; &amp; y</pre><button type="button" class="btn btn-ghost btn-sm copy">Copy</button></div>'),
   'md_to_html: headings, code, links, bold, lists and code blocks, all escaped');
like(md_to_html('<script>alert(1)</script>'), qr/\A<p>&lt;script&gt;/, '... and raw HTML is shown, never run');

# --- a rebuild clears only what a build made ---------------------------------
my $other = tempdir;
$other->child('keep.txt')->spew('mine');
ok(!eval { build_site(root => "$root", out => "$other"); 1 }, 'a directory with other files in it is not cleared');
ok(-f $other->child('keep.txt'), '... and its files are still there');
ok(eval { build_site(root => "$root", out => "$out"); 1 }, 'an earlier build is cleared and rebuilt') or diag $@;

# --- the nginx site serves what the package installs ---------------------------
my $conf  = $root->child('nginx', 'developer.mailmasker.org.conf')->slurp;
my $rules = $root->child('debian', 'rules')->slurp;
like($conf, qr{^\s*root /usr/share/homelab-developer/site;}m, 'nginx serves /usr/share/homelab-developer/site');
like($rules, qr{\$\(DEST\)/usr/share/homelab-developer/site}, '... which is where debian/rules puts the site');
like($conf, qr{try_files \$uri \$uri\.html}, '... with /name served from name.html');

done_testing;
