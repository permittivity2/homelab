package Homelab::BlockLink::Visibility;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(view refused_addresses);

# Who may see, and block, which of a link's addresses.
#
# THE RULE (post-cutover item 69, 2026-11-11): the link alone is NOT a
# credential. Only someone signed in (through homelab-sso) as one of the
# accounts the message was delivered to sees anything, and then only that
# account's addresses:
#   - 'owner': signed in as one of the link's accounts -> that account's
#     addresses from the message, and its own block list.
#   - 'guest': anyone else -- not signed in, or signed in as some other
#     account -> nothing: no address, no form, nothing to block.
# show() and submit() both call view(), so the page can never offer something
# the server would then refuse, or the other way round.
#
# WHY. Until 0.1.6 a link that covered ONE account kept a one-click block for
# whoever held it ("the token in the email is the credential", item 48), on
# the reasoning that only the recipient ever opened their own mail. That
# stopped being true: the footer line that carries the link is quoted into
# every reply and forward, and since item 67 (replies go out from the alias
# the message came to) the original sender routinely ends up holding a
# working link -- and could block the very alias they were writing to. The
# owner's decision on 2026-11-11: sign-in, with no exception.
#
# A link can also cover SEVERAL accounts: homelab-postfix-block-link makes
# one link per message (one shared body and header set per transaction), and
# a message can reach several mailmasker accounts in one delivery (To, Cc or
# Bcc). The owner view scopes to the signed-in account, so each recipient
# sees and blocks only their own addresses, never another's Bcc'd copy.
#
# An account's MAIN address is never offered, whatever the mode: blocking it
# stops all of that account's mail, password resets included. homelab-domain-
# admin's own self-service endpoint already refuses exactly that
# (_is_own_exact_address); the link's on-behalf path never checked it.

sub _norm ($s) { return lc($s // '') }

# view(\@candidates, $signed_in_email) -> {
#     mode      => 'owner' | 'guest',
#     offer     => [ candidates that may be blocked from this page ],
#     main      => [ in-scope candidates that are an account's main address ],
#     accounts  => number of distinct accounts on the link,
#     for_other => 1 when signed in, but as none of the link's accounts,
# }
# Candidates are the pending_links JSON: [{address, account_email}, ...].
sub view ($candidates, $signed_in = '') {
    my (%seen, @valid);
    for my $c (@{ $candidates // [] }) {
        next unless ref $c eq 'HASH';
        next unless length($c->{address} // '') && length($c->{account_email} // '');
        # No account means nobody to block it on behalf of, and a repeated
        # address is the same address however it was spelt.
        next if $seen{ _norm($c->{address}) }++;
        push @valid, { address => $c->{address}, account_email => $c->{account_email} };
    }

    my %accounts = map { _norm($_->{account_email}) => 1 } @valid;
    my $me = _norm($signed_in);

    my ($mode, @scope) = ('guest');
    if (length $me && $accounts{$me}) {
        $mode  = 'owner';
        @scope = grep { _norm($_->{account_email}) eq $me } @valid;
    }

    my (@offer, @main);
    for my $c (@scope) {
        if (_norm($c->{address}) eq _norm($c->{account_email})) { push @main, $c }
        else                                                    { push @offer, $c }
    }

    return {
        mode      => $mode,
        offer     => \@offer,
        main      => \@main,
        accounts  => scalar(keys %accounts),
        for_other => (length $me && !$accounts{$me}) ? 1 : 0,
    };
}

# The requested addresses this view does NOT allow, in request order.
sub refused_addresses ($view, $requested) {
    my %offer = map { _norm($_->{address}) => 1 } @{ $view->{offer} };
    return [ grep { !$offer{ _norm($_) } } @{ $requested // [] } ];
}

1;
