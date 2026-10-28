use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);

# Guards t/lib/TestAccounts.pm, the shared clean-up for the real accounts
# the integration suites create. Worth its own test because its whole job
# happens in an END block, where a silent failure is invisible -- which is
# exactly how 25 live accounts (5 of them site_admin, with the passwords
# written in the test files) ended up sitting in production, found
# 2026-10-27.
#
# No database needed. Everything runs in a CHILD perl process and this file
# asserts on what the child reports. It must never call track_account()
# itself: that would arm this file's own END block and make the test try to
# clean up a fictional account at exit (which it did, on the first draft --
# prove reported 10/10 subtests passed and still failed the file on a 255
# exit status). The live database round-trip is verified separately against
# a DB node.

my $lib = "$FindBin::Bin/lib";
ok(-f "$lib/TestAccounts.pm", 'the shared helper is where every suite expects it');

my $src = do { open my $fh, '<', "$lib/TestAccounts.pm" or die $!; local $/; <$fh> };

# It is `use`d at compile time in ~19 test files, which runs even when a
# file's own plan skip_all would have skipped it. A module that cannot fail
# to load cannot turn a skip into a whole-file abort -- so it must stay on
# core-only dependencies.
unlike $src, qr/^\s*use\s+Mojo/m, 'no Mojo dependency (loads under a bare perl)';
unlike $src, qr/-signatures/,     'no signatures feature (loads on an older perl)';

# -n on sudo: a test run must never block on a password prompt.
like $src, qr/'sudo',\s*'-n'/, 'sudo is called non-interactively';

# Deactivate rather than DELETE -- the rows are referenced by api.sessions,
# api.refresh_tokens and the audit trail.
like $src, qr/UPDATE api\.users SET active = FALSE/, 'accounts are deactivated, not deleted';
like $src, qr/DELETE FROM api\.user_roles/,          'granted roles are stripped (site_admin especially)';
like $src, qr/UPDATE api\.sessions SET revoked/,     'live sessions are revoked';
like $src, qr/UPDATE api\.refresh_tokens SET revoked/, 'refresh tokens are revoked too';

sub probe {
    my (@body) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print $fh "use lib '$lib';\nuse TestAccounts qw(track_account);\n", @body;
    close $fh;
    my $out = `$^X $path 2>&1`;
    return $out // '';
}

# An address the module cannot parse must never be dropped quietly: it is
# still an account somebody created. Regression -- the first version of this
# module validated addresses and then returned silently on a rejection, so a
# tracked account disappeared from the report with no output at all.
{
    my $out = probe(q{track_account(undef, 'bad\@addr');}, "\n");
    like $out, qr/NOT CLEANED UP -- unparseable/, 'an unparseable address is reported, never skipped silently';
    like $out, qr/\Qbad\@addr\E/,                 'and the offending address is named';
}

# track_account returns its argument, so it can wrap an address inline --
# login_jwt(track_account(undef, $addr), $pw) in the drive suites.
{
    my $out = probe(
        q{print STDERR '# RET=', scalar(track_account(undef, 'ret@test.mailmasker.org')), "\n";}, "\n");
    like $out, qr/# RET=ret\@test\.mailmasker\.org/,
        'track_account returns the address, so it can wrap a call';
}

# When no clean-up route works, say so loudly and name every address, so a
# human can finish the job by hand. Silence is how credentials get left
# behind. Only assertable where there is no usable local postgres.
SKIP: {
    my $have_pg = system('sudo -n -u postgres psql -d homelab -c "select 1" >/dev/null 2>&1') == 0;
    skip 'a working local postgres is present -- the no-route path cannot be exercised here', 3 if $have_pg;

    my $out = probe(q{track_account(undef, 'leak-probe@test.mailmasker.org');}, "\n");
    like $out, qr/COULD NOT CLEAN UP TEST ACCOUNTS/,  'an unreachable database is reported loudly';
    like $out, qr/leak-probe\@test\.mailmasker\.org/, 'and every leaked address is named';
    like $out, qr/by hand/,                            'and it says what to do about it';
}

done_testing();
