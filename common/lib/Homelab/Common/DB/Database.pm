package Homelab::Common::DB::Database;
use Mojo::Base 'Mojo::Pg::Database';

use Mojo::IOLoop;

# Mojo::Pg 4.28's Mojo::Pg::Database::_watch, with ONE change, to end the
# runaway "connection not open" flood of post-cutover #110.
#
# THE BUG. For an async query (query_p / pub-sub) Mojo::Pg registers the
# backend socket with the reactor; when it is readable the callback probes the
# backend with $dbh->pg_ready while RaiseError is still on. If the connection
# has gone -- a Patroni leader switch dropped it mid-query -- pg_ready DIES.
# The exception escapes the reactor callback *before* `waiting` is cleared and
# *before* _unwatch runs, so the pending query's callback is never invoked, the
# dead socket stays readable, and the reactor fires this same callback again on
# every tick, forever: ~500 lines/s of DBD::Pg "connection not open" to the
# root disk until the process restarts (2 GB/day; it filled prod-homelab12).
#
# THE FIX. Probe readiness without letting a dead connection throw. $ready is:
#   undef -> the connection is gone: fail the pending query ONCE with the
#            error, _unwatch, and let the handle drop so Mojo::Pg's own
#            ping-on-dequeue discards it and the next ->db reconnects;
#   0     -> not ready yet (the query is still running) -- keep waiting, exactly
#            as upstream does, so normal async queries are untouched;
#   1     -> ready -- proceed to pg_result as upstream does.
# Everything else is a byte-for-byte copy of upstream 4.28, so a future
# libmojo-pg-perl bump should be diffed against this (t/db-watch.t guards it).
sub _watch {
  my $self = shift;

  return if $self->{watching} || $self->{watching}++;

  my $dbh = $self->dbh;
  unless ($self->{handle}) {
    open $self->{handle}, '<&', $dbh->{pg_socket} or die "Can't dup: $!";
  }
  Mojo::IOLoop->singleton->reactor->io(
    $self->{handle} => sub {
      my $reactor = shift;

      return $self->_unwatch if !$self->_notifications && !$self->{waiting};

      # --- the only departure from upstream (post-cutover #110) ---
      my $ready = do {
        local $dbh->{RaiseError} = 0;
        local $dbh->{PrintError} = 0;
        my $r = eval { $dbh->pg_ready };
        $@ ? undef : $r;
      };
      if (!defined $ready) {
        if (my $waiting = delete $self->{waiting}) {
          my ($sth, $cb) = @{$waiting}{qw(sth cb)};
          $self->$cb($dbh->errstr // 'connection not open',
            $self->results_class->new(db => $self, sth => $sth));
        }
        return $self->_unwatch;
      }
      return if !$self->{waiting} || !$ready;
      # --- end of the departure ---

      my ($sth, $cb) = @{delete $self->{waiting}}{qw(sth cb)};

      # Do not raise exceptions inside the event loop
      my $result = do { local $dbh->{RaiseError} = 0; $dbh->pg_result };
      my $err    = defined $result ? undef : $dbh->errstr;

      $self->$cb($err, $self->results_class->new(db => $self, sth => $sth));
      $self->_finish_when_safe(@{delete $self->{finish}}) if $self->{finish};
      $self->_unwatch unless $self->{waiting} || $self->is_listening;
    }
  )->watch($self->{handle}, 1, 0);
}

1;

=head1 NAME

Homelab::Common::DB::Database - Mojo::Pg::Database that survives a dropped backend

=head1 DESCRIPTION

A one-method subclass of L<Mojo::Pg::Database> used as the C<database_class> of
every runtime handle built by L<Homelab::Common::DB/runtime_pg>. It overrides
the private C<_watch> so that a backend connection lost mid async query fails
the pending query once and reconnects, instead of looping on a dead socket and
flooding the log (post-cutover #110).

=cut
