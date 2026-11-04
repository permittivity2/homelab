package Homelab::Developer::Site;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
use Mojo::JSON qw(to_json);
use Mojo::Util qw(encode trim xml_escape);
use Mojolicious;
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use Homelab::Developer::Reference qw(load_reference public_areas who_text);
use Exporter 'import';

our @EXPORT_OK = qw(build_site md_to_html);

# developer.mailmasker.org (post-cutover item 49), built as plain files from
# reference/*.yml, pages/*.md and skill/SKILL.md, so the host serving it runs
# nothing but nginx. Every page comes twice: as HTML for people, in the
# fleet's shared look, and as Markdown for tools and AI assistants, at the
# same address plus .md. llms.txt indexes the Markdown pages, and the Claude
# Code skill (skill/SKILL.md) reads them.

our $SITE = 'https://developer.mailmasker.org';
my $MARK = '.homelab-developer-site';   # left in a build directory, so a rebuild may clear it
my %STATUS = (200 => 'OK', 201 => 'Created', 202 => 'Accepted', 204 => 'No Content');

# The site's own pages, so no ability's id can take one of their names.
our %RESERVED = map { $_ => 1 } qw(index 404 getting-started claude-code reference llms robots skill);

# Builds the whole site into $o{out} (which must be empty, missing, or an
# earlier build), from the developer/ directory $o{root}. $o{webtheme} is the
# homelab-webtheme source to take the shared chrome from: the repo's
# ../webtheme by default, else the installed package. Returns what it wrote.
sub build_site (%o) {
    my $root = path($o{root});
    my $out  = path($o{out});
    _clear($out);

    my $areas = public_areas(load_reference($root->child('reference')));
    my @all   = map { @{ $_->{abilities} } } @$areas;
    if (my @taken = grep { $RESERVED{ $_->{id} } } @all) {
        die "these ability ids are the names of the site's own pages: " . join(', ', map { $_->{id} } @taken) . "\n";
    }

    my %v = (
        site    => $SITE,
        api     => $Homelab::Developer::Reference::BASE,
        me      => $Homelab::Developer::Reference::EXAMPLE{me},
        domain  => $Homelab::Developer::Reference::EXAMPLE{domain},
        version => $o{version} // 'dev',
        built   => strftime('%Y-%m-%d', gmtime($o{time} // $ENV{SOURCE_DATE_EPOCH} // time)),
    );
    my $skill = _fill($root->child('skill', 'SKILL.md')->slurp('UTF-8'), 'skill/SKILL.md', %v);
    my %page;
    for my $name (qw(getting-started claude-code)) {
        my $md = _fill($root->child('pages', "$name.md")->slurp('UTF-8'), "pages/$name.md", %v, skill => _fence($skill, 'markdown'));
        my ($title) = $md =~ /\A# (.+)\n/ or die "pages/$name.md: the first line must be its '# ' title\n";
        $page{$name} = { md => $md, title => $title, body => $md =~ s/\A# .+\n+//r };
    }

    my $app  = _renderer($root, $o{webtheme});
    # (Not "inline" or "status": Mojolicious keeps those stash names for itself.)
    my %base = (areas => $areas, v => \%v, who_text => \&who_text, fmt => \&_inline,
                example_text => \&_example_text, status_text => \%STATUS);
    my $html = sub ($file, $template, %stash) {
        my $c = $app->build_controller;
        my $s = $c->render_to_string(template => $template, layout => 'developer', %base, %stash)
            // die "$template: rendered nothing\n";
        _write($out, $file, "$s");
    };

    # People: Getting started (the home page), one page per ability, the
    # Claude Code page, and the page nginx shows for a wrong address.
    my ($sign_in) = grep { $_->{method} eq 'POST' && $_->{path} eq '/api/v1/auth/login' } @all;
    $html->('index.html', 'page', current => 'start', crumb => 'API reference', title => $page{'getting-started'}{title},
            description => 'How to sign in, send a token, and read the answers of the MailMasker API.',
            alternate => '/getting-started.md', body => md_to_html($page{'getting-started'}{body}), example => $sign_in);
    $html->("$_->{id}.html", 'ability', current => $_->{id}, entry => $_, title => $_->{title},
            description => $_->{summary}, alternate => "/$_->{id}.md") for @all;
    $html->('claude-code.html', 'page', current => 'claude-code', crumb => 'For tools', title => $page{'claude-code'}{title},
            description => 'A Claude Code skill that looks the MailMasker API up on this site as it works.',
            alternate => '/claude-code.md', body => md_to_html($page{'claude-code'}{body}));
    $html->('404.html', 'page', current => '', crumb => 'API reference', title => 'Not found', description => '',
            body => md_to_html("There's no page at this address. Every ability is in the menu, and [Getting started](/) is the place to begin."));

    # Tools: each page as Markdown, everything in one file, the index for AI
    # tools, the same as JSON, and the skill itself.
    _write($out, "$_.md", _links_for_md($page{$_}{md})) for keys %page;
    _write($out, "$_->{id}.md", _ability_md($_, level => 1)) for @all;
    _write($out, 'reference.md', _reference_md($areas, $page{'getting-started'}, \%v));
    _write($out, 'llms.txt', _llms_txt($areas, \%v));
    _write($out, 'reference.json', to_json({ site => $v{site}, api => $v{api}, version => $v{version},
        built => $v{built}, areas => $areas }) =~ s{\\/}{/}gr . "\n");
    _write($out, 'skill/SKILL.md', $skill);
    _write($out, 'robots.txt', "User-agent: *\nAllow: /\n");
    _write($out, $MARK, "Built by homelab-developer $v{version}; homelab-developer-build may clear this directory.\n");
    return { pages => scalar(@all) + 3, abilities => scalar(@all), out => "$out" };
}

# --- Markdown into HTML ---------------------------------------------------
#
# Only the little the pages use: # to ### headings, paragraphs, - and 1.
# lists, ``` code blocks (shown with a Copy button), and inline `code`,
# **bold** and [links](/path). Everything else is plain text, escaped.
sub md_to_html ($md) {
    my @lines = split /\n/, $md;
    my ($i, @out) = (0);
    while ($i < @lines) {
        my $l = $lines[$i];
        if ($l =~ /\A(`{3,})\w*\s*\z/) {
            my ($fence, @code) = ($1);
            push @code, $lines[$i] while ++$i < @lines && $lines[$i] !~ /\A\Q$fence\E\s*\z/;
            $i++;
            push @out, '<div class="ref-snippet"><pre>' . xml_escape(join "\n", @code)
                . '</pre><button type="button" class="btn btn-ghost btn-sm copy">Copy</button></div>';
        } elsif ($l =~ /\A(#{1,3})\s+(.+)\z/) {
            my $n = length $1;
            push @out, "<h$n>" . _inline($2) . "</h$n>";
            $i++;
        } elsif ($l =~ /\A(?:([-*])|\d+\.)\s+/) {
            my ($tag, $item) = ($1 ? 'ul' : 'ol', $1 ? qr/\A[-*]\s+(.*)\z/ : qr/\A\d+\.\s+(.*)\z/);
            my @items;
            while ($i < @lines && $lines[$i] =~ $item) {
                push @items, $1;
                $items[-1] .= " $1" while ++$i < @lines && $lines[$i] =~ /\A\s{2,}(\S.*)\z/;
            }
            push @out, qq{<$tag class="ref-notes">} . join('', map { '<li>' . _inline($_) . '</li>' } @items) . "</$tag>";
        } elsif ($l =~ /\A\s*\z/) {
            $i++;
        } else {
            my @p;
            push @p, $lines[$i++] while $i < @lines && $lines[$i] !~ /\A\s*\z/ && $lines[$i] !~ /\A(?:#{1,3}\s|[-*]\s|\d+\.\s|```)/;
            push @out, '<p>' . _inline(join ' ', @p) . '</p>';
        }
    }
    return join "\n", @out;
}

# A line of text as HTML: `code` first, so nothing inside it is read as a
# link or bold; then [links](...) and **bold**. Entries use it too, for the
# `code` in their descriptions and notes.
sub _inline ($t) {
    return join '', map {
        /\A`([^`]+)`\z/ ? '<code>' . xml_escape($1) . '</code>' : _links_and_bold(xml_escape($_))
    } split /(`[^`]+`)/, $t // '';
}
sub _links_and_bold ($t) {
    $t =~ s{\[([^\]]+)\]\(([^)\s]+)\)}{<a href="$2">$1</a>}g;
    $t =~ s{\*\*([^*]+)\*\*}{<strong>$1</strong>}g;
    return $t;
}

