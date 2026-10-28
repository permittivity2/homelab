package TestAccounts;

# Deliberately dependency-free: plain strict/warnings, no Mojo::Base, no
# signatures. Every consuming test `use`s this at COMPILE time, which runs
# even when the file's own `plan skip_all` would have skipped it (see the
# long comment in audit/t/basic.t about exactly that hazard). A module that
# cannot fail to load cannot turn a skip into a whole-file abort.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(track_account);

# Clean-up for accounts the integration tests create.
#
# WHY THIS EXISTS. These tests register real, loginable accounts -- several
# of them then granted site_admin -- with passwords written in plain text in
# the test files, into whatever database the config points at. That is now
# routinely PRODUCTION, because it is the only place a full fleet database
# exists. Found 2026-10-27: five runs of the api suite had left 25 live
# accounts behind, 5 of them site_admin, all with known passwords.
#
# ONE implementation, shared by every package, rather than an END block
# copied into each test file. This codebase keeps getting bitten by a fix
# applied to one copy and not its siblings; a security clean-up is the last
# thing that should be duplicated.
#
# Deactivate + strip roles + revoke sessions rather than DELETE: the rows
# are referenced by api.sessions, api.refresh_tokens and the audit trail,
# so a delete means either cascading or a foreign-key error -- and the audit
# record of what the test did is worth keeping. Deactivated, role-less and
# with no live session, the account cannot log in or be used for anything.

my ($APP, @TRACKED);

# track_account($app_or_undef, @emails)
#
# Call it right where the address is minted, so an account registered by a
# test that later dies is still cleaned up. Returns its arguments, so it can
# wrap an assignment.
#
# $app may be:
#   - an app with ->pg (the api suite): cleaned up through that handle.
#   - undef, or an app without ->pg (drive, invite, sso, worker, audit,
#     block-link, domain-admin -- which register over HTTP against the API
#     and have no api-schema credentials of their own): cleaned up with
#     `sudo -u postgres psql`, which is the same technique those suites
#     ALREADY require in order to grant themselves site_admin. So this adds
#     no new privilege requirement to any test that did not have it.
#
# KNOWN CEILING. Only homelab_api_runtime/_migrate hold UPDATE on api.users;
# no other package's runtime role has any grant on the api schema at all.
# So for every package except api, clean-up needs local postgres -- i.e.
# those suites can only clean up when run ON a database node, which is also
# the only place their own site_admin grant works. Run them anywhere else
# and the END block below says so, loudly, naming each address. That warning
# is the signal to either move the run to a DB node or deactivate by hand;
# it is deliberately not a silent no-op.
sub track_account {
    my ($app, @emails) = @_;
    $APP = $app if $app;
    push @TRACKED, grep { defined && length } @emails;
    return wantarray ? @emails : $emails[0];
}

# Addresses are generated from fixed prefixes plus time/$$, so they are
# always plain. Validate anyway -- these get interpolated into SQL for the
# psql backend, and "it can't contain a quote" is an assumption worth
# enforcing rather than trusting.
sub _safe_addr {
    my ($addr) = @_;
    return $addr =~ /\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\z/ ? $addr : undef;
}

sub _neutralise_sql {
    my (@addrs) = @_;
    my $list = join ', ', map { "'$_'" } @addrs;
    return (
        "UPDATE api.refresh_tokens SET revoked = TRUE WHERE id IN "
          . "(SELECT refresh_token_id FROM api.sessions WHERE user_id IN "
          . "(SELECT id FROM api.users WHERE email IN ($list)))",
        "UPDATE api.sessions SET revoked = TRUE WHERE user_id IN "
          . "(SELECT id FROM api.users WHERE email IN ($list))",
        "DELETE FROM api.user_roles WHERE user_id IN "
          . "(SELECT id FROM api.users WHERE email IN ($list))",
        "UPDATE api.users SET active = FALSE WHERE email IN ($list)",
    );
}

sub _cleanup_via_app {
    my (@addrs) = @_;
    my $db = eval { $APP->pg->db } or return 0;
    for my $sql (_neutralise_sql(@addrs)) {
        eval { $db->query($sql); 1 } or return 0;
    }
    return 1;
}

sub _cleanup_via_psql {
    my (@addrs) = @_;
    for my $sql (_neutralise_sql(@addrs)) {
        my @cmd = ('sudo', '-n', '-u', 'postgres', 'psql', '-d', 'homelab',
                   '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', $sql);
        system(@cmd);
        return 0 if $? != 0;
    }
    return 1;
}

# END, not a teardown line: it must run even when a test dies partway
# through, which is exactly when credentials get orphaned.
END {
    return unless @TRACKED;

    my (@addrs, @rejected);
    for my $addr (@TRACKED) {
        if (defined _safe_addr($addr)) { push @addrs, $addr }
        else                           { push @rejected, $addr }
    }

    # Never drop a rejected address quietly. An address this module cannot
    # parse is still an account somebody created; staying silent about it is
    # the same silent-leak failure the loud branch below exists to prevent.
    # (Caught by this module's own test: an address carrying a stray
    # backslash was skipped with no output at all.)
    if (@rejected) {
        print STDERR
          "# TestAccounts: *** NOT CLEANED UP -- unparseable address(es) ***\n",
          map({ "#     $_\n" } @rejected);
    }

    return unless @addrs;

    my $ok = _cleanup_via_app(@addrs) || _cleanup_via_psql(@addrs);

    if ($ok) {
        print STDERR "# TestAccounts: neutralised " . scalar(@addrs) . " test account(s)\n";
    }
    else {
        # Loud and specific. A silent failure here is how live credentials
        # end up sitting in production unnoticed for weeks.
        print STDERR
          "# TestAccounts: *** COULD NOT CLEAN UP TEST ACCOUNTS ***\n",
          "#   Left behind, with the passwords written in this test file:\n",
          map({ "#     $_\n" } @addrs),
          "#   Neither the app's own DB handle nor `sudo -u postgres psql -d homelab`\n",
          "#   worked. Deactivate them by hand before leaving them in production.\n";
    }
}

1;
