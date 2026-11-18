package Homelab::Notes::Links;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(wikilink_html);

# A link between notes, [[Title]] or [[Title|shown as]], as both renderers
# write it (post-cutover #93). The resolver is the controller's: it answers
# a URL for a title the viewer may open, or nothing. Found: a link with the
# wikilink class (Clean keeps exactly that class). Not found: a span marked
# missing, carrying the title, which the page turns into "make this note"
# for someone who may edit. $title and $text arrive ALREADY ESCAPED (the
# renderers escape before they look for links); the lookup key is the title
# with its entities undone and its spaces squeezed.
sub wikilink_html ($title, $text, $resolver) {
    my $key = $title =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
    $key =~ s/&amp;/&/g; $key =~ s/&lt;/</g; $key =~ s/&gt;/>/g; $key =~ s/&quot;/"/g; $key =~ s/&#39;/'/g;
    my $shown = (defined $text && $text =~ /\S/) ? $text : $title;
    my $url = (ref $resolver eq 'CODE' && length $key) ? $resolver->($key) : undef;
    return '<a class="wikilink" href="' . _attr($url) . '">' . $shown . '</a>' if defined $url && length $url;
    return '<span class="wikilink wikilink--missing" data-title="' . _attr($key) . '">' . $shown . '</span>';
}

sub _attr ($s) {
    $s //= '';
    $s =~ s/&(?![a-zA-Z][a-zA-Z0-9]{1,31};|#\d{1,7};|#[xX][0-9a-fA-F]{1,6};)/&amp;/g;
    $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

1;
