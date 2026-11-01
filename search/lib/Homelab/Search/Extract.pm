package Homelab::Search::Extract;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(extract best_created_at EXTRACTOR_VERSION keys_catalogue);

# PER-TYPE METADATA, for files whose useful facts are not in their text.
#
# A photo's camera, a video's duration, a PDF's page count and a zip's
# member list are all things a person searches on and none of them appear
# in the body text the indexer already stores. This turns them into rows.
#
# ADVERSARIAL INPUT, ALWAYS. These bytes came from strangers -- an emailed
# PDF, an uploaded image -- and image and document parsers are a large
# attack surface. So: a wall-clock alarm around every extraction, a size
# ceiling before it starts, a cap on every value that comes back, no shell
# anywhere, and any failure means the file is indexed on its basic fields
# alone rather than failing the unit. A file that will not parse is not an
# error; it is a file without metadata.
#
# Pure Perl on purpose. Image::ExifTool is one well-maintained pure-Perl
# library covering images, video, audio, PDF and Office; Archive::Zip lists
# zip members. Neither forks a media toolchain, which is the thing the plan
# explicitly did not want on hosts that also hold the mail store.

use constant {
    # BUMP THIS when the tag map or a transform changes. drive_items records
    # the version it was extracted with, so "which files predate this
    # extractor" is an indexed comparison and the re-index is incremental
    # rather than a full rebuild.
    EXTRACTOR_VERSION => 3,

    # Generous on purpose. ExifTool reads HEADERS, not the file -- a 564 MB
    # video in this corpus is parsed in milliseconds -- and Archive::Zip
    # reads the central directory with a seek. A 256 MB cap looked prudent
    # and silently skipped every video on the system. The real bound on
    # work is the alarm below; this only rejects the absurd.
    MAX_BYTES    => 8 * 1024 * 1024 * 1024,
    TIMEOUT_S    => 10,
    MAX_TEXT     => 400,                # per text value
    MAX_MEMBERS  => 60,                 # zip members listed
};

# Loaded lazily and tolerated if absent: a host without the libraries still
# indexes, it just records no metadata. That keeps the package installable
# before its Recommends land.
my ($HAVE_EXIFTOOL, $HAVE_ZIP);
sub _exiftool () {
    return $HAVE_EXIFTOOL if defined $HAVE_EXIFTOOL;
    $HAVE_EXIFTOOL = eval { require Image::ExifTool; 1 } ? 1 : 0;
    return $HAVE_EXIFTOOL;
}
sub _zip () {
    return $HAVE_ZIP if defined $HAVE_ZIP;
    $HAVE_ZIP = eval { require Archive::Zip; 1 } ? 1 : 0;
    return $HAVE_ZIP;
}

