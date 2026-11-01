use strict;
use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use Homelab::Search::Extract qw(extract best_created_at EXTRACTOR_VERSION keys_catalogue);

# The extractor runs over bytes from strangers, so most of what matters here
# is what it does with input it cannot parse. Fixtures are built in the test
# rather than committed, so the repository carries no binaries and there is
# nothing to go stale.

my $dir = tempdir(CLEANUP => 1);
sub fixture ($$) {
    my ($name, $bytes) = @_;
    my $p = "$dir/$name";
    open my $fh, '>', $p or die $!;
    binmode $fh; print $fh $bytes; close $fh;
    return $p;
}

# --------------------------------------------------------------- catalogue
my $cat = keys_catalogue();
ok scalar(@$cat) >= 30, 'the catalogue covers a useful number of fields';
ok !grep({ $_->{key_name} ne lc $_->{key_name} } @$cat), 'every key is lowercase';
ok !grep({ $_->{value_kind} !~ /\A(?:text|num|at)\z/ } @$cat), 'every kind is one of the three columns';
ok !grep({ !length $_->{label} } @$cat), 'every key has a human label';

# The sensitive set is the thing AI mode filters on, so assert exactly what
# is in it rather than that it is non-empty.
my @sensitive = sort map { $_->{key_name} } grep { $_->{sensitive} } @$cat;
is_deeply \@sensitive, [qw(gps.altitude_m gps.latitude gps.longitude people.names)],
    'the sensitive set is the GPS trio plus the names of tagged people';
# A count of people is not identifying, so it stays shareable -- "photos
# with people in them" remains answerable without naming anyone.
ok !grep({ $_->{key_name} eq 'people.count' && $_->{sensitive} } @$cat),
    'a people COUNT is not sensitive, only the names are';

my %dup;
$dup{ $_->{key_name} }++ for @$cat;
ok !grep({ $_ > 1 } values %dup), 'no key is declared twice';

# ------------------------------------------------------- refuses the absurd
is_deeply extract('image/jpeg', undef),            {}, 'no path is not an error';
is_deeply extract('image/jpeg', "$dir/nope.jpg"),  {}, 'a missing file is not an error';
is_deeply extract('image/jpeg', fixture('empty.jpg', '')), {}, 'an empty file yields nothing';

# Input that is a lie about itself: the extension and the declared type say
# image, the bytes are nothing of the kind. This is the normal case for a
# hostile upload and must be a quiet {} rather than a die.
is_deeply extract('image/jpeg', fixture('liar.jpg', "\x00" x 4096)), {},
    'a file whose bytes do not match its declared type yields nothing';
is_deeply extract('application/pdf', fixture('liar.pdf', 'not a pdf at all')), {},
    'so does a PDF that is not one';

# A truncated archive is a normal thing to be sent.
is_deeply extract('application/zip', fixture('trunc.zip', "PK\x03\x04" . ("\x00" x 64))), {},
    'a truncated zip yields nothing rather than dying';

# ------------------------------------------------------------- a real zip
SKIP: {
    skip 'Archive::Zip not installed', 3 unless eval { require Archive::Zip; 1 };
    my $zp = "$dir/real.zip";
    my $z  = Archive::Zip->new;
    $z->addString("invoice contents", "invoices/march/invoice-42.pdf");
    $z->addString("x", "notes.txt");
    $z->writeToFileNamed($zp);

    my $m = extract('application/zip', $zp);
    is $m->{'archive.member_count'}, 2, 'both members are counted';
    like $m->{'archive.members'}, qr/invoice-42\.pdf/,
        'the member list is indexed, which is what makes "the zip with the invoice in it" findable';
    ok !exists $m->{'media.width'}, 'and nothing irrelevant is invented';
}

# ------------------------------------------------- the zero-date, for real
# QuickTime files in the live corpus carry '0000:00:00 00:00:00'. Stored, it
# is either a Postgres error or a year-zero timestamp that sorts before
# everything that exists.
{
    no warnings 'once';
    my $at = \&Homelab::Search::Extract::_at;
    is $at->('0000:00:00 00:00:00'), undef, 'a zero date is rejected';
    is $at->('2026:08:09 20:59:05'), '2026-08-09 20:59:05', 'a real date is converted to ISO';
    is $at->('2026:09:01 22:27:59+00:00'), '2026-09-01 22:27:59+00:00', 'an offset is preserved';
    is $at->('2026:09:01 22:27:59Z'), '2026-09-01 22:27:59', 'a Z offset is dropped, not kept as text';
    is $at->('2026:13:45 99:99:99'), undef, 'an impossible date is rejected';
    is $at->('garbage'), undef, 'so is a non-date';
    is $at->(undef), undef, 'and undef';
}

# ------------------------------------------------------------ the numbers
{
    no warnings 'once';
    my $num = \&Homelab::Search::Extract::_num;
    is $num->('8.67'),    8.67, 'a plain number';
    is $num->('8.7 mm'),  8.7,  'a number with a unit suffix';
    is $num->('-109.012832361111'), -109.012832361111, 'a signed coordinate keeps its sign';
    is $num->('not a number'), undef, 'text is not a number';
    is $num->('1e400'),  undef, 'an overflow is refused rather than stored as inf';
    is $num->(undef),    undef, 'undef is not a number';
}

