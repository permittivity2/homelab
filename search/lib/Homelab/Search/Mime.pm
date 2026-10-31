package Homelab::Search::Mime;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(categories category_label classify parse_tokens token_sql);

# MIME filtering, in ONE place, because three callers need the same answer:
# the mail query (matching a message's ATTACHMENT types), the drive query
# (matching the file's own type), and the template that draws the picker.
#
# THE SHAPE OF THE PROBLEM. A person thinks in supersets -- "pictures",
# "videos" -- and occasionally in leaves -- "specifically a PNG". Those are
# not two features; they are one, as long as a filter value can say which it
# means. So every value here is a single token, and the token's FORM says how
# wide it is:
#
#   image/*          a superset: the whole image top-level type
#   image/png        one leaf
#   cat:documents    a curated set that CROSSES top-level types
#
# The first two fall straight out of the schema -- migrations/001-search.sql
# splits mime into (type, subtype) precisely so `type = 'image'` is an
# indexed equality instead of `LIKE 'image/%'` -- and they need no
# maintenance: a subtype nobody has ever seen still matches `image/*` the
# day it arrives.
#
# The third exists because the useful groupings are not all top-level types.
# "Documents" spans application/pdf, Word, ODF and RTF; "Spreadsheets" spans
# two application/vnd.* names plus text/csv. No amount of schema makes those
# fall out of (type, subtype), so they are a curated list, and curated means
# it will drift from reality -- which is why the picker ALSO offers the
# account's real leaf types from the index itself (Query::mime_facets). The
# categories are the fast path, not the only path.
#
# Categories deliberately OVERLAP (PDF is its own entry and also a Document;
# text/csv is Text and also a Spreadsheet). That is not a bug to normalize
# away: include is an OR and exclude is a NOT-OR, so overlap costs nothing
# and the alternative -- forcing every type into exactly one bucket -- means
# arguing about where CSV goes instead of just finding the file.

# Order IS the display order, commonest first.
my @CATEGORIES = (
    { key => 'pictures', featured => 1, label => 'Pictures',      types => ['image'] },
    { key => 'pdf', featured => 1,      label => 'PDF',           pairs => [ 'application/pdf' ] },
    { key => 'text', featured => 1,     label => 'Text',          types => ['text'] },
    { key => 'videos', featured => 1,   label => 'Videos',        types => ['video'] },
    { key => 'audio',    label => 'Audio',         types => ['audio'] },
    { key => 'documents', featured => 1, label => 'Documents', pairs => [
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.oasis.opendocument.text',
        'application/rtf', 'text/rtf',
    ] },
    { key => 'spreadsheets', label => 'Spreadsheets', pairs => [
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.oasis.opendocument.spreadsheet',
        'text/csv', 'text/tab-separated-values',
    ] },
    { key => 'presentations', label => 'Presentations', pairs => [
        'application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/vnd.oasis.opendocument.presentation',
    ] },
    { key => 'archives', label => 'Archives', pairs => [
        'application/zip', 'application/gzip', 'application/x-gzip',
        'application/x-tar', 'application/x-7z-compressed',
        'application/x-rar-compressed', 'application/vnd.rar',
        'application/x-bzip2', 'application/x-xz',
    ] },
    { key => 'calendar', label => 'Calendar', pairs => [
        'text/calendar', 'application/ics', 'application/calendar+json',
    ] },
    { key => 'email', label => 'Email messages', pairs => [
        'message/rfc822', 'message/partial', 'application/vnd.ms-outlook',
    ] },
    { key => 'code', label => 'Code and data', pairs => [
        'application/json', 'application/xml', 'text/xml', 'text/html',
        'text/markdown', 'text/css', 'application/javascript',
        'text/javascript', 'application/x-perl', 'text/x-perl',
        'text/x-python', 'text/x-shellscript', 'application/x-sh',
        'application/sql', 'text/x-c', 'text/x-java',
    ] },
);

my %BY_KEY = map { $_->{key} => $_ } @CATEGORIES;