# ---------------------------------------------------------------- the keys
#
# One catalogue, used to seed search.metadata_keys and to decide how a value
# is stored. `kind` picks the column (text/num/at) -- the key determines the
# type, which is why the type lives on the key and not on every row.
#
# `sensitive` is load-bearing, not a label. A photo's coordinates are the
# single most revealing field here, and AI mode filters sensitive keys out
# of everything it sends to a third party. The owner still sees them.
my @KEYS = (
    [ 'media.width',            'Width',            'num',  0 ],
    [ 'media.height',           'Height',           'num',  0 ],
    [ 'media.duration_s',       'Duration',         'num',  0 ],
    [ 'media.created_at',       'Created',          'at',   0 ],

    [ 'image.camera_make',      'Camera make',      'text', 0 ],
    [ 'image.camera_model',     'Camera model',     'text', 0 ],
    [ 'image.lens',             'Lens',             'text', 0 ],
    [ 'image.taken_at',         'Taken',            'at',   0 ],
    [ 'image.orientation',      'Orientation',      'num',  0 ],
    [ 'image.iso',              'ISO',              'num',  0 ],
    [ 'image.f_number',         'Aperture',         'num',  0 ],
    [ 'image.exposure_s',       'Exposure',         'num',  0 ],
    [ 'image.focal_length_mm',  'Focal length',     'num',  0 ],

    # PEOPLE. A name attached to a photo is PII about somebody who is not
    # the account holder and never agreed to anything -- arguably more
    # sensitive than the coordinates, which only say where the owner was.
    # Sensitive, therefore, on the same mechanism: stored, searchable by
    # the owner, never sent to a third party.
    #
    # A count is not identifying on its own, so "photos with people in
    # them" stays answerable by AI mode while the names do not leave.
    [ 'people.names',           'People',           'text', 1 ],
    [ 'people.count',           'People count',     'num',  0 ],

    [ 'image.keywords',         'Keywords',         'text', 0 ],
    [ 'image.description',      'Description',      'text', 0 ],

    [ 'gps.latitude',           'Latitude',         'num',  1 ],
    [ 'gps.longitude',          'Longitude',        'num',  1 ],
    [ 'gps.altitude_m',         'Altitude',         'num',  1 ],

    [ 'video.codec',            'Video codec',      'text', 0 ],
    [ 'video.frame_rate',       'Frame rate',       'num',  0 ],

    [ 'media.bitrate',          'Bitrate',          'num',  0 ],
    [ 'audio.artist',           'Artist',           'text', 0 ],
    [ 'audio.album',            'Album',            'text', 0 ],
    [ 'audio.title',            'Track title',      'text', 0 ],
    [ 'audio.year',             'Year',             'num',  0 ],

    [ 'doc.title',              'Title',            'text', 0 ],
    [ 'doc.author',             'Author',           'text', 0 ],
    [ 'doc.subject',            'Subject',          'text', 0 ],
    [ 'doc.keywords',           'Keywords',         'text', 0 ],
    [ 'doc.page_count',         'Pages',            'num',  0 ],
    [ 'doc.word_count',         'Words',            'num',  0 ],
    [ 'doc.producer',           'Produced by',      'text', 0 ],
    [ 'doc.creator',            'Created by',       'text', 0 ],
    [ 'doc.created_at',         'Document created', 'at',   0 ],
    [ 'doc.modified_at',        'Document modified','at',   0 ],

    [ 'archive.member_count',   'Files inside',     'num',  0 ],
    [ 'archive.members',        'Contents',         'text', 0 ],
);

sub keys_catalogue () {
    return [ map { { key_name => $_->[0], label => $_->[1],
                     value_kind => $_->[2], sensitive => $_->[3] } } @KEYS ];
}
my %KIND = map { $_->[0] => $_->[2] } @KEYS;

# --------------------------------------------------- ExifTool tag -> our key
#
# Only these tags are requested. Asking for everything returns a few hundred
# per file, most of it noise, and bounds nothing.
my %TAG = (
    ImageWidth       => 'media.width',
    ImageHeight      => 'media.height',
    Duration         => 'media.duration_s',
    Make             => 'image.camera_make',
    Model            => 'image.camera_model',
    LensModel        => 'image.lens',
    DateTimeOriginal => 'image.taken_at',
    Orientation      => 'image.orientation',
    ISO              => 'image.iso',
    FNumber          => 'image.f_number',
    ExposureTime     => 'image.exposure_s',
    FocalLength      => 'image.focal_length_mm',
    # Face tagging has three standards in the wild and a photo may carry
    # any of them: MWG Regions (Lightroom, digiKam, Picasa), Microsoft's
    # People Tags, and IPTC Extension's PersonInImage. All three are read;
    # whichever the writing application used, the names end up in one key.
    RegionName              => 'people.names',
    RegionPersonDisplayName => 'people.names',
    PersonInImage           => 'people.names',
    Keywords                => 'image.keywords',
    XPKeywords              => 'image.keywords',
    ImageDescription        => 'image.description',
    'Caption-Abstract'      => 'image.description',
    GPSLatitude      => 'gps.latitude',
    GPSLongitude     => 'gps.longitude',
    GPSAltitude      => 'gps.altitude_m',
    CompressorName   => 'video.codec',
    VideoFrameRate   => 'video.frame_rate',
    AvgBitrate       => 'media.bitrate',
    Artist           => 'audio.artist',
    Album            => 'audio.album',
    Year             => 'audio.year',
    Title            => 'doc.title',
    Author           => 'doc.author',
    Subject          => 'doc.subject',
    Keywords         => 'doc.keywords',
    PageCount        => 'doc.page_count',
    Words            => 'doc.word_count',
    Producer         => 'doc.producer',
    Creator          => 'doc.creator',
    CreateDate       => 'doc.created_at',
    ModifyDate       => 'doc.modified_at',
);
my @WANTED = sort keys %TAG;

