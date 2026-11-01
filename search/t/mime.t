use strict;
use warnings;
use Test::More;
use lib 'lib';
use Homelab::Search::Mime qw(categories category_label categories_of classify
                             friendly friendly_set parse_tokens token_sql);

# ---------------------------------------------------------------- the widths
# One mechanism, three widths. These three forms are the whole user-facing
# contract, so they get asserted before anything else.
is_deeply parse_tokens(['image/*']),    [['image', undef]], 'image/* is the whole type';
is_deeply parse_tokens(['image/png']),  [['image', 'png']],  'image/png is one leaf';
is_deeply parse_tokens(['cat:pictures']), [['image', undef]], 'cat:pictures expands to the type';

# A curated category that CROSSES top-level types -- the reason categories
# exist at all, since no (type, subtype) rule produces this set.
my $docs = parse_tokens(['cat:documents']);
ok scalar(@$docs) >= 4, 'documents expands to several types';
ok scalar(grep { $_->[1] && $_->[1] =~ /wordprocessingml/ } @$docs),     '...including docx';
# PDF deliberately LEFT this category when it was relabelled "Word
# processing". It has its own entry and lives in the office super-category;
# a word-processing filter that returns PDFs is the thing that made the old
# "Documents" label read as broader than it was.
ok !scalar(grep { $_->[0] eq 'application' && $_->[1] eq 'pdf' } @$docs),
    'word processing no longer drags in pdf';

my $office = parse_tokens(['cat:office']);
ok scalar(grep { $_->[0] eq 'application' && $_->[1] eq 'pdf' } @$office), 'office covers pdf';
ok scalar(grep { $_->[1] && $_->[1] =~ /wordprocessingml/ }  @$office),    '...and Word';
ok scalar(grep { $_->[1] && $_->[1] =~ /spreadsheetml/ }     @$office),    '...and Excel';
ok scalar(grep { $_->[1] && $_->[1] =~ /presentationml/ }    @$office),    '...and PowerPoint';
ok scalar(grep { $_->[1] && $_->[1] =~ /opendocument/ }      @$office),    '...and LibreOffice';

my $sheets = parse_tokens(['cat:spreadsheets']);
ok scalar(grep { $_->[0] eq 'text' && $_->[1] eq 'csv' } @$sheets),
    'spreadsheets crosses into text/csv';

