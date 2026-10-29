use v5.36;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Homelab::Common::ProfileSigner qw(sign_apple_profile signing_enabled);
use MIME::Base64 qw(encode_base64);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use File::Temp ();

# --- what counts as configured -----------------------------------------
#
# Every one of these shapes occurs for real. Blank is how the shipped
# example config says "feature off", and YAML turns a present-but-empty
# key into '' rather than undef -- which is the trap this guards.
ok !signing_enabled(undef), 'undef config is not enabled';
ok !signing_enabled({}), 'empty config is not enabled';
ok !signing_enabled({ url => '', lineage => '' }), 'blank values are not enabled';
ok !signing_enabled({ url => 'http://x:1', lineage => '' }), 'half-configured is not enabled';
ok !signing_enabled({ url => 'YOUR_SIGNER_URL', lineage => 'a.example' }),
    'an unedited placeholder is not enabled';
ok signing_enabled({ url => 'http://x:1', lineage => 'a.example' }), 'both present is enabled';

my %PROFILE = (
    email     => 'someone@example.org',
    imap_host => 'mail.example.org', imap_port => 993,
    smtp_host => 'smtp.example.org', smtp_port => 587,
);

is sign_apple_profile(signing => {}, profile => \%PROFILE), undef,
    'an unconfigured signer returns undef rather than dying';

# --- failures are undef, never exceptions ------------------------------
#
# Done BEFORE the happy path and with no server anywhere, because this is
# the behaviour the whole module exists to guarantee: a signer that
# cannot be reached must cost a red "Unverified" label, never a failed
# download. Mojo's ->result THROWS on a transport failure rather than
# returning an error, which is exactly how this would regress.
my $cred = File::Temp->new(TEMPLATE => 'cred-XXXXXX', SUFFIX => '.yml', TMPDIR => 1);
print {$cred} "token: test-agent-jwt\n";
close $cred;

my %base = (lineage => 'a.example', credential_file => $cred->filename);

is sign_apple_profile(
    signing => { %base, url => 'http://127.0.0.1:1', timeout_seconds => 2 },
    profile => \%PROFILE), undef, 'a refused connection becomes undef, not an exception';

Homelab::Common::ProfileSigner::_reset_cache();
is sign_apple_profile(
    signing => { %base, url => 'http://127.0.0.1:1', timeout_seconds => 2,
                 credential_file => '/nonexistent/credential.yml' },
    profile => \%PROFILE), undef, 'a missing agent credential becomes undef, not an exception';

# --- a real round trip over a real socket ------------------------------
#
# Worth the fork: what is most likely to drift here is not the logic but
# the wire contract -- the path, the bearer header, the base64 field
# name -- and a mocked transport would keep passing while it did. The
# server runs in a child process because Mojo::UserAgent drives its own
# event loop for blocking requests, so an in-process daemon on the
# singleton loop would never get a chance to answer.
my $dir     = File::Temp->newdir(TEMPLATE => 'signer-wire-XXXXXX', TMPDIR => 1);
my $portf   = path($dir->dirname, 'port');
my $seenf   = path($dir->dirname, 'seen');
my $FAKE_DER = chr(0x30) . ('signed-profile-bytes' x 20);

my $pid = fork;
die "cannot fork: $!" unless defined $pid;
unless ($pid) {
    # child: the fake signer
    require Mojolicious;
    require Mojo::Server::Daemon;
    my $app = Mojolicious->new;
    $app->log->level('fatal');
    $app->routes->post('/internal/v1/sign/apple-mail-profile' => sub ($c) {
        # Appended one JSON object per line, so the parent can both read
        # the last request and count how many there were.
        if (open(my $fh, '>>', $seenf->to_string)) {
            print {$fh} encode_json({
                auth => $c->req->headers->authorization // '',
                body => $c->req->json,
            }), "\n";
            close $fh;
        }
        return $c->render(json => { ok => \1, lineage => 'a.example',
            profile_b64 => encode_base64($FAKE_DER, '') });
    });
    # The client appends the path itself, so a refusing endpoint has to
    # live under its own base.
    $app->routes->post('/refuse/internal/v1/sign/apple-mail-profile' => sub ($c) {
        return $c->render(json => { error => 'lineage is not available for signing here' },
            status => 403);
    });
    my $d = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1'], silent => 1);
    $d->start;
    $portf->spew($d->ports->[0] . "\n");
    $d->run;
    exit 0;
}

END { kill 'TERM', $pid if $pid }

# Wait for the child to publish its port. Bounded: a hung child must
# fail the test, not hang the suite.
my $port;
for (1 .. 100) {
    if (-s $portf->to_string) { chomp($port = $portf->slurp); last }
    select undef, undef, undef, 0.05;
}

SKIP: {
    skip 'the fake signer did not start', 9 unless $port;

    Homelab::Common::ProfileSigner::_reset_cache();
    $seenf->spew('') if -e $seenf->to_string;

    my %signing = (%base, url => "http://127.0.0.1:$port");

    my $der = sign_apple_profile(signing => \%signing, profile => \%PROFILE);
    is $der, $FAKE_DER, 'the signed bytes come back decoded';

    my @seen = _seen();
    is scalar @seen, 1, 'one request was made';
    is $seen[0]{auth}, 'Bearer test-agent-jwt',
        'the agent credential is presented as a bearer token';
    is $seen[0]{body}{lineage}, 'a.example', 'the lineage is sent in the body';
    is $seen[0]{body}{email}, 'someone@example.org',
        'profile PARAMETERS are sent, not a pre-built document';
    ok !exists $seen[0]{body}{profile}, '  ... and no document is sent at all';

    # The cache keeps a page reload off the signer. In its negative form
    # it is load-bearing: it is what stops an unreachable signer adding
    # a connect timeout to every single profile download.
    my $again = sign_apple_profile(signing => \%signing, profile => \%PROFILE);
    is $again, $FAKE_DER, 'a repeat request returns the same bytes';
    is scalar _seen(), 1, '  ... without asking the signer again';

    # A different mailbox is a different document, so it must miss.
    sign_apple_profile(signing => \%signing,
        profile => { %PROFILE, email => 'other@example.org' });
    is scalar _seen(), 2, 'a different mailbox does reach the signer';

    Homelab::Common::ProfileSigner::_reset_cache();
    is sign_apple_profile(
        signing => { %signing, url => "http://127.0.0.1:$port/refuse" },
        profile => \%PROFILE), undef, 'a 403 refusal becomes undef, not an exception';
}

sub _seen {
    return () unless -s $seenf->to_string;
    return map { decode_json($_) } grep { length } split /\n/, $seenf->slurp;
}

done_testing;
