package Homelab::Notes::Render;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Homelab::Notes::Markdown qw(markdown_to_html);
use Homelab::Notes::Clean qw(clean_html text_to_html);

our @EXPORT_OK = qw(render_body excerpt);

# A note's body as the browser gets it, by format. Markdown and HTML both end
# in Clean: that is the one gate (Clean.pm). Text is escaped as typed.
sub render_body ($format, $body) {
    $format //= 'markdown';
    $body //= '';
    return clean_html(markdown_to_html($body)) if $format eq 'markdown';
    return clean_html($body)                   if $format eq 'html';
    return text_to_html($body);
}

# The first words of a body as plain text, for a list row.
sub excerpt ($format, $body, $max = 160) {
    my $t = $body // '';
    if (($format // '') eq 'html') { $t = Mojo::DOM->new(clean_html($t) =~ s{<}{ <}gr)->all_text }
    else {
        $t =~ s/```.*?```/ /gs;
        $t =~ s/^\s*#+\s*//mg;
        $t =~ s/[*_`>~]//g;
        $t =~ s/!?\[([^\]]*)\]\([^)]*\)/$1/g;
    }
    $t =~ s/\s+/ /g;
    $t =~ s/\A\s+|\s+\z//g;
    return length($t) > $max ? substr($t, 0, $max - 1) . "\x{2026}" : $t;
}

1;