# ExifTool dates are 'YYYY:MM:DD HH:MM:SS' with an optional offset.
#
# A zero date is REAL and common -- the QuickTime files in this corpus carry
# '0000:00:00 00:00:00' -- and feeding that to Postgres is either an error
# or a year-zero timestamp that sorts before everything. Rejected here.
sub _at ($v) {
    return undef unless defined $v && !ref $v;
    return undef unless $v =~ /\A(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(.*)\z/;
    my ($Y, $M, $D, $h, $m, $s, $rest) = ($1, $2, $3, $4, $5, $6, $7 // '');
    return undef if $Y eq '0000' || $M eq '00' || $D eq '00';
    return undef if $M > 12 || $D > 31 || $h > 23 || $m > 59 || $s > 60;
    my $off = ($rest =~ /([+-]\d{2}:?\d{2}|Z)/) ? $1 : '';
    $off = '' if $off eq 'Z';
    return "$Y-$M-$D $h:$m:$s" . ($off ? $off : '');
}

sub _num ($v) {
    return undef unless defined $v && !ref $v;
    # ExifTool with PrintConv off still hands back the odd '8.7 mm'.
    #
    # The exponent is matched DELIBERATELY, even though no tag is expected
    # to use one: without it '1e400' matched just the '1' and was stored as
    # the number one -- a silently wrong value, which is worse than a
    # rejected one. Matching it lets the range check below see the overflow.
    return undef unless $v =~ /\A\s*([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/;
    my $n = $1 + 0;
    # Postgres double precision would take it, but a NaN or a 1e300 in a
    # metadata column is corruption, not data.
    return undef unless $n == $n && abs($n) < 1e15;
    return $n;
}

sub _text ($v) {
    return undef unless defined $v;
    # Several of these tags are naturally multi-valued -- three faces in a
    # photo is three RegionNames -- and ExifTool hands those back as an
    # arrayref. Returning undef for a ref (the previous behaviour) would
    # have silently dropped exactly the photos that were tagged.
    if (ref $v eq 'ARRAY') {
        my @parts = grep { defined && length } map { ref $_ ? () : $_ } @$v;
        return undef unless @parts;
        $v = join ', ', @parts;
    }
    return undef if ref $v;
    $v =~ s/\0//g;
    $v =~ s/\s+/ /g;
    $v =~ s/\A\s+|\s+\z//g;
    return undef unless length $v;
    return length($v) > MAX_TEXT ? substr($v, 0, MAX_TEXT) . '…' : $v;
}

# Camera factory placeholders, which are not descriptions of anything.
#
# Every DJI photo in this corpus carries ImageDescription 'default'; Olympus
# stamps 'OLYMPUS DIGITAL CAMERA' and several phones write
# 'Exif_JPEG_PICTURE'. Indexing those puts an identical, meaningless line
# under 82 photos and makes a real description harder to spot.
#
# Matched on the WHOLE value and only for the description field, so a photo
# a person actually captioned "default" keeps its caption. This is a short
# list of known strings, deliberately not a cleverness that guesses.
my %PLACEHOLDER = map { lc($_) => 1 } (
    'default', 'olympus digital camera', 'exif_jpeg_picture',
    'exif_jpeg_420', 'samsungcamera', 'digital camera', 'camera',
);

sub _coerce ($key, $v) {
    my $kind = $KIND{$key} // 'text';
    return _num($v) if $kind eq 'num';
    return _at($v)  if $kind eq 'at';
    my $text = _text($v);
    return undef if defined $text && $key eq 'image.description'
                 && $PLACEHOLDER{ lc $text };
    return $text;
}

# ------------------------------------------------------------------- zip
sub _zip_members ($path) {
    return {} unless _zip();
    my %out;
    my $zip = Archive::Zip->new;
    # read() returns a status rather than dying, and a corrupt archive is a
    # normal thing to be sent.
    return {} unless $zip->read($path) == Archive::Zip::AZ_OK();
    my @names = map { $_->fileName } $zip->members;
    $out{'archive.member_count'} = scalar @names;
    # The member list is what makes "the zip with the invoice in it"
    # findable, so it is indexed as text. Clipped: a zip can hold 100k
    # entries and the point is to be searchable, not complete.
    my @show = @names > MAX_MEMBERS ? @names[0 .. MAX_MEMBERS - 1] : @names;
    my $joined = join ' ', @show;
    $out{'archive.members'} = _text($joined) if length $joined;
    return \%out;
}

# ------------------------------------------------------------------ entry
#
# Returns a hashref of our key => already-coerced value. Never dies.
sub extract ($mime, $path, %opt) {
    my $log = $opt{log};
    $mime = lc($mime // '');
    return {} unless defined $path && length $path;

    my $size = -s $path;
    return {} unless defined $size && $size > 0 && $size <= MAX_BYTES;

    my %out;
    my $ok = eval {
        # The alarm is the only thing standing between a malformed file and
        # an indexer that stops making progress. local-ised so it cannot
        # leak into the caller's own timing.
        local $SIG{ALRM} = sub { die "extract timeout\n" };
        alarm TIMEOUT_S;

        if ($mime eq 'application/zip' || $mime eq 'application/x-zip-compressed') {
            %out = %{ _zip_members($path) };
        }
        elsif (_exiftool()) {
            # PrintConv off: we want 45.337 and 0.0125, not
            # q{45 deg 20' 14.34" N} and '1/80'.
            #
            # Duplicates off matters more than it looks: with duplicates on,
            # ExifTool also returns 'GPSLatitude (2)', and the duplicate has
            # LOST the hemisphere sign -- so a south-hemisphere photo would
            # be recorded in the north.
            my $et = Image::ExifTool->new;
            $et->Options(PrintConv => 0, Duplicates => 0, Composite => 1,
                         FastScan => 0, Charset => 'UTF8');
            # NO TAG LIST. Passing one looks like the careful thing and
            # quietly breaks COMPOSITE tags -- Duration, VideoFrameRate and
            # CompressorName are derived from other tags, and ExifTool
            # cannot derive them from a set it was told not to read. The
            # symptom was every video indexing with dimensions but no
            # duration. Reading everything costs nothing measurable here
            # (a 564 MB video returns in under a millisecond, because only
            # headers are touched) and the alarm is the real bound.
            my $info = $et->ImageInfo($path);
            for my $tag (@WANTED) {
                my $key = $TAG{$tag} or next;
                next if exists $out{$key};        # first writer wins
                my $v = _coerce($key, $info->{$tag});
                $out{$key} = $v if defined $v;
            }
            # An image's own CreateDate is its taken-at, not a document
            # date; move it so a photo without DateTimeOriginal still gets
            # one, and so doc.created_at means what it says.
            if ($mime =~ m{^image/} && !exists $out{'image.taken_at'}
                && exists $out{'doc.created_at'}) {
                $out{'image.taken_at'} = delete $out{'doc.created_at'};
            }
            # CompressorName is the readable one ('Lavc58 dnxhd'); the
            # fourcc is the fallback when a file carries only that.
            $out{'video.codec'} //= _text($info->{CompressorID})
                if defined $info->{CompressorID};
            if ($mime =~ m{^(?:video|audio)/} && exists $out{'doc.created_at'}) {
                $out{'media.created_at'} = delete $out{'doc.created_at'};
            }
            # The count is derived rather than read: no standard provides
            # one, and it is the part that may be shared.
            if (defined $out{'people.names'}) {
                my @n = split /\s*,\s*/, $out{'people.names'};
                $out{'people.count'} = scalar @n if @n;
            }
            # A photo is not a document. Dropping these keeps doc.* meaning
            # "this file is a document", so a search for an author or a
            # page count never matches a JPEG whose EXIF happened to carry
            # a CreateDate.
            delete @out{qw(doc.producer doc.creator doc.title doc.author
                           doc.subject doc.keywords doc.page_count doc.word_count
                           doc.created_at doc.modified_at)}
                if $mime =~ m{^(?:image|video|audio)/};
        }
        alarm 0;
        1;
    };
    alarm 0;
    if (!$ok) {
        my $e = $@ || 'unknown';
        chomp $e;
        $log->debug("extract: $mime $path: $e") if $log;
        return {};
    }
    return \%out;
}

# The best "when was this actually made" we can offer, for
# drive_items.content_created_at. EXIF beats the upload time by years.
sub best_created_at ($meta) {
    return $meta->{'image.taken_at'} // $meta->{'media.created_at'}
        // $meta->{'doc.created_at'};
}

1;
