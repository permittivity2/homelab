package Homelab::Search::MailParse;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

use Email::MIME;
use Email::Address::XS;
use HTTP::Date qw(str2time);
use Encode qw(decode FB_DEFAULT);

our @EXPORT_OK = qw(parse_message parse_maildir_name HEADER_ALLOWLIST);

# Parses one maildir file into the shape search.messages and friends want.
#
# EVERYTHING IN HERE IS HOSTILE INPUT. Anyone on the internet can email
# these users, so every field below arrives from a stranger: a subject can
# be megabytes, a charset can be a lie, a Content-Type can be malformed, a
# multipart can nest until it exhausts memory. So: every decode is wrapped,
# every length is capped, and a part that will not parse degrades the
# message to metadata-only rather than aborting the mailbox.
#
# Why Email::MIME and Email::Address::XS rather than regexes: an address
# list is not comma-separated in any useful sense -- a quoted display name
# may contain commas, and a group syntax may contain nested lists. A regex
# gets "Forge, Constance" <c@x> wrong by splitting it into two addresses,
# which would then be interned as two fictional people. Transfer encodings
# and charsets have the same shape of problem.

# Only these headers get stored (see migrations/001-search.sql). Everything
# else either has a column of its own or is never queried.
use constant HEADER_ALLOWLIST => [qw(
    list-id return-path authentication-results x-mailer user-agent
    auto-submitted x-spam-status content-type
)];

my $MAX_SUBJECT   = 2000;         # a subject longer than this is a weapon, not a subject
my $MAX_BODY      = 2 * 1024 * 1024;
my $MAX_ADDRS     = 200;          # per role; a 10k-recipient Cc is not worth interning
my $MAX_PARTS     = 500;
my $MAX_NAME      = 320;

sub _clip ($s, $n) {
    return undef unless defined $s;
    $s =~ s/\0//g;                # NULs break Postgres text
    return length($s) > $n ? substr($s, 0, $n) : $s;
}

