use strict;
use warnings;
use Test::More;
# The compression error globals are read once each in a die message;
# `once` would otherwise warn about them as possible typos.
no warnings 'once';

# Guards Homelab::DomainAdmin::DmarcReport -- the parsing half of the DMARC
# aggregate report ingest. No database and no IMAP server: the whole point of
# extracting this out of script/homelab-dmarc-ingest is that the format
# handling is testable on its own.
#
# The sample below is a REAL report, captured from the live reporting mailbox
# on 2026-10-28 (Google, mailmasker.org, the first one to arrive after the
# zones started publishing rua=). Synthetic XML would not have caught that
# receivers ship the XML declaration, use unindented <record> children, or
# send a .zip where the obvious guess is .gz.

# Runtime require, not a compile-time use: these modules are real Depends of
# the package but a bare checkout (or a CI image that has not installed them)
# must SKIP rather than abort the whole file -- the same reason audit/t's own
# app is loaded at runtime.
eval { require Homelab::DomainAdmin::DmarcReport; 1 }
    or plan skip_all => "Homelab::DomainAdmin::DmarcReport not loadable: $@";
eval { require Email::MIME; require IO::Compress::Gzip; require IO::Compress::Zip; 1 }
    or plan skip_all => "MIME/compression modules not available: $@";
Homelab::DomainAdmin::DmarcReport->import(qw(extract_reports parse_report));

my $REAL_XML = <<'XML';
<?xml version="1.0" encoding="UTF-8" ?>
<feedback>
  <version>1.0</version>
  <report_metadata>
    <org_name>google.com</org_name>
    <email>noreply-dmarc-support@google.com</email>
    <extra_contact_info>https://support.google.com/a/answer/2466580</extra_contact_info>
    <report_id>3538878607975787600</report_id>
    <date_range>
      <begin>1793059200</begin>
      <end>1793145599</end>
    </date_range>
  </report_metadata>
  <policy_published>
    <domain>mailmasker.org</domain>
    <adkim>r</adkim>
    <aspf>r</aspf>
    <p>quarantine</p>
    <sp>quarantine</sp>
    <pct>100</pct>
    <np>quarantine</np>
  </policy_published>
  <record>
    <row>
      <source_ip>23.116.91.65</source_ip>
      <count>3</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>pass</spf>
      </policy_evaluated>
    </row>
    <identifiers>
      <header_from>mailmasker.org</header_from>
    </identifiers>
    <auth_results>
      <dkim>
        <domain>mailmasker.org</domain>
        <result>pass</result>
        <selector>20261024a</selector>
      </dkim>
      <spf>
        <domain>mailmasker.org</domain>
        <result>pass</result>
      </spf>
    </auth_results>
  </record>
</feedback>
XML

# --- parsing the real thing ------------------------------------------------
subtest 'parses a real Google aggregate report' => sub {
    my $p = parse_report($REAL_XML);
    my $r = $p->{report};
    is $r->{org_name},      'google.com',          'org_name';
    is $r->{report_id},     '3538878607975787600', 'report_id (string, not number -- it exceeds 32 bits)';
    is $r->{policy_domain}, 'mailmasker.org',      'policy domain';
    is $r->{policy_p},      'quarantine',          'published policy';
    is $r->{policy_pct},    '100',                 'pct';
    is $r->{policy_adkim},  'r',                   'adkim';
    is $r->{date_begin},    1793059200,            'window start as epoch';
    is $r->{date_end},      1793145599,            'window end as epoch';

    is scalar @{ $p->{records} }, 1, 'one record';
    my $rec = $p->{records}[0];
    is $rec->{source_ip},     '23.116.91.65', 'source ip';
    is $rec->{message_count}, 3,              'count is numeric';
    is $rec->{disposition},   'none',         'disposition';
    is $rec->{dkim_result},   'pass',         'ALIGNMENT dkim (policy_evaluated)';
    is $rec->{spf_result},    'pass',         'ALIGNMENT spf (policy_evaluated)';
    is $rec->{header_from},   'mailmasker.org', 'header_from';
    is $rec->{auth_results}{dkim}[0]{selector}, '20261024a',
        'DKIM selector survives into auth_results -- it is what makes a failure actionable';
};

# The distinction the schema comment warns about, and the single most likely
# way to misread these reports: a signature that VERIFIES but does not ALIGN.
# auth_results/dkim = pass while policy_evaluated/dkim = fail.
subtest 'keeps alignment and raw authentication apart' => sub {
    my $xml = $REAL_XML;
    $xml =~ s{<policy_evaluated>\s*<disposition>none</disposition>\s*<dkim>pass</dkim>\s*<spf>pass</spf>\s*</policy_evaluated>}
             {<policy_evaluated><disposition>quarantine</disposition><dkim>fail</dkim><spf>fail</spf></policy_evaluated>}s;
    my $rec = parse_report($xml)->{records}[0];
    is $rec->{dkim_result}, 'fail',  'alignment failed';
    is $rec->{disposition}, 'quarantine', 'and the receiver acted on it';
    is $rec->{auth_results}{dkim}[0]{result}, 'pass',
        'while the raw signature still verified -- the two must not be conflated';
};

