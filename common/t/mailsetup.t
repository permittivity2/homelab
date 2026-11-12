use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Homelab::Common::MailSetup qw(mail_settings manual_setup_rows);
use Homelab::Common::AppleProfile qw(build_mail_profile);

subtest 'defaults derive from the mailbox domain' => sub {
    my $s = mail_settings(email => 'a@mailmasker.org');
    is $s->{imap_host}, 'mail.mailmasker.org', 'IMAP host';
    is $s->{smtp_host}, 'smtp.mailmasker.org', 'SMTP host';
    is $s->{imap_port}, 993, 'IMAPS';
    is $s->{smtp_port}, 587, 'submission';
    is $s->{username},  'a@mailmasker.org', 'login is the full address';
    is $s->{service_label}, 'MailMasker', 'default label';
};

subtest 'a blank config key means derive, not empty' => sub {
    # YAML renders `imap_host:` with no value as '', not undef. Treating
    # that as a real setting would send clients to an empty hostname --
    # and the shipped example config leaves exactly these keys blank.
    my $s = mail_settings(email => 'a@example.org', config => {
        imap_host => '', smtp_host => '', imap_port => '', smtp_port => '',
        service_label => '', organization => '',
    });
    is $s->{imap_host}, 'mail.example.org', 'blank imap_host derives';
    is $s->{smtp_host}, 'smtp.example.org', 'blank smtp_host derives';
    is $s->{imap_port}, 993, 'blank port falls back to the default';
    is $s->{smtp_port}, 587, 'blank port falls back to the default';
    ok length $s->{service_label}, 'blank label falls back';
    ok length $s->{organization},  'blank organization falls back';
};

subtest 'overrides are honoured' => sub {
    my $s = mail_settings(email => 'a@example.org', config => {
        imap_host => 'imap.elsewhere.net', imap_port => 143,
        smtp_host => 'smtp.elsewhere.net', smtp_port => 465,
        service_label => 'Elsewhere', organization => 'Elsewhere Ltd',
        webmail_url => 'https://w/', myaccount_url => 'https://m/',
    });
    is $s->{imap_host}, 'imap.elsewhere.net', 'imap_host';
    is $s->{imap_port}, 143, 'imap_port';
    is $s->{smtp_port}, 465, 'smtp_port';
    is $s->{service_label}, 'Elsewhere', 'label';
    is $s->{webmail_url}, 'https://w/', 'webmail_url';
};

subtest 'the manual table and the Apple profile cannot disagree' => sub {
    # This is the whole reason the settings are resolved in one place.
    # A user following the table by hand and a user tapping the profile
    # must end up on the same host and port, or one of them has a mail
    # app that silently will not connect.
    my $cfg  = { imap_host => 'imap.example.org', imap_port => 143,
                 smtp_host => 'mx.example.org',   smtp_port => 2525 };
    my $s    = mail_settings(email => 'u@example.org', config => $cfg);
    my $xml  = build_mail_profile(email => $s->{email}, %{$s}{qw(imap_host imap_port smtp_host smtp_port)});
    my $rows = manual_setup_rows($s);
    my %row  = map { $_->[0] => $_->[1] } @$rows;

    like $xml, qr{<key>IncomingMailServerHostName</key>\s*<string>\Q$row{'Incoming (IMAP) server'}\E</string>},
        'IMAP host matches the table';
    like $xml, qr{<key>IncomingMailServerPortNumber</key>\s*<integer>\Q$row{'Incoming port'}\E</integer>},
        'IMAP port matches the table';
    like $xml, qr{<key>OutgoingMailServerHostName</key>\s*<string>\Q$row{'Outgoing (SMTP) server'}\E</string>},
        'SMTP host matches the table';
    like $xml, qr{<key>OutgoingMailServerPortNumber</key>\s*<integer>\Q$row{'Outgoing port'}\E</integer>},
        'SMTP port matches the table';
};

subtest 'the table spells out the encryption, not just the port' => sub {
    my $rows = manual_setup_rows(mail_settings(email => 'a@mailmasker.org'));
    my %note = map { $_->[0] => $_->[2] } @$rows;
    is $note{'Incoming port'}, 'SSL/TLS',  '993 is implicit TLS';
    is $note{'Outgoing port'}, 'STARTTLS', '587 is STARTTLS';

    my $alt = manual_setup_rows(mail_settings(email => 'a@x.org',
        config => { imap_port => 143, smtp_port => 465 }));
    my %n2 = map { $_->[0] => $_->[2] } @$alt;
    is $n2{'Incoming port'}, 'STARTTLS', '143 is STARTTLS';
    is $n2{'Outgoing port'}, 'SSL/TLS',  '465 is implicit TLS';
};

subtest 'the other outgoing port is offered as an alternative (#70)' => sub {
    # The pool serves 587 (STARTTLS) and 465 (implicit TLS) alike; a client
    # set to the wrong mechanism for its port fails with an unhelpful error,
    # so the table names the other port with its own encryption word.
    my $rows = manual_setup_rows(mail_settings(email => 'a@mailmasker.org'));
    my %row  = map { $_->[0] => $_->[1] } @$rows;
    my %note = map { $_->[0] => $_->[2] } @$rows;
    is $row{'Outgoing port'}, 587, 'primary stays 587';
    is $row{'Outgoing port, alternative'}, 465, '465 is the alternative to 587';
    # No em dash in these patterns: MailSetup.pm is utf8 source (Mojo::Base),
    # this test file is not, so the literal would be bytes against characters.
    like $note{'Outgoing port, alternative'}, qr/^SSL\/TLS\b/, 'labelled implicit TLS';
    like $note{'Outgoing port, alternative'}, qr/both ports work/, 'says both work';
    like $note{'Outgoing port, alternative'}, qr/no STARTTLS option/, 'says when to pick it';
    my @order = map { $_->[0] } @$rows;
    my ($p) = grep { $order[$_] eq 'Outgoing port' } 0 .. $#order;
    is $order[$p + 1], 'Outgoing port, alternative', 'the alternative row follows the primary';

    my $r465 = manual_setup_rows(mail_settings(email => 'a@x.org', config => { smtp_port => 465 }));
    my %r2   = map { $_->[0] => $_->[1] } @$r465;
    my %n2   = map { $_->[0] => $_->[2] } @$r465;
    is $r2{'Outgoing port, alternative'}, 587, 'a site on 465 offers 587';
    like $n2{'Outgoing port, alternative'}, qr/^STARTTLS\b/, 'labelled STARTTLS';
    like $n2{'Outgoing port, alternative'}, qr/no SSL\/TLS option/, 'says when to pick it';

    my $odd = manual_setup_rows(mail_settings(email => 'a@x.org', config => { smtp_port => 2525 }));
    ok !(grep { $_->[0] eq 'Outgoing port, alternative' } @$odd), 'an unusual port gets no alternative row';
};

subtest 'no password is ever placed in the table' => sub {
    my $rows = manual_setup_rows(mail_settings(email => 'a@mailmasker.org'));
    my %row  = map { $_->[0] => $_->[1] } @$rows;
    is $row{'Password'}, '(your mailbox password)', 'the password row is a prompt, not a value';
};

subtest 'bad input' => sub {
    ok !eval { mail_settings(); 1 }, 'email required';
    ok !eval { mail_settings(email => 'nope'); 1 }, 'address must have an @';
};

done_testing();
