use strict;
use warnings;
use Test::More;
use lib 'lib';

eval { require Email::MIME; require Email::Address::XS; 1 }
    or plan skip_all => 'Email::MIME / Email::Address::XS not installed';

use Homelab::Search::MailParse qw(parse_message parse_maildir_name);

# The maildir rename trap: reading a message changes its FILENAME but not
# its identity. If these two disagree, every mailbox re-indexes itself every
# time someone opens their mail.
my $unread = parse_maildir_name('1633010060.M349P855.host,S=25475,W=26090');
my $read   = parse_maildir_name('1633010060.M349P855.host,S=25475,W=26090:2,S');
is $unread->{uniq_part}, $read->{uniq_part}, 'flag change does not change uniq_part';
is $unread->{is_seen}, 0, 'new/ file is unseen';
is $read->{is_seen},   1, 'S flag parsed as seen';
is parse_maildir_name('x:2,FS')->{is_flagged}, 1, 'F flag parsed as flagged';

# A quoted display name containing a comma is ONE address. A regex split on
# commas produces two fictional people here.
my $raw = <<'MAIL';
From: "Forge, Constance" <constance@forge.example>
To: Bob <bob@example.org>, carol@example.org
Subject: Quarterly
Date: Tue, 13 Jan 2026 09:30:00 -0600
Message-ID: <abc123@forge.example>
Content-Type: text/plain; charset=utf-8

Numbers attached.
MAIL

my $p = parse_message($raw, { size => length $raw, mtime => 1 });
ok $p, 'parses';
is $p->{subject}, 'Quarterly', 'subject';
is scalar @{ $p->{addresses}{from} }, 1, 'one From address';
is $p->{addresses}{from}[0]{display_name}, 'Forge, Constance',
    'comma inside a quoted display name is kept, not split';
is $p->{addresses}{from}[0]{local_part}, 'constance', 'From local part';
is scalar @{ $p->{addresses}{to} }, 2, 'two To addresses';
is $p->{rfc822_msgid}, 'abc123@forge.example', 'Message-ID is unwrapped';
like $p->{body_text}, qr/Numbers attached/, 'body text extracted';
cmp_ok $p->{sent_at}, '>', 1_700_000_000, 'Date header parsed to an epoch';

# multipart/alternative must not index the same prose twice.
my $alt = <<'MAIL';
From: a@example.org
Subject: Alt
Content-Type: multipart/alternative; boundary=BB

--BB
Content-Type: text/plain

plain version
--BB
Content-Type: text/html

<html><body><p>html version</p></body></html>
--BB--
MAIL
my $pa = parse_message($alt, {});
like   $pa->{body_text}, qr/plain version/, 'plain part preferred';
unlike $pa->{body_text}, qr/html version/,  'html alternative not also indexed';

# Garbage must degrade, not die.
my $junk = parse_message("this is not a message at all\n", {});
ok defined $junk, 'unstructured input still returns something rather than dying';

done_testing();
