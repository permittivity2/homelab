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

1;
