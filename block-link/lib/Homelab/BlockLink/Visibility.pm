package Homelab::BlockLink::Visibility;
use Mojo::Base -strict, -signatures;
use Exporter 'import';

our @EXPORT_OK = qw(view refused_addresses);

# Who may see, and block, which of a link's addresses.
#
# WHY THIS EXISTS. homelab-postfix-block-link makes ONE link per message, and
# a message can reach several mailmasker accounts in one delivery (To, Cc or
# Bcc): its envrcpt callback collects every enabled recipient, eom writes one
# pending_links row, and the same link goes into every copy. Until 2026-11-03
# the page showed every address on the link to whoever opened it, with every
# box checked -- so each recipient saw the others' addresses, even a Bcc'd
# one, and one person's Save blocked the other person's address, on the other
# person's account. A milter cannot give each recipient a different link (one
# shared body and header set per transaction), so the rule lives here instead,
# at the only place that knows who is looking.
#
# THE RULE, decided with the owner 2026-11-03 (post-cutover item 48):
#   - Signed in as one of the link's accounts ("owner"): that account's
#     addresses only, plus its own block list.
#   - Otherwise, a link that covers ONE account ("link") keeps the one-click
#     block it always had: the token in the email is the credential, the same
#     trust model as before.
#   - Otherwise ("several"): nothing until you sign in as one of them.
# show() and submit() both call view(), so the page can never offer something
# the server would then refuse, or the other way round.
#
# An account's MAIN address is never offered, whatever the mode: blocking it
# stops all of that account's mail, password resets included. homelab-domain-
# admin's own self-service endpoint already refuses exactly that
# (_is_own_exact_address); the link's on-behalf path never checked it.

sub _norm ($s) { return lc($s // '') }

# view(\@candidates, $signed_in_email) -> {
#     mode      => 'owner' | 'link' | 'several',
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

    my ($mode, @scope);
    if (length $me && $accounts{$me}) {
        $mode  = 'owner';
        @scope = grep { _norm($_->{account_email}) eq $me } @valid;
    }
    elsif (keys %accounts <= 1) {
        $mode  = 'link';
        @scope = @valid;
    }
    else {
        $mode = 'several';
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