# Display order: the handful people reach for first, in the order declared
# above, and then everything else sorted case-insensitively. Sorting the tail
# rather than hand-ordering all of it means a category added later lands
# somewhere predictable instead of wherever it was appended.
my @ORDERED = (
    (grep {  $_->{featured} } @CATEGORIES),
    (sort { lc($a->{label}) cmp lc($b->{label}) } grep { !$_->{featured} } @CATEGORIES),
);

sub categories () {
    return [ map { {
        key   => $_->{key},
        label => $_->{label},
        # The picker needs to know what a category COVERS, so ticking it can
        # tick the specific types underneath it. Two shapes, because that is
        # genuinely what the categories are: a whole top-level type, or an
        # explicit list.
        types => [ @{ $_->{types} || [] } ],
        pairs => [ @{ $_->{pairs} || [] } ],
    } } @ORDERED ];
}

sub category_label ($key) { return ($BY_KEY{$key} || {})->{label} }

# Which category a specific type belongs to, for grouping the specific-types
# list under the same headings as the checkboxes. First match in display
# order wins: the categories overlap on purpose (text/csv is Text and also a
# Spreadsheet), and a thing shown twice in a list of checkboxes is a thing
# that can be ticked twice, so a leaf is filed exactly once. Featured
# categories come first in that order, so csv files under Text rather than
# somewhere alphabetical is deliberate.
sub classify ($mime) {
    my $m = lc($mime // '');
    return undef unless $m =~ m{\A([a-z]+)/(.+)\z};
    my $type = $1;
    for my $c (@ORDERED) {
        return $c->{key} if grep { $_ eq $type } @{ $c->{types} || [] };
        return $c->{key} if grep { lc($_) eq $m } @{ $c->{pairs} || [] };
    }
    return undef;
}

# A token is untrusted input and goes nowhere near SQL text, so parsing is
# also the validation: anything that is not one of the three recognised forms
# is DROPPED, not escaped and not passed through. The return is a pair of
# lists of (type, subtype) terms where subtype undef means "whole type".
sub parse_tokens ($tokens) {
    my (@terms, %seen);
    for my $raw (@{ $tokens || [] }) {
        next unless defined $raw;
        my $t = lc $raw;
        $t =~ s/\A\s+|\s+\z//g;
        next unless length $t;

        my @expand;
        if ($t =~ m{\Acat:([a-z_]+)\z}) {
            my $cat = $BY_KEY{$1} or next;
            push @expand, map { "$_/*" } @{ $cat->{types} || [] };
            push @expand, @{ $cat->{pairs} || [] };
        }
        else { @expand = ($t) }

        for my $e (@expand) {
            # Subtypes really do contain dots and plusses (vnd.*, svg+xml).
            next unless $e =~ m{\A([a-z]+)/(\*|[a-z0-9][a-z0-9.+_-]*)\z};
            my ($type, $sub) = ($1, $2);
            $sub = undef if $sub eq '*';
            my $k = $type . '/' . ($sub // '*');
            next if $seen{$k}++;
            push @terms, [ $type, $sub ];
        }
    }
    return \@terms;
}

# Build a boolean over an ALREADY-JOINED mime_types alias. Returns
# (sql, @binds) or () when nothing was selected.
#
# coalesce(..., false) matters for the exclude side: these joins are LEFT
# joins (a file whose type was never sniffed has no mime_types row), so a
# bare NOT(...) over NULL is NULL, which is not true, which would quietly
# drop every untyped file from a result set the person asked to be WIDER.
sub token_sql ($alias, $tokens, $negate = 0) {
    my $terms = parse_tokens($tokens);
    return () unless @$terms;

    my (@or, @bind);
    for my $t (@$terms) {
        if (defined $t->[1]) {
            push @or, "($alias.type = ? AND $alias.subtype = ?)";
            push @bind, $t->[0], $t->[1];
        }
        else {
            push @or, "$alias.type = ?";
            push @bind, $t->[0];
        }
    }
    my $sql = '(' . join(' OR ', @or) . ')';
    $sql = "NOT coalesce($sql, false)" if $negate;
    return ($sql, @bind);
}

1;
