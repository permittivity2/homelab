package Homelab::Common::Queue;
use Mojo::Base -strict;
use Minion;
use Homelab::Common::DB qw(pg_url);
use Exporter 'import';

our @EXPORT_OK = qw(new_minion);

# Returns a Minion instance backed by Postgres, using a feature's normal
# RUNTIME connection info (through pgbouncer, same as everything else —
# Minion::Backend::Pg manages its own internal tables/migrations on
# first use, nothing extra needed here). Task names should be namespaced
# by owning feature (e.g. 'drive.thumbnail', 'backup.reconcile') since
# the underlying jobs table is necessarily shared across every feature —
# see CLAUDE.md for why that's fine (enqueuing isn't authority; the
# worker code for a task decides what it's willing to do).
#
# Returns a bare Minion object — not every consumer is a Mojolicious app
# (a plain worker script just needs ->enqueue/->perform_jobs), so this
# doesn't assume one. A Mojolicious app that wants the Minion::Admin
# dashboard can still do: $app->plugin(Minion => {Pg => pg_url(%opts)});
sub new_minion {
    my (%opts) = @_;
    return Minion->new(Pg => pg_url(%opts));
}

1;
