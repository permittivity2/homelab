use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Homelab::Common::AppleProfile qw(build_mail_profile profile_filename);

# The profile is XML this fleet hands to a stranger's iPhone. Nothing here
# can be checked by looking at it -- a wrong port, a false TLS flag or a
# duplicated identifier all produce a file that LOOKS fine and fails (or
# worse, silently works insecurely) on the device. So: parse it, and
# assert on the parsed structure rather than on the string.

my $EMAIL = 'johnboy002@mailmasker.org';

# --- a tiny plist reader -------------------------------------------------
# Deliberately not XML::LibXML: this test must run anywhere the module
# does, and the subset of plist the generator emits (flat dict of
# string/integer/true/false, plus one array of dicts) is small enough to
# read with a regex scanner. If the generator ever emits something this
# cannot parse, that is itself worth a failure.
sub unesc ($s) {
    $s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g; $s =~ s/&amp;/&/g;   # ampersand LAST, or &amp;lt; double-decodes
    return $s;
}

sub parse_plist ($xml) {
    my @tok;
    while ($xml =~ m{<(key|string|integer)>(.*?)</\1>|<(true|false)\s*/>|<(dict|array)>|</(dict|array)>}gs) {
        if (defined $1)    { push @tok, [$1, unesc($2)] }
        elsif (defined $3) { push @tok, ['bool', $3 eq 'true' ? 1 : 0] }
        elsif (defined $4) { push @tok, ["open_$4"] }
        else               { push @tok, ["close_$5"] }
    }
    my $i = 0;
    my $parse_value;
    my $parse_dict = sub {
        my %h;
        while ($i < @tok) {
            my $t = $tok[$i];
            return \%h if $t->[0] eq 'close_dict';
            die "expected key, got $t->[0]\n" unless $t->[0] eq 'key';
            my $k = $t->[1];
            $i++;
            $h{$k} = $parse_value->();
        }
        return \%h;
    };
    $parse_value = sub {
        my $t = $tok[$i] or die "truncated\n";
        if ($t->[0] eq 'open_dict')  { $i++; my $d = $parse_dict->(); $i++; return $d }
        if ($t->[0] eq 'open_array') {
            $i++;
            my @a;
            while ($tok[$i] && $tok[$i][0] ne 'close_array') { push @a, $parse_value->() }
            $i++;
            return \@a;
        }
        $i++;
        return $t->[1];
    };
    # Skip to the root <dict>.
    $i++ while $tok[$i] && $tok[$i][0] ne 'open_dict';
    $i++;
    return $parse_dict->();
}

my $xml  = build_mail_profile(email => $EMAIL);
my $root = parse_plist($xml);

subtest 'the file is a well-formed configuration profile' => sub {
    like $xml, qr/^<\?xml version="1\.0" encoding="UTF-8"\?>/, 'XML declaration first';
    like $xml, qr/-\/\/Apple\/\/DTD PLIST 1\.0\/\/EN/,         'Apple plist DOCTYPE';
    is $root->{PayloadType},    'Configuration', 'root is a Configuration payload';
    is $root->{PayloadVersion}, '1',             'PayloadVersion 1';
    ok  ref $root->{PayloadContent} eq 'ARRAY',  'PayloadContent is an array';
    is  scalar @{ $root->{PayloadContent} }, 1,  'exactly one payload inside';
};

subtest 'the mail account is what the fleet actually serves' => sub {
    my $a = $root->{PayloadContent}[0];
    is $a->{PayloadType},       'com.apple.mail.managed', 'mail payload type';
    is $a->{EmailAccountType},  'EmailTypeIMAP',          'IMAP, not POP';
    is $a->{EmailAddress},      $EMAIL,                   'address';
    is $a->{IncomingMailServerUsername}, $EMAIL,          'IMAP login is the full address';
    is $a->{OutgoingMailServerUsername}, $EMAIL,          'SMTP login is the full address';

    # Defaults derived from the address domain. These match the SANs on
    # the live certificate (mail.mailmasker.org, smtp.mailmasker.org) --
    # a hostname not on the cert gives a TLS name mismatch on the phone.
    is $a->{IncomingMailServerHostName},   'mail.mailmasker.org', 'IMAP host';
    is $a->{IncomingMailServerPortNumber}, '993',                 'IMAPS port';
    is $a->{OutgoingMailServerHostName},   'smtp.mailmasker.org', 'SMTP host';
    is $a->{OutgoingMailServerPortNumber}, '587',                 'submission port';
};

