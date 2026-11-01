package Homelab::Search::Mime;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(categories category_label categories_of classify friendly
                    friendly_set
                    parse_tokens token_sql);

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
# Categories deliberately OVERLAP (PDF is its own entry and also an Office
# document; text/csv is Text and also a Spreadsheet). That is not a bug to
# normalize away: include is an OR and exclude is a NOT-OR, so overlap costs
# nothing and the alternative -- forcing every type into exactly one bucket
# -- means arguing about where CSV goes instead of just finding the file.
#
# The overlap is now VISIBLE, which it was not before. categories_of()
# returns every category a type belongs to, so the picker lists text/csv
# under Text and under Spreadsheets, and ticking either one reveals it.
# classify() survives as "the first of those" for anything that still wants
# a single home. The earlier single-home-only rule had a real cost: it filed
# text/calendar under Text, because the broad `text` family is tested before
# the exact-type lists -- so 46 of the 54 calendar entries in the live index
# were invisible to a reader who had just ticked Calendar.
#
# THE KEYS ARE A WIRE CONTRACT. `cat:documents` is what homelab-cli's
# --type takes and what a bookmarked URL carries, so a key is renamed only
# with a reason. `documents` is now LABELLED "Word processing" and no longer
# covers PDF: PDF has its own entry and belongs to `office`, the
# super-category added for "anything that came out of an office suite".
# Anyone who had bookmarked cat:documents gets word-processor files without
# PDFs, which is the narrower and more honest reading of that name.

