use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use MIME::Base64 qw(decode_base64);
use Homelab::Common::Mailer ();

# Covers the message ASSEMBLY only -- send_mail's SMTP conversation needs
# a real submission endpoint and is exercised for real by homelab-invite.
# The MIME shape is the part that fails silently: a wrong boundary or a
# missing blank line produces a message that is accepted by the server and
# renders as raw source in somebody's inbox.

sub build (%o) { return Homelab::Common::Mailer::_build_message(%o) }

subtest 'plain text messages are unchanged' => sub {
    # Every existing caller sends plain text. This asserts the html option
    # did not quietly alter their bytes.
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => 'Hi', body => "line one\nline two\n");
    like $m, qr/^From: a\@x\.org\r\n/,            'From';
    like $m, qr/\r\nTo: b\@y\.org\r\n/,           'To';
    like $m, qr/\r\nSubject: Hi\r\n/,             'Subject';
    like $m, qr/\r\nContent-Type: text\/plain; charset=UTF-8\r\n\r\nline one\nline two\n$/,
        'single text/plain part, body verbatim after the header break';
    unlike $m, qr/multipart/, 'not multipart';
    unlike $m, qr/Content-Transfer-Encoding/, 'no transfer encoding added';
};

subtest 'html makes it multipart/alternative' => sub {
    my $text = "Plain version\n";
    my $html = '<p>HTML &amp; version</p>';
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => 'Hi', body => $text, html => $html);

    my ($b) = $m =~ /Content-Type: multipart\/alternative; boundary="([^"]+)"/;
    ok $b, 'boundary declared in the content type';
    like $m, qr/\r\nMIME-Version: 1\.0\r\n/, 'MIME-Version present';

    my @parts = split /\r\n--\Q$b\E(?:--)?\r\n/, $m;
    shift @parts;    # preamble
    is scalar(grep { length } @parts), 2, 'exactly two parts';

    like $parts[0], qr{^Content-Type: text/plain; charset=UTF-8\r\n},  'first part is text/plain';
    like $parts[1], qr{^Content-Type: text/html; charset=UTF-8\r\n},   'second part is text/html';
    # Order matters: a client picks the LAST alternative it can render,
    # so html after plain is what makes the html one show.
    ok index($m, 'text/plain') < index($m, 'text/html'), 'plain comes before html';

    like $m, qr/\r\n--\Q$b\E--\r\n$/, 'closing boundary ends the message';

    for my $p (@parts) {
        like $p, qr/Content-Transfer-Encoding: base64\r\n\r\n/, 'part is base64 encoded';
    }
    my ($p_body) = $parts[0] =~ /\r\n\r\n(.*)/s;
    my ($h_body) = $parts[1] =~ /\r\n\r\n(.*)/s;
    is decode_base64($p_body), $text, 'text part decodes to the plain body';
    is decode_base64($h_body), $html, 'html part decodes to the html body';
};

subtest 'calendar makes an iTIP message: mixed > alternative (plain, text/calendar) + the .ics attached' => sub {
    # homelab-calendar's invitations (post-cutover #85): the shape Google's
    # own invitations have, which the mail programs' Yes/Maybe/No buttons
    # are tuned to.
    my $ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n";
    my $m = build(from => 'cal@x.org', to => 'b@y.org', subject => 'Invitation: Lunch', body => "Come to lunch\n",
        reply_to => 'owner@x.org', calendar => { method => 'REQUEST', ics => $ics });
    like $m, qr/\r\nReply-To: owner\@x\.org\r\n/, 'Reply-To names the organizer';
    my ($outer) = $m =~ /Content-Type: multipart\/mixed; boundary="([^"]+)"/;
    my ($inner) = $m =~ /Content-Type: multipart\/alternative; boundary="([^"]+)"/;
    ok $outer && $inner && $outer ne $inner, 'two boundaries, mixed outside, alternative inside';
    ok index($m, "--$outer\r\nContent-Type: multipart/alternative") > 0, 'the alternative is the first part of the mixed';
    like $m, qr{--\Q$inner\E\r\nContent-Type: text/plain; charset=UTF-8\r\n}, 'the plain text is the first alternative';
    like $m, qr{--\Q$inner\E\r\nContent-Type: text/calendar; charset=UTF-8; method=REQUEST\r\n}, 'text/calendar with the method is the last alternative';
    like $m, qr{--\Q$outer\E\r\nContent-Type: application/ics; name="invite\.ics"\r\nContent-Disposition: attachment; filename="invite\.ics"\r\n}, 'the .ics is attached too';
    like $m, qr/\r\n--\Q$inner\E--\r\n--\Q$outer\E\r\n/, 'the alternative closes before the attachment';
    like $m, qr/\r\n--\Q$outer\E--\r\n$/, 'the mixed closes the message';
    my @ics_parts = $m =~ /Content-Transfer-Encoding: base64\r\n\r\n((?:[A-Za-z0-9+\/=]+\r\n)+)/g;
    is scalar(grep { decode_base64($_) eq $ics } @ics_parts), 2, 'the calendar text appears twice, byte for byte';
    is scalar(() = $m =~ /BEGIN:VCALENDAR/g), 0, '... and never in the clear';

    my $c = build(from => 'cal@x.org', to => 'b@y.org', subject => 'Cancelled', body => "Off\n", calendar => { method => 'CANCEL', ics => $ics });
    like $c, qr{text/calendar; charset=UTF-8; method=CANCEL}, 'a CANCEL carries its method';
    my $bad = build(from => 'cal@x.org', to => 'b@y.org', subject => 'x', body => "x\n", calendar => { method => 'DROP TABLE', ics => $ics });
    like $bad, qr{method=REQUEST}, 'an unknown method falls back to REQUEST';
    my $none = build(from => 'cal@x.org', to => 'b@y.org', subject => 'x', body => "plain\n", calendar => { method => 'REQUEST', ics => '' });
    unlike $none, qr/multipart/, 'an empty ics is no calendar at all: plain text as before';
};