subtest 'TLS is on for both directions' => sub {
    my $a = $root->{PayloadContent}[0];
    # The single most consequential pair of booleans in the file. iOS
    # infers implicit-TLS-vs-STARTTLS from the port, so false here on 587
    # does not mean STARTTLS -- it means plaintext submission of the
    # user's password.
    is $a->{IncomingMailServerUseSSL}, 1, 'IMAP uses TLS';
    is $a->{OutgoingMailServerUseSSL}, 1, 'SMTP uses TLS';
    is $a->{IncomingMailServerAuthentication}, 'EmailAuthPassword', 'IMAP password auth';
    is $a->{OutgoingMailServerAuthentication}, 'EmailAuthPassword', 'SMTP password auth';
};

subtest 'no credential is ever written into the profile' => sub {
    # The whole security argument for serving this file from a URL rests
    # on this. If a future change starts embedding a password, this test
    # is the thing that has to be deliberately deleted to do it.
    my $a = $root->{PayloadContent}[0];
    ok !exists $a->{IncomingPassword}, 'no IncomingPassword key';
    ok !exists $a->{OutgoingPassword}, 'no OutgoingPassword key';
    unlike $xml, qr/<key>\w*Password<\/key>\s*<string>/,
        'no *Password key with a string value anywhere in the file';
    is $a->{OutgoingPasswordSameAsIncomingPassword}, 1,
        'one password prompt at install, not two';
};

subtest 'identifiers are stable, so reinstalling replaces rather than duplicates' => sub {
    # iOS keys a profile on PayloadIdentifier and each payload on
    # PayloadUUID. Random values would mean a user who taps "Add to
    # iPhone" twice gets two copies of the same mailbox.
    my $again = parse_plist(build_mail_profile(email => $EMAIL));
    is $again->{PayloadIdentifier}, $root->{PayloadIdentifier}, 'root identifier stable';
    is $again->{PayloadUUID},       $root->{PayloadUUID},       'root UUID stable';
    is $again->{PayloadContent}[0]{PayloadUUID},
       $root->{PayloadContent}[0]{PayloadUUID},                 'payload UUID stable';

    my $other = parse_plist(build_mail_profile(email => 'someoneelse@mailmasker.org'));
    isnt $other->{PayloadUUID}, $root->{PayloadUUID}, 'a different account gets a different UUID';
    isnt $other->{PayloadIdentifier}, $root->{PayloadIdentifier}, '...and a different identifier';

    like $root->{PayloadUUID}, qr/^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/,
        'UUID is syntactically a v5 UUID';
    unlike $root->{PayloadIdentifier}, qr/[\@+]/, 'identifier is reverse-DNS-shaped, no @ or +';
};

subtest 'the user can remove it' => sub {
    is $root->{PayloadRemovalDisallowed}, 0,
        'profile is user-removable -- this is consumer mail, not a managed device';
};

subtest 'overrides and XML escaping' => sub {
    my $p = parse_plist(build_mail_profile(
        email => 'x@example.net', imap_host => 'imap.example.net', imap_port => 143,
        smtp_host => 'mx.example.net', smtp_port => 2525,
        account_label => 'Example', organization => 'Example & Co <Ltd>',
        display_name => 'A "quoted" name',
    ));
    my $a = $p->{PayloadContent}[0];
    is $a->{IncomingMailServerHostName},   'imap.example.net', 'imap_host override';
    is $a->{IncomingMailServerPortNumber}, '143',              'imap_port override';
    is $a->{OutgoingMailServerHostName},   'mx.example.net',   'smtp_host override';
    is $a->{OutgoingMailServerPortNumber}, '2525',             'smtp_port override';
    is $a->{EmailAccountDescription},      'Example',          'account_label override';
    # Round-tripping through the parser proves the escaping, not just that
    # an entity appeared somewhere.
    is $p->{PayloadOrganization}, 'Example & Co <Ltd>', 'ampersand and angle brackets survive';
    is $a->{EmailAccountName},    'A "quoted" name',    'double quotes survive';
};

subtest 'bad input is refused, not silently shipped' => sub {
    ok !eval { build_mail_profile(); 1 },                        'email is required';
    ok !eval { build_mail_profile(email => 'not-an-address'); 1 },'address must have an @';
};

subtest 'download filename' => sub {
    is profile_filename($EMAIL), 'mailmasker-johnboy002-mailmasker.org.mobileconfig',
        'filename is derived from the address';
    unlike profile_filename('a+b@c.org'), qr{[/\\\@+]},
        'no path separators or address punctuation in the filename';
};

done_testing();
