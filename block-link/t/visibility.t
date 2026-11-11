use Mojo::Base -strict, -signatures;
use Test::More;

# Who may see, and block, which of a link's addresses (Visibility.pm). Pure
# rules, no database and no app, so this runs in CI.
#
# Two regressions it guards:
#   - post-cutover item 48 (2026-11-03): one message delivered to two
#     mailmasker accounts gets ONE link, and the page used to show every
#     address on it to whoever opened it -- each recipient saw the other's
#     address, even a Bcc'd one, and one Save blocked the other person's
#     address on the other person's account.
#   - post-cutover item 69 (2026-11-11): a one-account link used to work for
#     whoever held it, signed in or not. The footer that carries the link is
#     quoted into replies and forwards, so the sender could block the alias
#     they were writing to. Now the link alone grants nothing.

use lib 'lib';
use Homelab::BlockLink::Visibility qw(view refused_addresses);

sub addrs ($list) { [ map { $_->{address} } @$list ] }

my $alice = 'alice@example.test';
my $bob   = 'bob@example.test';

my $one = [
    { account_email => $alice, address => 'shop1@alice.example' },
    { account_email => $alice, address => 'news@alice.example' },
];
my $two = [
    { account_email => $alice, address => 'shop1@alice.example' },
    { account_email => $bob,   address => 'bcc-copy@bob.example' },   # the Bcc'd one
    { account_email => $alice, address => 'news@alice.example' },
];

# --- one account on the link: nothing without a sign-in as that account ---
{
    my $v = view($one, '');
    is $v->{mode}, 'guest', 'one account, signed out: guest';
    is_deeply $v->{offer}, [], '... offers NOTHING (the link alone is no credential)';
    is_deeply $v->{main}, [], '... not even a main-address note';
    is $v->{for_other}, 0, '... not "signed in as someone else"';
    is $v->{accounts}, 1, '... one account';
    is_deeply refused_addresses($v, ['shop1@alice.example']), ['shop1@alice.example'],
        '... and a POST for any of them is refused';
}
{
    my $v = view($one, $alice);
    is $v->{mode}, 'owner', 'one account, signed in as it: owner';
    is_deeply addrs($v->{offer}), ['shop1@alice.example', 'news@alice.example'], '... offers every address';
    is $v->{for_other}, 0, '... the owner, not someone else';
    is_deeply refused_addresses($v, ['SHOP1@alice.example']), [], '... and a POST for one of them is allowed';
}
{
    my $v = view($one, 'carol@example.test');
    is $v->{mode}, 'guest', 'one account, signed in as someone else: guest';
    is $v->{for_other}, 1, '... flagged, so the page can say the link is for another account';
    is_deeply $v->{offer}, [], '... and nothing is offered';
    is_deeply refused_addresses($v, ['shop1@alice.example']), ['shop1@alice.example'], '... a POST is refused';
}

# --- two accounts on the link: the item-48 regression ---
{
    my $v = view($two, '');
    is $v->{mode}, 'guest', 'two accounts, signed out: guest';
    is_deeply $v->{offer}, [], '... offers NOTHING (no address of either account is shown)';
    is_deeply $v->{main}, [], '... not even a main-address note';
    is $v->{accounts}, 2, '... two accounts counted';
    is_deeply refused_addresses($v, ['shop1@alice.example']), ['shop1@alice.example'],
        '... and a POST for any of them is refused';
}
{
    my $v = view($two, $alice);
    is $v->{mode}, 'owner', 'two accounts, signed in as alice: owner';
    is_deeply addrs($v->{offer}), ['shop1@alice.example', 'news@alice.example'], '... only alice\'s addresses';
    ok !(grep { $_->{address} eq 'bcc-copy@bob.example' } @{ $v->{offer} }), '... the Bcc\'d one is not shown to alice';
    is_deeply refused_addresses($v, ['news@alice.example', 'bcc-copy@bob.example']), ['bcc-copy@bob.example'],
        '... alice cannot block bob\'s address';
}
{
    my $v = view($two, 'BOB@Example.Test');
    is $v->{mode}, 'owner', 'signed-in address matches ignoring case';
    is_deeply addrs($v->{offer}), ['bcc-copy@bob.example'], '... bob sees only his own';
}
{
    my $v = view($two, 'carol@example.test');
    is $v->{mode}, 'guest', 'two accounts, signed in as neither: guest';
    is $v->{for_other}, 1, '... flagged as someone else';
    is_deeply $v->{offer}, [], '... nothing offered';
}

# --- an account's main address is never offered, even to its owner ---
{
    my $v = view([
        { account_email => $alice, address => 'Alice@Example.Test' },
        { account_email => $alice, address => 'shop1@alice.example' },
    ], $alice);
    is_deeply addrs($v->{offer}), ['shop1@alice.example'], 'the main address is left out of the offer';
    is_deeply addrs($v->{main}), ['Alice@Example.Test'], '... and listed, so the page can say why';
    is_deeply refused_addresses($v, ['alice@example.test']), ['alice@example.test'], '... and a POST for it is refused';
}

# --- malformed candidates ---
{
    my $v = view([
        { account_email => $alice, address => 'a@alice.example' },
        { account_email => $alice, address => 'A@alice.example' },   # same address, other case
        { account_email => '',     address => 'orphan@x.example' },  # nobody to block it for
        { address => 'noacct@x.example' },
        'not a hash',
        { account_email => $alice },
    ], $alice);
    is_deeply addrs($v->{offer}), ['a@alice.example'], 'duplicates, orphans and junk are dropped';
    is $v->{accounts}, 1, '... and they do not count as a second account';
}
{
    my $v = view([], $alice);
    is $v->{mode}, 'guest', 'no candidates: nobody is its owner';
    is_deeply $v->{offer}, [], '... nothing offered';
    my $u = view(undef, undef);
    is $u->{mode}, 'guest', 'undef candidates and an undef visitor are handled';
    is_deeply $u->{offer}, [], '... nothing offered';
}

# refused_addresses compares ignoring case and keeps the request's order.
{
    my $v = view($one, $alice);
    is_deeply refused_addresses($v, ['SHOP1@alice.example', 'x@y.example', 'news@alice.example', 'z@y.example']),
        ['x@y.example', 'z@y.example'], 'refused: case-insensitive, in request order';
    is_deeply refused_addresses($v, []), [], 'an empty request refuses nothing';
}

done_testing;