subtest 'a subject with non-ASCII is an encoded word' => sub {
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => "Caf\x{e9} \x{2014} r\x{e9}union", body => "x\n");
    like $m, qr/\r\nSubject: =\?UTF-8\?B\?[A-Za-z0-9+\/=]+\?=\r\n/, 'RFC 2047, base64, UTF-8';
    my ($b64) = $m =~ /Subject: =\?UTF-8\?B\?([A-Za-z0-9+\/=]+)\?=/;
    is Encode::decode('UTF-8', decode_base64($b64)), "Caf\x{e9} \x{2014} r\x{e9}union", '... decoding gives the subject back';
    my $plain = build(from => 'a@x.org', to => 'b@y.org', subject => "Plain subject", body => "x\n");
    like $plain, qr/\r\nSubject: Plain subject\r\n/, 'an ASCII subject is left exactly as it was';
};

subtest 'base64 keeps lines inside the SMTP limit' => sub {
    # SMTP caps a line at 998 octets. HTML written as a here-doc routinely
    # has longer lines than that; base64 is what makes it safe.
    my $long = '<p>' . ('x' x 5000) . '</p>';
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => 'Long', body => 'x', html => $long);
    my $worst = 0;
    for my $line (split /\r\n/, $m) { $worst = length $line if length $line > $worst }
    cmp_ok $worst, '<', 998, "longest line is $worst octets";
};

subtest 'utf-8 survives the round trip' => sub {
    my $text = "caf\x{e9} \x{2014} na\x{ef}ve\n";
    my $html = "<p>caf\x{e9} \x{2014} na\x{ef}ve</p>";
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => 'UTF', body => $text, html => $html);
    my ($b) = $m =~ /boundary="([^"]+)"/;
    my @parts = grep { length } split /\r\n--\Q$b\E(?:--)?\r\n/, $m;
    shift @parts;
    my ($h_body) = $parts[1] =~ /\r\n\r\n(.*)/s;
    my $decoded = decode_base64($h_body);
    # Encoded as UTF-8 octets, which is what the charset parameter claims.
    is $decoded, Encode::encode('UTF-8', $html), 'html part is UTF-8 octets, matching its charset';
};

subtest 'a boundary cannot collide with the content' => sub {
    my $m = build(from => 'a@x.org', to => 'b@y.org', subject => 'x', body => 'b', html => '<p>h</p>');
    my ($b) = $m =~ /boundary="([^"]+)"/;
    like $b, qr/^=_homelab_[0-9a-f]{40}_=$/, 'boundary carries 40 hex digits of entropy';
    # Both parts are base64, whose alphabet excludes '=' except as
    # padding -- so a delimiter containing '=' inside it cannot occur in
    # the encoded bodies even if a user pasted it in.
    is scalar(() = $m =~ /\Q$b\E/g), 4,
        'boundary appears exactly four times: declaration, two part delimiters, closing delimiter';
};

done_testing();
