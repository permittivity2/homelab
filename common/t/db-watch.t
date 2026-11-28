use Mojo::Base -strict;
use Test::More;

BEGIN {
    plan skip_all => 'Mojo::Pg not installed' unless eval { require Mojo::Pg; 1 };
}
use Mojo::IOLoop;
use Homelab::Common::DB::Database;

# ---------------------------------------------------------------------------
# post-cutover #110: Homelab::Common::DB::Database overrides Mojo::Pg 4.28's
# _watch so a backend connection lost mid async query fails the pending query
# ONCE and removes the watcher, instead of the reactor re-firing a dead-socket
# callback every tick (the "connection not open" flood). Drive _watch with a
# fake reactor + dbh and assert all three outcomes of the readiness probe.
# ---------------------------------------------------------------------------

{
    package FakeResults;
    sub new { my ($c, %a) = @_; bless {%a}, $c }

    package FakeReactor;            # captures the io callback; remove() ends it
    sub new    { bless {}, shift }
    sub io     { my ($s, $h, $cb) = @_; $s->{cb} = $cb; return $s }
    sub watch  { return $_[0] }
    sub remove { my ($s) = @_; delete $s->{cb}; $s->{removed} = ($s->{removed} // 0) + 1; return $s }

    package FakeDbh;               # ready => 'die' | 0 | 1
    sub new         { my ($c, %a) = @_; bless { ready => $a{ready}, result => $a{result}, err => 'connection not open' }, $c }
    sub pg_ready    { my $s = shift; die "connection not open\n" if ($s->{ready} // '') eq 'die'; return $s->{ready} }
    sub pg_result   { $_[0]->{result} }
    sub errstr      { $_[0]->{err} }
    sub pg_notifies { undef }
}

# Build a Database on a fake dbh, register its watcher with a fake reactor,
# then fire the readable callback up to three times (as the reactor would).
sub run_watch {
    my (%opt) = @_;
    my $reactor = FakeReactor->new;
    Mojo::IOLoop->singleton->reactor($reactor);
    my $dbh = FakeDbh->new(ready => $opt{ready}, result => $opt{result});

    my @calls;
    my $db = Homelab::Common::DB::Database->new(dbh => $dbh);
    $db->results_class('FakeResults');
    $db->{handle} = \*STDIN;       # skip the pg_socket dup
    $db->{listen} = {};            # is_listening() wants a defined hash
    $db->{waiting} = { sth => 'FAKE_STH', cb => sub { my ($s, $err, $res) = @_; push @calls, { err => $err } } };

    $db->_watch;
    my $fires = 0;
    for (1 .. 3) { last unless $reactor->{cb}; $reactor->{cb}->($reactor); $fires++ }
    return { calls => \@calls, reactor => $reactor, fires => $fires, db => $db };
}

# 1) dead connection: fail once, watcher removed, nothing left to re-fire.
{
    my $r = run_watch(ready => 'die');
    is(scalar @{ $r->{calls} }, 1, 'dead connection: the pending query fails exactly once');
    like($r->{calls}[0]{err}, qr/connection not open/, 'dead connection: the callback gets the error');
    ok($r->{reactor}{removed}, 'dead connection: the watcher was removed (_unwatch)');
    ok(!defined $r->{reactor}{cb}, 'dead connection: no callback left -- the flood is over');
    is($r->{fires}, 1, 'dead connection: the callback fired once, not forever');
}

# 2) not ready yet: no callback, still waiting (a normal in-flight async query).
{
    my $r = run_watch(ready => 0);
    is(scalar @{ $r->{calls} }, 0, 'not ready: the query callback is not invoked');
    ok($r->{db}{waiting}, 'not ready: still waiting for the result');
}

# 3) ready: delivered once, no error.
{
    my $r = run_watch(ready => 1, result => 1);
    is(scalar @{ $r->{calls} }, 1, 'ready: the query callback is invoked once');
    is($r->{calls}[0]{err}, undef, 'ready: delivered with no error');
}

done_testing;
