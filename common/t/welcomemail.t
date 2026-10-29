use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Homelab::Common::MailSetup qw(mail_settings);
use Homelab::Common::WelcomeMail qw(ready_email welcome_email);

my $EMAIL    = 'johnboy002@mailmasker.org';
my $SETUP    = 'https://invite.mailmasker.org/setup/mail?t=v1.abc.123.def';
my $settings = mail_settings(email => $EMAIL);

subtest 'both messages carry a real plain-text alternative' => sub {
    # Not a formality. A "please view this in HTML" stub is what a
    # text-only client, a screen reader and a spam scorer all see, and
    # it is a cheap way to land in a junk folder -- which for a message
    # whose entire job is to arrive is the only failure that matters.
    for my $m ([ready_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP)],
               [welcome_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP)]) {
        my ($subject, $text, $html) = @{ $m->[0] ? $m : $m };
        ok length($subject),      'has a subject';
        cmp_ok length($text), '>', 300, 'plain part is a real message, not a stub';
        unlike $text, qr/view this (?:email )?in/i, 'plain part does not tell you to read the HTML';
        like $text, qr/\Q$EMAIL\E/,  'plain part names the account';
        like $html, qr/\Q$EMAIL\E/,  'html part names the account';
    }
};

subtest 'the setup link reaches every surface' => sub {
    my (undef, $rt, $rh) = ready_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP);
    like $rt, qr/\Q$SETUP\E/, 'ready mail, plain';
    like $rh, qr/\Q$SETUP\E/, 'ready mail, html';
    my (undef, $wt, $wh) = welcome_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP);
    like $wt, qr/\Q$SETUP\E/, 'welcome mail, plain';
    like $wh, qr/\Q$SETUP\E/, 'welcome mail, html';
};

subtest 'no setup link means no broken offer' => sub {
    # setup_url is undef on an install with no signing secret. The mails
    # must still be complete and must not advertise a button that is not
    # there.
    my ($s, $t, $h) = ready_email(account_email => $EMAIL, settings => $settings, setup_url => undef);
    ok length($t) > 200, 'still a complete message';
    unlike $t, qr/Set up my device/, 'no dangling call to action in the plain part';
    unlike $h, qr/Set up my device/, 'no dangling call to action in the html part';
    like $t, qr/\Q$EMAIL\E/, 'still names the login';
    # The manual settings are the fallback path in that case, so they
    # must survive.
    like $t, qr/mail\.mailmasker\.org/, 'manual IMAP host still present';
};

subtest 'manual settings appear in full, in both parts' => sub {
    for my $m ([ready_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP)],
               [welcome_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP)]) {
        my (undef, $text, $html) = @{ $m->[0] ? $m : $m };
        for my $want ('mail.mailmasker.org', 'smtp.mailmasker.org', '993', '587') {
            like $text, qr/\Q$want\E/, "plain part has $want";
            like $html, qr/\Q$want\E/, "html part has $want";
        }
        like $text, qr/IMAP, not POP/, 'plain part says IMAP not POP';
        like $html, qr/IMAP, not POP/, 'html part says IMAP not POP';
    }
};

subtest 'no password is ever printed' => sub {
    my $s2 = mail_settings(email => $EMAIL);
    for my $m ([ready_email(account_email => $EMAIL, settings => $s2, setup_url => $SETUP)],
               [welcome_email(account_email => $EMAIL, settings => $s2, setup_url => $SETUP)]) {
        my (undef, $text, $html) = @{ $m->[0] ? $m : $m };
        like $text, qr/\(your mailbox password\)/, 'the password row is a prompt';
        unlike $text, qr/password[:=]\s*\S{8,}/i, 'nothing that looks like a literal password';
        unlike $html, qr/password[:=]\s*\S{8,}/i, 'nothing that looks like a literal password';
    }
};

subtest 'html is escaped' => sub {
    my $evil = 'a<script>alert(1)</script>@mailmasker.org';
    my $s3 = mail_settings(email => $evil, config => { service_label => 'A & B' });
    my (undef, undef, $html) = welcome_email(account_email => $evil, settings => $s3, setup_url => $SETUP);
    unlike $html, qr/<script>/, 'the address cannot inject markup';
    like   $html, qr/&amp;/,    'ampersand in the label is escaped';
};

subtest 'the welcome mail is addressed at the mailbox it lands in' => sub {
    my ($subject, $text) = welcome_email(account_email => $EMAIL, settings => $settings, setup_url => $SETUP);
    like $subject, qr/^Welcome to /, 'subject reads as a welcome, not a notification';
    like $text, qr/first message in it/, 'says what it is -- a new mailbox is otherwise indistinguishable from a broken one';
    like $text, qr/Keep this message/, 'tells them why to keep it (the next device)';
};

done_testing();