# Types seen in the live index that used to fall through to "Other".
for my $pair (['cat:archives', 'x-zip-compressed'], ['cat:email', 'x-microsoft-rpmsg-message'],
              ['cat:calendar', 'x-vcalendar']) {
    my ($tok, $want) = @$pair;
    ok scalar(grep { ($_->[1] // '') eq $want } @{ parse_tokens([$tok]) }),
        "$tok covers $want";
}

# ------------------------------------------------------------- real subtypes
# Subtypes in the live corpus contain dots and plusses; a tighter pattern
# would silently drop exactly the office and image types people filter on.
for my $m (qw(
    image/svg+xml application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/x-7z-compressed text/tab-separated-values message/rfc822
)) {
    my $got = parse_tokens([$m]);
    is scalar(@$got), 1, "$m parses";
    is join('/', $got->[0][0], $got->[0][1]), $m, "$m round-trips";
}

# -------------------------------------------------------------- what is DROPPED
# Parsing IS the validation, so every rejected form has to be rejected here
# rather than escaped downstream.
for my $bad (
    "image/png'; DROP TABLE search.messages; --",
    'image/png OR 1=1', '*/*', '/png', 'image/', 'image', '',
    '   ', 'cat:nope', 'cat:', 'image/*/*', "image\n/png",
    'image/png;charset=utf-8',
) {
    is_deeply parse_tokens([$bad]), [], "dropped: " . ($bad =~ s/\n/\\n/gr);
}
is_deeply parse_tokens([undef]), [], 'undef dropped';
is_deeply parse_tokens(undef),   [], 'no list at all is not an error';

# Normalisation and dedup -- a form that submits the same group twice, or a
# token typed in capitals, must not multiply the generated boolean.
is_deeply parse_tokens(['  IMAGE/PNG  ']), [['image', 'png']], 'trimmed and lowercased';
is_deeply parse_tokens(['image/png', 'image/png', 'IMAGE/PNG']), [['image', 'png']], 'deduped';
is_deeply parse_tokens(['cat:pictures', 'image/*']), [['image', undef]],
    'a category and its equivalent token collapse';

# ----------------------------------------------------------------- SQL shape
is_deeply [ token_sql('t', []) ],    [], 'nothing selected builds no clause';
is_deeply [ token_sql('t', undef) ], [], 'undef builds no clause';

my ($sql, @b) = token_sql('t', ['image/*', 'application/pdf']);
is scalar(@b), 3, 'one bind for the type, two for the leaf';
is_deeply \@b, ['image', 'application', 'pdf'], 'binds are in statement order';
like $sql, qr/\Q(t.type = ? OR (t.type = ? AND t.subtype = ?))\E/, 'ORed over the alias';
unlike $sql, qr/image|pdf/, 'no value is ever interpolated into the SQL';

my ($nsql, @nb) = token_sql('t', ['image/*'], 1);
is_deeply \@nb, ['image'], 'negation does not change the binds';
# The coalesce is load-bearing: these are LEFT joins, so a file whose type
# was never sniffed has t.type IS NULL, and a bare NOT(NULL) is NULL -- which
# would drop untyped files from a filter that asked to be WIDER.
like $nsql, qr/^NOT coalesce\(/, 'exclude wraps in coalesce(..., false)';
like $nsql, qr/false\)$/,        '...defaulting to false';

# ------------------------------------------------------------ the picker list
my $cats = categories();
ok scalar(@$cats) >= 10, 'the picker has a useful number of groups';
is $cats->[0]{key}, 'pictures', 'commonest first: pictures leads';
is $cats->[1]{key}, 'pdf',      'then PDF';

# Featured ones keep their declared order; everything after them is sorted
# case-insensitively, so a category added later lands somewhere predictable
# instead of wherever it happened to be appended.
my @labels = map { $_->{label} } @$cats;
my @featured = @labels[0 .. 4];
is_deeply \@featured, ['Pictures', 'PDF', 'Text', 'Videos', 'Office documents'],
    'the featured five, in declared order';
my @tail = @labels[5 .. $#labels];
is_deeply \@tail, [ sort { lc($a) cmp lc($b) } @tail ],
    'the rest are sorted case-insensitively';
ok !grep({ my $l = $_; grep { $_ eq $l } @featured } @tail), 'no category appears twice';

# The picker needs to know what each group covers, to tick the specific
# types underneath it.
my ($pics) = grep { $_->{key} eq 'pictures' } @$cats;
is_deeply $pics->{types}, ['image'], 'pictures exposes its top-level type';
my ($docs_c) = grep { $_->{key} eq 'documents' } @$cats;
ok scalar(@{ $docs_c->{pairs} }) > 1, 'documents exposes its explicit members';

# ------------------------------------------------------------------ classify
is classify('image/jpeg'),       'pictures',     'a leaf files under its type';
is classify('IMAGE/JPEG'),       'pictures',     'case does not matter';
is classify('application/pdf'),  'pdf',          'pdf wins over documents (declared first)';
is classify('video/quicktime'),  'videos',       'an unseen subtype still files by type';
is classify('message/rfc822'),   'email',        'an explicit member files correctly';
is classify('application/zip'),  'archives',     'archives';
# text/csv is in BOTH Text and Spreadsheets; it must be filed exactly once,
# or it renders as two checkboxes for one thing.
is classify('text/csv'),         'text',         'an overlapping leaf files under the earlier group';
is classify('application/vnd.hp-hpgl'), undef,   'an unknown type is ungrouped, not forced';
is classify('nonsense'),         undef,          'a non-mime is ungrouped';
is classify(undef),              undef,          'undef is ungrouped';

# Every leaf the categories name must classify, or the specific-types list
# would show it under "Other" while its own group sits right above.
for my $c (@$cats) {
    for my $m (@{ $c->{pairs} }) {
        ok defined classify($m), "classify knows $m";
    }
}
ok !grep({ !length($_->{label}) } @$cats), 'every group has a label';
is category_label('videos'), 'Videos', 'labels are addressable by key';
is category_label('nope'),   undef,    'an unknown key has no label';
is category_label('documents'), 'Word processing',
    'the key is the wire contract; only the label was corrected';

# ------------------------------------------------------------ categories_of
# EVERY home, not just the first. This is what the picker groups by, and
# getting it wrong is not cosmetic: the single-home version filed
# text/calendar under Text, so ticking Calendar revealed 8 of its 54 entries.
is_deeply categories_of('text/csv'),   ['text', 'spreadsheets'],
    'csv is Text and a Spreadsheet, in display order';
is_deeply categories_of('text/html'),  ['text', 'code'],         'html is Text and Code';
is_deeply categories_of('text/markdown'), ['text', 'code'],      'markdown is Text and Code';
is_deeply categories_of('text/calendar'), ['text', 'calendar'],  'calendar events are reachable from Calendar';
is_deeply categories_of('application/pdf'), ['pdf', 'office'],   'pdf is itself and an Office document';
is_deeply categories_of('application/msword'), ['office', 'documents'],
    'Word is an Office document and Word processing';
is_deeply categories_of('image/png'),  ['pictures'],             'one home is still one home';
is_deeply categories_of('application/vnd.hp-hpgl'), [],          'an unknown type has none';
is_deeply categories_of('nonsense'),   [],                       'a non-mime has none';
is_deeply categories_of(undef),        [],                       'undef has none';

# classify is the first of those, so the old single-home callers are intact.
is classify('text/csv'), categories_of('text/csv')->[0], 'classify is the first category_of';

# Every category must claim at least one of its own declared members, or the
# chip is drawn for a group the picker can never populate.
for my $c (@$cats) {
    my ($m) = (@{ $c->{pairs} }, map { "$_/x" } @{ $c->{types} });
    ok scalar(grep { $_ eq $c->{key} } @{ categories_of($m) }),
        "categories_of claims $c->{key} for $m";
}

# -------------------------------------------------------------- friendly
my ($lbl, $ext) = friendly('application/vnd.openxmlformats-officedocument.wordprocessingml.document');
is $lbl, 'Word document', 'the 71-character type has a human name';
is $ext, '.docx',         '...and the extension a person recognises';
is_deeply [ friendly('image/png') ], ['PNG image', '.png'], 'ordinary types too';
is_deeply [ friendly('application/x-not-a-real-type') ], ['application/x-not-a-real-type', ''],
    'an unmapped type falls back to itself rather than to a guess';
is_deeply [ friendly(undef) ], ['', ''], 'undef is empty, not an error';
like( (friendly('image/*'))[0], qr/not recorded/,
    'a wildcard subtype says what it is instead of showing an asterisk');

# friendly_set qualifies only where the name AND extension collide.
my $set = friendly_set([qw(image/jpeg image/jpg image/png)]);
is scalar(@$set), 3, 'one row per type';
ok $set->[0]{qualify} && $set->[1]{qualify}, 'both JPEG spellings are qualified';
ok !$set->[2]{qualify},                      'PNG is unambiguous and is not';
my $words = friendly_set([
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/msword' ]);
ok !grep({ $_->{qualify} } @$words),
    'same name, different extension: no qualifier, so the long type stays off the screen';
is_deeply friendly_set(undef), [], 'no list is not an error';

# Every advertised group must actually expand to something, or the UI offers
# a filter that silently does nothing.
for my $c (@$cats) {
    ok scalar(@{ parse_tokens(["cat:$c->{key}"]) }) > 0, "cat:$c->{key} expands";
}

done_testing;