# ------------------------------------------------------------- best date
is best_created_at({ 'image.taken_at' => '2019-01-01 00:00:00',
                     'doc.created_at' => '2026-01-01 00:00:00' }),
   '2019-01-01 00:00:00', 'a photo\'s taken-at beats a document date';
is best_created_at({}), undef, 'and nothing is nothing';

# Camera placeholders: 'default' under 82 photos is noise, not a caption.
{
    no warnings 'once';
    my $c = \&Homelab::Search::Extract::_coerce;
    is $c->('image.description', 'default'), undef, "DJI's 'default' is dropped";
    is $c->('image.description', 'OLYMPUS DIGITAL CAMERA'), undef, 'so is the Olympus stamp';
    is $c->('image.description', 'Sunset over the lake'), 'Sunset over the lake',
        'a real caption survives';
    # Matched on the WHOLE value, so a caption that merely contains the word
    # is not thrown away.
    is $c->('image.description', 'the default setting was wrong'),
        'the default setting was wrong', 'a caption containing the word survives';
    # And only for descriptions: a keyword "default" is the user's own tag.
    is $c->('image.keywords', 'default'), 'default', 'keywords are left alone';
}

cmp_ok EXTRACTOR_VERSION, '>=', 1, 'the extractor is versioned, so a re-index can be incremental';

# ------------------------------------------------------ multi-valued tags
# Three faces in a photo is three RegionNames, and ExifTool returns those
# as an arrayref. Returning undef for a ref -- the first behaviour here --
# would have silently dropped exactly the photos that had been tagged.
{
    no warnings 'once';
    my $text = \&Homelab::Search::Extract::_text;
    is $text->(['Ada', 'Grace', 'Alan']), 'Ada, Grace, Alan', 'an array of names is joined';
    is $text->(['Ada']),      'Ada',  'a single-element array is still a name';
    is $text->([]),           undef,  'an empty array is nothing';
    is $text->([undef, '']),  undef,  'and so is an array of nothings';
    is $text->('Ada'),        'Ada',  'a plain string is unchanged';
    is $text->({ a => 1 }),   undef,  'a hashref is still refused';
}

# --------------------------------- face tags and camera-mode noise
# Needs ExifTool to WRITE the fixtures, so skipped where it is absent --
# but these are behavioural rules someone could undo by accident, so they
# are asserted rather than left to the live check that found them.
SKIP: {
    skip 'Image::ExifTool not installed', 7 unless eval { require Image::ExifTool; 1 };
    require MIME::Base64;

    # The smallest valid baseline JPEG, inline so the repository carries no
    # binaries. ExifTool needs a real container to write tags into.
    my $seed = fixture('seed.jpg', MIME::Base64::decode_base64(
        '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP////////////////////////////////////'
      . '////////////////////////////////////////////wgALCAABAAEBAREA/8QAFAAB'
      . 'AAAAAAAAAAAAAAAAAAAACf/aAAgBAQAAAAHSzyD/2Q=='));

    my $write = sub {
        my ($name, %tags) = @_;
        my $out = "$dir/$name";
        my $et  = Image::ExifTool->new;
        for my $k (sort keys %tags) {
            my $v = $tags{$k};
            $et->SetNewValue($k, $_, AddValue => 1) for (ref $v ? @$v : $v);
        }
        return $et->WriteInfo($seed, $out) ? $out : undef;
    };

    # All three face-tagging standards reach the same key.
    for my $pair ([ RegionName              => 'MWG Regions' ],
                  [ RegionPersonDisplayName => 'Microsoft People Tags' ],
                  [ PersonInImage           => 'IPTC Extension' ]) {
        my ($tag, $label) = @$pair;
        my $f = $write->("$tag.jpg", $tag => ['Ada Lovelace', 'Grace Hopper']) or next;
        my $m = extract('image/jpeg', $f);
        is $m->{'people.names'}, 'Ada Lovelace, Grace Hopper', "$label lands in people.names";
    }

    # A multi-face photo gives a count, which is the shareable part.
    my $f = $write->('counted.jpg', RegionName => ['A', 'B', 'C']);
    is extract('image/jpeg', $f)->{'people.count'}, 3, 'the count is derived from the names'
        if $f;

    # DJI writes its CAPTURE MODE into the user keyword field. Dropped --
    # but ONLY for DJI, because 'single' is an ordinary word and somebody
    # else's tag is their own.
    my $dji = $write->('dji.jpg',   Make => 'DJI', XPKeywords => 'single');
    my $can = $write->('canon.jpg', Make => 'Canon', XPKeywords => 'single');
    is extract('image/jpeg', $dji)->{'image.keywords'}, undef,
        "DJI's capture mode is not a keyword" if $dji;
    is extract('image/jpeg', $can)->{'image.keywords'}, 'single',
        'the same word on another camera is the owner\'s own tag' if $can;
    my $djireal = $write->('djireal.jpg', Make => 'DJI', XPKeywords => 'Montana trip');
    is extract('image/jpeg', $djireal)->{'image.keywords'}, 'Montana trip',
        'and a real keyword on a DJI photo survives' if $djireal;
}

done_testing;
