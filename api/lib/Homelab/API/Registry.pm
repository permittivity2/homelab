package Homelab::API::Registry;
use Mojo::Base -base, -signatures;

has 'pg';

# Upserts on (feature_name, host, port), not feature_name alone -- see
# 009-multi-instance-registry.sql. A restarted/keepalive re-registration
# from the SAME instance (same host:port) still updates in place; a
# genuinely different instance of the same feature_name (a second
# homelab-drive, a rolling-upgrade replacement still warming up
# alongside the old one) adds a separate row instead of overwriting it.
sub register ($self, %opts) {
    $self->pg->db->query(
        'INSERT INTO api.service_registry (feature_name, host, port, health_check_url, description, updated_at)
         VALUES (?, ?, ?, ?, ?, NOW())
         ON CONFLICT (feature_name, host, port) DO UPDATE
             SET health_check_url = EXCLUDED.health_check_url,
                 description = EXCLUDED.description, updated_at = NOW()',
        $opts{feature_name}, $opts{host}, $opts{port}, $opts{health_check_url}, $opts{description},
    );
    return 1;
}

# Picks ONE row when multiple instances of $feature_name are
# registered -- most-recently-updated first, on the reasoning that a
# stale/dead instance's row stops getting keepalive-refreshed and so
# sorts last. This is a pragmatic single choice, not real load
# balancing or health-aware routing -- if this feature ever needs
# genuine multi-instance traffic distribution, that belongs in front of
# it (an HAProxy backend with multiple `server` lines, the same pattern
# already used for dovecot/postfix), not bolted onto this lookup.
sub lookup ($self, $feature_name) {
    return $self->pg->db->query(
        'SELECT feature_name, host, port, health_check_url, description
         FROM api.service_registry WHERE feature_name = ? ORDER BY updated_at DESC LIMIT 1',
        $feature_name,
    )->hash;
}

# Non-blocking twin of lookup() above, for the gateway's own hot path
# (_gateway in App.pm runs this on EVERY /api/v1/{drive,mail,domains,
# jobs,audit}/* request) -- a blocking ->query() here parks the whole
# hypnotoad worker for the round trip before forward() even starts.
sub lookup_p ($self, $feature_name) {
    return $self->pg->db->query_p(
        'SELECT feature_name, host, port, health_check_url, description
         FROM api.service_registry WHERE feature_name = ? ORDER BY updated_at DESC LIMIT 1',
        $feature_name,
    )->then(sub ($results) { return $results->hash });
}

# Every registered row, including every instance of a multi-instance
# feature_name -- deliberately not deduplicated to one-per-feature, so
# `homelab-cli registry list` can actually show "there are 2 of these."
sub list_all ($self) {
    return $self->pg->db->query(
        'SELECT feature_name, host, port, health_check_url, description
         FROM api.service_registry ORDER BY feature_name, updated_at DESC',
    )->hashes->to_array;
}

# Infrastructure registry: non-HTTP topology (dovecot, postfix, HAProxy
# frontends, webproxy vhosts) -- see 009-multi-instance-registry.sql for
# why this is a separate table from service_registry above, never
# consulted by _gateway's forwarding logic.
sub register_infrastructure ($self, %opts) {
    $self->pg->db->query(
        'INSERT INTO api.infrastructure_registry (name, kind, host, port, description, fronts, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())
         ON CONFLICT (name, host, port) DO UPDATE
             SET kind = EXCLUDED.kind, description = EXCLUDED.description,
                 fronts = EXCLUDED.fronts, updated_at = NOW()',
        $opts{name}, $opts{kind}, $opts{host}, $opts{port}, $opts{description}, $opts{fronts},
    );
    return 1;
}

# Removes every row for a given $name prefix before its caller
# re-registers its current set -- for a config that's regenerated
# wholesale on every apply (HAProxy's backends.yml -> haproxy.cfg,
# webproxy's sites.yml -> vhosts, both already documented as "not
# merged" in their own generated-file headers), a renamed/removed
# frontend or vhost should disappear from the topology view too,
# not accumulate forever. Callers pass their own stable prefix
# (e.g. 'haproxy-', 'webproxy-') so this can never touch another
# package's rows.
sub replace_infrastructure_by_prefix ($self, $prefix, @entries) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query('DELETE FROM api.infrastructure_registry WHERE name LIKE ?', "$prefix%");
    for my $e (@entries) {
        $db->query(
            'INSERT INTO api.infrastructure_registry (name, kind, host, port, description, fronts, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, NOW())',
            $e->{name}, $e->{kind}, $e->{host}, $e->{port}, $e->{description}, $e->{fronts},
        );
    }
    $tx->commit;
    return 1;
}

sub list_infrastructure ($self) {
    return $self->pg->db->query(
        'SELECT name, kind, host, port, description, fronts, updated_at
         FROM api.infrastructure_registry ORDER BY kind, name, host',
    )->hashes->to_array;
}

1;