# --- packaging: how it actually arrives ------------------------------------
# Built as raw MIME text on purpose. Email::MIME->create (1.954) does not
# emit a Content-Disposition header for a single attachment and collapses a
# one-part message, so $part->filename came back undef and the fixture bore
# no resemblance to what receivers actually send -- which looked like a
# parser bug. Hand-rolling the envelope keeps the fixture honest.
sub _mail_with {
    my ($filename, $payload, $ct) = @_;
    require MIME::Base64;
    my $b64 = MIME::Base64::encode_base64($payload);
    return <<"MAIL";
From: reporter\@example.org
To: dmarc-reports\@example.org
Subject: Report domain: example.org
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUND42"

--BOUND42
Content-Type: text/plain; charset=UTF-8

This is an aggregate report for example.org.

--BOUND42
Content-Type: $ct; name="$filename"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="$filename"

$b64
--BOUND42--
MAIL
}

subtest 'extracts a zipped report (what Google actually sends)' => sub {
    my $zipped = '';
    IO::Compress::Zip::zip(\(my $copy = $REAL_XML) => \$zipped, Name => 'report.xml')
        or die "zip: $IO::Compress::Zip::ZipError";
    my @x = extract_reports(_mail_with('google.com!mailmasker.org!1!2.zip', $zipped, 'application/zip'));
    is scalar @x, 1, 'one report found';
    like $x[0], qr/<feedback/, 'and it decompressed to the feedback document';
    is parse_report($x[0])->{report}{org_name}, 'google.com', 'round-trips through parse';
};

subtest 'extracts a gzipped report' => sub {
    my $gz = '';
    IO::Compress::Gzip::gzip(\(my $copy = $REAL_XML) => \$gz) or die "gzip: $IO::Compress::Gzip::GzipError";
    my @x = extract_reports(_mail_with('r!example!1!2.xml.gz', $gz, 'application/gzip'));
    is scalar @x, 1, 'found via filename';
};

subtest 'believes the filename when the content type is vague' => sub {
    # Real receivers commonly send application/octet-stream for a .gz. If the
    # content type were trusted first, those reports would be silently
    # dropped and that domain would just look like it had no data.
    my $gz = '';
    IO::Compress::Gzip::gzip(\(my $copy = $REAL_XML) => \$gz) or die;
    my @x = extract_reports(_mail_with('r!example!1!2.xml.gz', $gz, 'application/octet-stream'));
    is scalar @x, 1, 'octet-stream .gz still extracted';
};

subtest 'ignores mail with nothing to parse' => sub {
    my $plain = "From: a\@b.c\nTo: d\@e.f\nSubject: routing probe\n"
              . "Content-Type: text/plain\n\nnot a report\n";
    is scalar(extract_reports($plain)), 0, 'a plain message yields no reports';

    my @x = extract_reports(_mail_with('notes.xml', '<other>hi</other>', 'text/xml'));
    is scalar @x, 0, 'XML that is not a <feedback> document is not treated as a report';
};

# --- refusing what it cannot store ----------------------------------------
subtest 'refuses documents it cannot identify' => sub {
    like do { eval { parse_report('<other/>') }; $@ }, qr/not a DMARC feedback/,
        'non-feedback root rejected';
    my $noid = $REAL_XML; $noid =~ s{<report_id>.*?</report_id>}{}s;
    like do { eval { parse_report($noid) }; $@ }, qr/no report_id/,
        'missing report_id rejected -- without it the insert cannot be idempotent';
};

# These documents arrive by email from third parties, so the parser must not
# fetch or expand external entities.
subtest 'does not expand external entities (XXE)' => sub {
    my $evil = <<'XML';
<?xml version="1.0"?>
<!DOCTYPE feedback [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
<feedback><report_metadata><org_name>&xxe;</org_name><report_id>1</report_id>
<date_range><begin>1</begin><end>2</end></date_range></report_metadata>
<policy_published><domain>x</domain></policy_published></feedback>
XML
    my $got = eval { parse_report($evil) };
    # Either refusing outright or parsing with the entity unexpanded is fine;
    # leaking file contents is not.
    my $org = $got ? ($got->{report}{org_name} // '') : '';
    unlike $org, qr/root:/, 'no /etc/passwd content reached the parsed output';
};

done_testing();
