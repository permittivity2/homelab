package Homelab::API::Registry;
use Mojo::Base -base, -signatures;

has 'pg';

sub register ($self, %opts) {
    $self->pg->db->query(
        'INSERT INTO api.service_registry (feature_name, host, port, health_check_url, updated_at)
         VALUES (?, ?, ?, ?, NOW())
         ON CONFLICT (feature_name) DO UPDATE
             SET host = EXCLUDED.host, port = EXCLUDED.port,
                 health_check_url = EXCLUDED.health_check_url, updated_at = NOW()',
        $opts{feature_name}, $opts{host}, $opts{port}, $opts{health_check_url},
    );
    return 1;
}

sub lookup ($self, $feature_name) {
    return $self->pg->db->query(
        'SELECT feature_name, host, port, health_check_url FROM api.service_registry WHERE feature_name = ?',
        $feature_name,
    )->hash;
}

# Non-blocking twin of lookup() above, for the gateway's own hot path
# (_gateway in App.pm runs this on EVERY /api/v1/{drive,mail,domains,
# jobs,audit}/* request) -- a blocking ->query() here parks the whole
# hypnotoad worker for the round trip before forward() even starts.
sub lookup_p ($self, $feature_name) {
    return $self->pg->db->query_p(
        'SELECT feature_name, host, port, health_check_url FROM api.service_registry WHERE feature_name = ?',
        $feature_name,
    )->then(sub ($results) { return $results->hash });
}

sub list_all ($self) {
    return $self->pg->db->query(
        'SELECT feature_name, host, port, health_check_url FROM api.service_registry ORDER BY feature_name',
    )->hashes->to_array;
}

1;
