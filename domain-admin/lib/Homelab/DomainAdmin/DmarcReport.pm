package Homelab::DomainAdmin::DmarcReport;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

use Email::MIME;
use IO::Uncompress::Gunzip qw(gunzip);
use IO::Uncompress::Unzip  qw(unzip);
use XML::LibXML;

our @EXPORT_OK = qw(extract_reports parse_report);

# Parsing for DMARC aggregate (rua) reports, kept OUT of
# script/homelab-dmarc-ingest so it can be tested without an IMAP server or a
# database. The script is then only plumbing: fetch, call these, insert.
#
# This is the part most likely to break -- receivers vary in how they package
# the same XML (zip vs gz, filename vs content-type, with or without an XML
# declaration) -- and the part whose breakage is quietest, because a report
# that fails to parse just means a domain silently has no data.

# extract_reports($raw_email) -> list of decompressed XML strings
#
# Receivers are inconsistent about content types (a .gz commonly arrives as
# application/octet-stream), so the filename is believed first and the
# content type is only a fallback. Anything that does not look like a
# <feedback> document after decompression is discarded rather than guessed at.
sub extract_reports ($raw) {
    my $em = Email::MIME->new($raw);
    my @out;
    $em->walk_parts(sub ($part) {
        my $name = $part->filename   // '';
        my $ct   = lc($part->content_type // '');
        return if $ct =~ m{^multipart/};

        my $kind = $name =~ /\.zip$/i                    ? 'zip'
                 : $name =~ /\.gz$/i                     ? 'gz'
                 : $name =~ /\.xml$/i                    ? 'xml'
                 : $ct   =~ m{application/(?:x-)?zip}    ? 'zip'
                 : $ct   =~ m{application/(?:x-)?gzip}   ? 'gz'
                 : $ct   =~ m{(?:text|application)/xml}  ? 'xml'
                 :                                         undef;
        return unless $kind;

        my $body = $part->body;
        my $xml;
        if    ($kind eq 'zip') { unzip  \$body => \$xml or die "unzip failed: $IO::Uncompress::Unzip::UnzipError\n" }
        elsif ($kind eq 'gz')  { gunzip \$body => \$xml or die "gunzip failed: $IO::Uncompress::Gunzip::GunzipError\n" }
        else                   { $xml = $body }

        push @out, $xml if defined $xml && $xml =~ /<feedback[\s>]/;
    });
    return @out;
}

sub _txt ($node, $xpath) {
    my $n = $node->findnodes($xpath)->[0];
    return undef unless $n;
    my $t = $n->textContent;
    $t =~ s/\A\s+|\s+\z//g;
    return length $t ? $t : undef;
}

# parse_report($xml) -> { report => {...}, records => [ {...}, ... ] }
#
# Dies on anything it cannot identify (no report_id), because an
# unidentifiable report cannot be stored idempotently and silently dropping
# it would hide a receiver whose format changed.
sub parse_report ($xml) {
    # no_network + expand_entities(0): these documents arrive by email from
    # third parties, so entity expansion and external fetches are both
    # refused outright (XXE / billion-laughs).
    my $doc  = XML::LibXML->load_xml(string => $xml, no_network => 1, expand_entities => 0);
    my $root = $doc->documentElement;
    die "not a DMARC feedback document\n" unless $root && $root->nodeName eq 'feedback';

    my $report_id = _txt($root, './report_metadata/report_id');
    die "report has no report_id\n" unless defined $report_id;

    my %report = (
        org_name      => _txt($root, './report_metadata/org_name') // 'unknown',
        org_email     => _txt($root, './report_metadata/email'),
        report_id     => $report_id,
        date_begin    => (_txt($root, './report_metadata/date_range/begin') // 0) + 0,
        date_end      => (_txt($root, './report_metadata/date_range/end')   // 0) + 0,
        policy_domain => _txt($root, './policy_published/domain') // 'unknown',
        policy_p      => _txt($root, './policy_published/p'),
        policy_sp     => _txt($root, './policy_published/sp'),
        policy_pct    => _txt($root, './policy_published/pct'),
        policy_adkim  => _txt($root, './policy_published/adkim'),
        policy_aspf   => _txt($root, './policy_published/aspf'),
    );

    my @records;
    for my $rec ($root->findnodes('./record')) {
        push @records, {
            source_ip     => _txt($rec, './row/source_ip'),
            message_count => (_txt($rec, './row/count') // 0) + 0,
            # policy_evaluated/*, i.e. ALIGNMENT -- not auth_results. See
            # migrations/008-dmarc-reports.sql.
            disposition   => _txt($rec, './row/policy_evaluated/disposition'),
            dkim_result   => _txt($rec, './row/policy_evaluated/dkim'),
            spf_result    => _txt($rec, './row/policy_evaluated/spf'),
            header_from   => _txt($rec, './identifiers/header_from'),
            auth_results  => {
                dkim => [ map { +{
                    domain   => _txt($_, './domain'),
                    result   => _txt($_, './result'),
                    selector => _txt($_, './selector'),
                } } $rec->findnodes('./auth_results/dkim') ],
                spf  => [ map { +{
                    domain => _txt($_, './domain'),
                    result => _txt($_, './result'),
                } } $rec->findnodes('./auth_results/spf') ],
            },
        };
    }
    return { report => \%report, records => \@records };
}

1;