# --- Markdown for tools -----------------------------------------------------

# One ability as Markdown, its title at heading $o{level}.
sub _ability_md ($e, %o) {
    my $h = '#' x ($o{level} // 1);
    my $sub = "$h#";
    my $base = $Homelab::Developer::Reference::BASE;
    my @md = ("$h $e->{title}", '', "`$e->{method} $base$e->{path}`", '', $e->{summary}, '',
        '- Who can use it: ' . who_text($e->{who}),
        "- Area: $e->{area}",
        "- Answers $e->{status} " . ($STATUS{ $e->{status} } // '') . ' when it works',
        "- Page: $SITE/$e->{id}", '',
        trim($e->{description} // ''), '');
    if (my @p = @{ $e->{params} }) {
        push @md, "$sub Parameters", '', '| Name | In | Required | What it is | Example |', '|---|---|---|---|---|',
            (map { '| ' . join(' | ', "`$_->{name}`", $_->{in}, ($_->{required} ? 'yes' : 'no'), _cell($_->{about}),
                   defined $_->{example} ? '`' . _cell(_example_text($_->{example})) . '`' : '') . ' |' } @p), '';
    }
    push @md, "$sub Good to know", '', (map { "- $_" } @{ $e->{notes} }), '' if @{ $e->{notes} };
    my $x = $e->{examples};
    push @md, "$sub Examples", '', 'cURL:', '', _fence($x->{curl}, 'bash'), '', 'Perl:', '', _fence($x->{perl}, 'perl'), '',
        'homelab-cli:', '', (defined $x->{cli} ? _fence($x->{cli}, 'bash') : 'There is no homelab-cli command for this yet.'), '';
    my $resp = trim($e->{response} // '');
    push @md, "$sub Response", '', "$e->{status} " . ($STATUS{ $e->{status} } // '') . ':', '',
        _fence($resp, $resp =~ /\A[\[{]/ ? 'json' : 'text'), '';
    return join "\n", @md;
}

# Everything in one file: Getting started, then every area and its abilities.
sub _reference_md ($areas, $start, $v) {
    my @md = ('# The MailMasker API', '',
        "Version $v->{version}, built $v->{built}. Everything on $v->{site} in one file: Getting started, then every ability, by area.", '',
        _demote(_links_for_md($start->{md})), '');
    for my $area (@$areas) {
        push @md, "## $area->{area}", '';
        push @md, trim($area->{intro}), '' if $area->{intro};
        push @md, _ability_md($_, level => 3) for @{ $area->{abilities} };
    }
    return join "\n", @md;
}

# The index for AI tools, in the llms.txt form (llmstxt.org): a title, a
# one-line summary, then a list of links per area.
sub _llms_txt ($areas, $v) {
    my @t = ('# The MailMasker API', '',
        "> The HTTP API behind MailMasker: sign-in and tokens, mail addresses and blocking, Drive, search, sessions, invites, domains and site administration, at $v->{api}.", '',
        'Each link is one ability, as Markdown: what it does, who may use it, its parameters, an example answer, and examples in cURL, Perl and homelab-cli. Start with Getting started for signing in, tokens and errors. Examples use you@example.com and example.com in place of a real address and domain.', '',
        '## Getting started', '',
        "- [Getting started]($SITE/getting-started.md): the api's address, signing in, sending and refreshing the token, errors, and installing homelab-cli", '');
    for my $area (@$areas) {
        push @t, "## $area->{area}", '';
        push @t, map { "- [$_->{title}]($SITE/$_->{id}.md): `$_->{method} $_->{path}`. $_->{summary} Who: " . who_text($_->{who}) . '.' } @{ $area->{abilities} };
        push @t, '';
    }
    push @t, '## Optional', '',
        "- [The whole reference]($SITE/reference.md): every page above, in one file",
        "- [reference.json]($SITE/reference.json): the same, as JSON",
        "- [The Claude Code skill]($SITE/claude-code.md): install it, and Claude looks calls up here as it works", '';
    return join "\n", @t;
}

# The pages link within the site as /name; as Markdown, those links point at
# the Markdown pages, in full.
sub _links_for_md ($md) {
    return $md =~ s{\]\((/[^)\s]*)\)}{'](' . _md_url($1) . ')'}ger;
}
sub _md_url ($p) {
    return "$SITE/getting-started.md" if $p eq '/';
    return $p =~ m{\.\w+\z} ? "$SITE$p" : "$SITE$p.md";
}

# Every heading one level down, outside code blocks.
sub _demote ($md) {
    my $code;
    return join "\n", map { $code = !$code if /\A```/; !$code && /\A#/ ? "#$_" : $_ } split /\n/, $md;
}

# A code block, fenced with more backticks than its text holds.
sub _fence ($text, $lang = '') {
    my ($longest) = sort { length $b <=> length $a } (($text // '') =~ /(`+)/g), '';
    my $f = '`' x (length($longest) < 3 ? 3 : length($longest) + 1);
    return "$f$lang\n" . trim($text // '') . "\n$f";
}

sub _cell ($t) { return ($t // '') =~ s/\|/\\|/gr =~ s/\s*\n\s*/ /gr }

# A param's example as text: JSON for lists and objects, true or false.
sub _example_text ($v) {
    return $v ? 'true' : 'false' if blessed($v) && $v->isa('JSON::PP::Boolean');
    return to_json($v) =~ s{\\/}{/}gr if ref $v;
    return $v // '';
}

# --- building ---------------------------------------------------------------

# {site}, {api}, {me}, {domain}, {version} and {built} filled in. A name left
# over is a mistake in the page, so it stops the build.
sub _fill ($text, $file, %v) {
    $text =~ s/\{([a-z_]+)\}/exists $v{$1} ? $v{$1} : "{$1}"/ge;
    my %left = map { $_ => 1 } $text =~ /\{([a-z_]+)\}/g;
    die "$file: unknown {" . join('}, {', sort keys %left) . "}\n" if %left;
    return $text;
}

# A Mojolicious app used only to render templates: the site's own, and the
# shared header and footer from homelab-webtheme.
sub _renderer ($root, $webtheme) {
    my $wt = path($webtheme // $root->sibling('webtheme'));
    my $app = Mojolicious->new;
    $app->log->level('fatal');
    $app->renderer->paths([ $root->child('templates')->to_string ]);
    my %theme = (app_name => 'MailMasker API', nav_links => [ { href => '/claude-code', label => 'Claude Code skill' } ]);
    if (-d $wt->child('templates', 'homelab')) {
        unshift @INC, $wt->child('lib')->to_string if -d $wt->child('lib');
        local $ENV{HOMELAB_WEBTHEME_HOME} = $wt->to_string;
        $app->plugin('Homelab::WebTheme' => \%theme);
    } else {
        $app->plugin('Homelab::WebTheme' => \%theme);   # the installed package's
    }
    return $app;
}

sub _clear ($out) {
    if (-e $out) {
        die "$out is not a directory\n" unless -d $out;
        die "$out has files in it that an earlier build didn't leave; refusing to clear it\n"
            if $out->list({ hidden => 1, dir => 1 })->size && !-e $out->child($MARK);
        $out->remove_tree;
    }
    $out->make_path;
}

sub _write ($out, $file, $chars) {
    my $f = $out->child(split m{/}, $file);
    $f->dirname->make_path;
    $f->spew(encode('UTF-8', $chars));
}

1;