# Order IS the display order, commonest first.
my @CATEGORIES = (
    { key => 'pictures', featured => 1, label => 'Pictures',      types => ['image'] },
    { key => 'pdf', featured => 1,      label => 'PDF',           pairs => [ 'application/pdf' ] },
    { key => 'text', featured => 1,     label => 'Text',          types => ['text'] },
    { key => 'videos', featured => 1,   label => 'Videos',        types => ['video'] },
    # The super-category: everything an office suite produces, Microsoft or
    # LibreOffice, PDF included. The narrower entries below it still exist,
    # so "all my office files" and "just the spreadsheets" are both one tick.
    { key => 'office', featured => 1, label => 'Office documents', pairs => [
        'application/pdf',
        'application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.oasis.opendocument.text',
        'application/rtf', 'text/rtf',
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/vnd.oasis.opendocument.spreadsheet',
        'application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/vnd.oasis.opendocument.presentation',
    ] },
    { key => 'audio',    label => 'Audio',         types => ['audio'] },
    # Key kept, label corrected: "Documents" read as though it covered every
    # document, which is what `office` is for. This is word-processor files
    # only, and PDF has moved out of it.
    { key => 'documents', label => 'Word processing', pairs => [
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
        # What Windows Explorer stamps on a .zip. Present in the live index
        # and it was landing in "Other".
        'application/x-zip-compressed',
    ] },
    { key => 'calendar', label => 'Calendar', pairs => [
        'text/calendar', 'application/ics', 'application/calendar+json',
        'text/x-vcalendar',
    ] },
    { key => 'email', label => 'Email messages', pairs => [
        'message/rfc822', 'message/partial', 'application/vnd.ms-outlook',
        # Outlook rights-managed message. Also in the live index, also
        # previously ungrouped.
        'application/x-microsoft-rpmsg-message',
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

# EVERY category a specific type belongs to, in display order. This is what
# the picker groups by: a type is listed under each of its categories, so
# ticking any one of them reveals it. The caller is responsible for keeping
# the duplicate checkboxes in step -- the template renders only the first
# copy with a form name, so one type is never submitted twice.
sub categories_of ($mime) {
    my $m = lc($mime // '');
    return [] unless $m =~ m{\A([a-z]+)/(.+)\z};
    my $type = $1;
    my (@keys, %seen);
    for my $c (@ORDERED) {
        my $hit = (grep { $_ eq $type }    @{ $c->{types} || [] })
               || (grep { lc($_) eq $m }   @{ $c->{pairs} || [] });
        push @keys, $c->{key} if $hit && !$seen{ $c->{key} }++;
    }
    return \@keys;
}

# The single home, for callers that want one: the first category in display
# order. Kept because a type still has a most-obvious bucket even when it
# has several -- application/pdf is a PDF before it is an Office document.
sub classify ($mime) { return categories_of($mime)->[0] }

# What a human calls this type, and the extension they would recognise.
#
# Readability, not accuracy: the real type stays one hover away in the
# picker. application/vnd.openxmlformats-officedocument.wordprocessingml.document
# is 71 characters and wrapped to three lines in a column, which is a worse
# answer to "which of these is the Word file" than "Word document .docx".
#
# Anything unmapped falls back to itself, which is the right default --
# image/png needs no translation, and a type nobody has seen before should
# appear as what it is rather than as a guess.
my %FRIENDLY = (
    'application/pdf'  => [ 'PDF document',        '.pdf'   ],
    'application/msword' => [ 'Word document',     '.doc'   ],
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
                       => [ 'Word document',       '.docx'  ],
    'application/vnd.oasis.opendocument.text'
                       => [ 'LibreOffice Writer',  '.odt'   ],
    'application/rtf'  => [ 'Rich text',           '.rtf'   ],
    'text/rtf'         => [ 'Rich text',           '.rtf'   ],
    'application/vnd.ms-excel' => [ 'Excel workbook', '.xls' ],
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
                       => [ 'Excel workbook',      '.xlsx'  ],
    'application/vnd.oasis.opendocument.spreadsheet'
                       => [ 'LibreOffice Calc',    '.ods'   ],
    'application/vnd.ms-powerpoint' => [ 'PowerPoint', '.ppt' ],
    'application/vnd.openxmlformats-officedocument.presentationml.presentation'
                       => [ 'PowerPoint',          '.pptx'  ],
    'application/vnd.oasis.opendocument.presentation'
                       => [ 'LibreOffice Impress', '.odp'   ],
    'application/zip'  => [ 'ZIP archive',         '.zip'   ],
    'application/x-zip-compressed' => [ 'ZIP archive', '.zip' ],
    'application/gzip' => [ 'gzip archive',        '.gz'    ],
    'application/x-gzip' => [ 'gzip archive',      '.gz'    ],
    'application/x-tar' => [ 'tar archive',        '.tar'   ],
    'application/x-7z-compressed' => [ '7-Zip archive', '.7z' ],
    'application/x-rar-compressed' => [ 'RAR archive', '.rar' ],
    'application/vnd.rar' => [ 'RAR archive',      '.rar'   ],
    'message/rfc822'   => [ 'Email message',       '.eml'   ],
    'application/vnd.ms-outlook' => [ 'Outlook message', '.msg' ],
    'application/x-microsoft-rpmsg-message' => [ 'Outlook protected message', '' ],
    'application/octet-stream' => [ 'Unrecognised binary', '' ],
    'application/vnd.hp-hpgl' => [ 'HP plotter drawing', '.hpgl' ],
    'application/pgp-signature' => [ 'PGP signature', '.asc' ],
    'application/pgp-keys' => [ 'PGP key',         '.asc'   ],
    'text/calendar'    => [ 'Calendar event',      '.ics'   ],
    'application/ics'  => [ 'Calendar event',      '.ics'   ],
    'text/x-vcalendar' => [ 'Calendar event',      'vCalendar' ],
    'text/csv'         => [ 'CSV spreadsheet',     '.csv'   ],
    'text/tab-separated-values' => [ 'Tab-separated values', '.tsv' ],
    'text/plain'       => [ 'Plain text',          '.txt'   ],
    'text/html'        => [ 'HTML page',           '.html'  ],
    'text/markdown'    => [ 'Markdown',            '.md'    ],
    'text/css'         => [ 'Stylesheet',          '.css'   ],
    'application/json' => [ 'JSON',                '.json'  ],
    'application/xml'  => [ 'XML',                 '.xml'   ],
    'text/xml'         => [ 'XML',                 '.xml'   ],
    'image/jpeg'       => [ 'JPEG image',          '.jpg'   ],
    'image/jpg'        => [ 'JPEG image',          '.jpg'   ],
    'image/png'        => [ 'PNG image',           '.png'   ],
    'image/gif'        => [ 'GIF image',           '.gif'   ],
    'image/webp'       => [ 'WebP image',          '.webp'  ],
    'image/heic'       => [ 'HEIC photo',          '.heic'  ],
    'image/svg+xml'    => [ 'SVG drawing',         '.svg'   ],
    'video/mp4'        => [ 'MP4 video',           '.mp4'   ],
    'video/quicktime'  => [ 'QuickTime video',     '.mov'   ],
    'video/3gpp'       => [ '3GPP video',          '.3gp'   ],
    'audio/mpeg'       => [ 'MP3 audio',           '.mp3'   ],
    'audio/mp4'        => [ 'AAC audio',           '.m4a'   ],
);

sub friendly ($mime) {
    my $m = lc($mime // '');
    # A wildcard subtype is not a real type -- it is what the indexer stores
    # for a mail part whose Content-Type gave only the top level. Saying so
    # beats showing "image/*" and letting the reader wonder.
    return ((ucfirst $1) . ', exact type not recorded', '') if $m =~ m{\A([a-z]+)/\*\z};
    my $f = $FRIENDLY{$m} or return ($mime // '', '');
    return @$f;
}

# Friendly names for a SET of types, with collisions resolved.
#
# Several real types share one human name: image/jpeg and image/jpg are both
# "JPEG image", application/zip and application/x-zip-compressed are both
# "ZIP archive", text/calendar and application/ics are both "Calendar
# event". Two identical-looking rows with different counts is worse than no
# friendly name at all, so where a name is not unique within the set the raw
# type is shown beside it.
#
# Done by detection rather than by hand-writing "(non-standard type)" into
# the table: the table is a maintenance surface, and a rule that notices
# cannot fall behind the data the way a hand-written qualifier does.
sub friendly_set ($mimes) {
    my @rows = map { my ($l, $e) = friendly($_);
                     { mime => $_, label => $l, ext => $e } } @{ $mimes || [] };
    # Keyed on name AND extension, because the extension already separates
    # most of them: "Word document .docx" and "Word document .doc" need no
    # help, and qualifying the first would put the 71-character type back on
    # the screen that this function exists to keep it off.
    my %n;
    my $key = sub ($r) { lc($r->{label}) . '|' . lc($r->{ext} // '') };
    $n{ $key->($_) }++ for @rows;
    $_->{qualify} = ($n{ $key->($_) } > 1 ? $_->{mime} : undef) for @rows;
    return \@rows;
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