# Collapse the whitespace a folded header leaves behind, so a subject does
# not arrive with embedded newlines and tabs.
# Default argument, and every caller forces scalar context: Email::MIME's
# header_raw() returns an empty LIST for a missing header, so passing it
# straight into a signatured sub is an arity error rather than an undef.
sub _unfold ($s = undef) {
    return undef unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# '1633010060.M349379P855863.host,S=25475,W=26090:2,S' ->
#   uniq_part => '1633010060.M349379P855863.host,S=25475,W=26090'
#   flags     => 'S'
#
# The split is on the LAST ':' and the stable identity is what precedes it.
# This is the whole reason re-reading a mailbox after someone opens their
# mail does not re-index it: dovecot renames the file when flags change,
# and only the part after the ':' moves.
sub parse_maildir_name ($name) {
    my ($uniq, $flags) = $name =~ /\A(.*?):(?:2,)?([A-Za-z]*)\z/;
    $uniq  = $name unless defined $uniq;   # new/ files have no ':' yet
    $flags = ''    unless defined $flags;
    return {
        uniq_part  => $uniq,
        flags      => $flags,
        is_seen    => (index($flags, 'S') >= 0 ? 1 : 0),
        is_flagged => (index($flags, 'F') >= 0 ? 1 : 0),
        is_draft   => (index($flags, 'D') >= 0 ? 1 : 0),
    };
}

# Email::MIME->body_str dies on a charset it does not know, which is common
# in real mail. Fall back to the raw octets decoded as UTF-8 with
# replacement characters -- a slightly mangled body still indexes usefully,
# whereas dying loses the whole message.
sub _part_text ($part) {
    my $text = eval { $part->body_str };
    return $text if defined $text && !$@;
    my $raw = eval { $part->body };
    return '' unless defined $raw;
    return decode('UTF-8', $raw, FB_DEFAULT);
}

sub _html_to_text ($html) {
    my $text = eval {
        require HTML::TreeBuilder;
        require HTML::FormatText;
        my $tree = HTML::TreeBuilder->new;
        $tree->parse($html);
        $tree->eof;
        my $out = HTML::FormatText->new(leftmargin => 0, rightmargin => 10_000)->format($tree);
        $tree->delete;
        $out;
    };
    return $text if defined $text && !$@;
    # Last resort: strip tags. Worse output, but never nothing.
    $html =~ s/<[^>]*>/ /g;
    return $html;
}

# Walks the MIME tree once, collecting the best body text and the
# attachment list. text/plain is preferred; text/html is converted only if
# no plain part was found, which is what keeps a typical multipart/alternative
# from indexing the same prose twice.
sub _walk ($top) {
    my (@plain, @html, @attach);
    my $parts = 0;

    my $visit;
    $visit = sub ($part) {
        return if ++$parts > $MAX_PARTS;
        my @sub = eval { $part->subparts };
        if (@sub) { $visit->($_) for @sub; return }

        my $ct       = lc($part->content_type // 'text/plain');
        my ($mime)   = $ct =~ m{\A\s*([^;\s]+)};
        $mime      //= 'text/plain';
        my $filename = eval { $part->filename } // undef;
        my $disp     = lc($part->header('Content-Disposition') // '');

        if (defined $filename && length $filename) {
            push @attach, {
                file_name  => _clip($filename, $MAX_NAME),
                mime_type  => $mime,
                size_bytes => length($part->body // ''),
            };
            return;
        }
        return if $disp =~ /attachment/;

        if    ($mime eq 'text/plain') { push @plain, _part_text($part) }
        elsif ($mime eq 'text/html')  { push @html,  _part_text($part) }
    };
    eval { $visit->($top) };

    my $body = @plain ? join("\n", @plain)
             : @html  ? _html_to_text(join("\n", @html))
             :          '';
    return ($body, \@attach);
}

sub _addresses ($email, $header) {
    my $raw = scalar $email->header_raw($header);
    return [] unless defined $raw && length $raw;
    # The FUNCTION, not the method. parse_email_addresses's method form takes
    # ($string, $class), so Email::Address::XS->parse_email_addresses($raw)
    # silently parses the class name as the address list and blesses the
    # result into a class named after $raw. It still "succeeds" -- 500/500
    # messages parsed with every address field empty -- so this is only
    # visible as a warning unless the extracted addresses are actually
    # checked.
    my @parsed = eval { Email::Address::XS::parse_email_addresses($raw) };
    return [] if $@;
    my @out;
    for my $a (@parsed) {
        last if @out >= $MAX_ADDRS;
        my $addr = $a->address;
        next unless defined $addr && $addr =~ /\A[^@\s]+\@[^@\s]+\z/;
        my ($lp, $dom) = $addr =~ /\A(.+)\@([^@]+)\z/;
        next unless defined $lp && defined $dom;
        my $name = $a->phrase;
        $name = _unfold($name);
        undef $name if defined $name && !length $name;
        push @out, {
            local_part   => _clip(lc $lp,  $MAX_NAME),
            domain       => _clip(lc $dom, $MAX_NAME),
            display_name => _clip($name,   $MAX_NAME),
        };
    }
    return \@out;
}

# $raw is the file's bytes; $stat is a hashref with size/mtime for the
# fallbacks. Returns undef only if the message cannot be parsed at all, in
# which case the caller should record it metadata-only.
sub parse_message ($raw, $stat = {}) {
    my $email = eval { Email::MIME->new($raw) };
    return undef unless $email;

    my ($body, $attach) = _walk($email);
    $body = _clip($body, $MAX_BODY);

    my $date = scalar $email->header_raw('Date');
    my $sent = defined $date ? eval { str2time($date) } : undef;
    my $recv;
    if (my $r = scalar $email->header_raw('Received')) {
        # First Received: is the most recent hop; its date is after the
        # final ';'.
        my ($tail) = $r =~ /;\s*([^;]+)\z/;
        $recv = eval { str2time($tail) } if defined $tail;
    }

    # header_raw_pairs returns a flat (name, value, name, value, ...) list;
    # walk it once rather than calling header() per allowlisted name, which
    # would re-scan the header block each time.
    my %headers;
    my %want  = map { $_ => 1 } @{ HEADER_ALLOWLIST() };
    my @pairs = eval { $email->header_raw_pairs };
    for (my $i = 0; $i + 1 <= $#pairs; $i += 2) {
        my $name = lc($pairs[$i] // '');
        next unless $want{$name};
        push @{ $headers{$name} }, _clip(_unfold($pairs[$i + 1]), 4000);
    }

    my $msgid = _unfold(scalar $email->header_raw('Message-ID'));
    $msgid =~ s/\A<|>\z//g if defined $msgid;
    my $irt = _unfold(scalar $email->header_raw('In-Reply-To'));
    $irt =~ s/\A<|>\z//g if defined $irt;

    return {
        subject         => _clip(_unfold(scalar $email->header_raw('Subject')), $MAX_SUBJECT),
        rfc822_msgid    => _clip($msgid, $MAX_NAME),
        in_reply_to     => _clip($irt,   $MAX_NAME),
        sent_at         => $sent,
        received_at     => $recv // $stat->{mtime},
        size_bytes      => $stat->{size} // length($raw),
        body_text       => $body,
        attachments     => $attach,
        has_attachments => (@$attach ? 1 : 0),
        headers         => \%headers,
        addresses       => {
            from     => _addresses($email, 'From'),
            sender   => _addresses($email, 'Sender'),
            reply_to => _addresses($email, 'Reply-To'),
            to       => _addresses($email, 'To'),
            cc       => _addresses($email, 'Cc'),
            bcc      => _addresses($email, 'Bcc'),
        },
    };
}

1;
