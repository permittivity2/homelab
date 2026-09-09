package Homelab::API::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::API::Auth qw(hash_password verify_password generate_jwt verify_jwt generate_refresh_token);
use Homelab::API::Registry;

has 'pg';
has 'registry';

sub startup ($self) {
    my $config = load_config('HOMELAB_API_CONFIG', '/etc/homelab/api/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:3000'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/api-hypnotoad.pid',
        workers  => $srv->{workers} // 4,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->registry(Homelab::API::Registry->new(pg => $self->pg));

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $r = $self->routes;

    # --- Auth ---------------------------------------------------------
    $r->post('/api/v1/auth/register' => sub ($c) { $self->_register($c) });
    $r->post('/api/v1/auth/login'    => sub ($c) { $self->_login($c) });
    $r->get('/api/v1/auth/introspect' => sub ($c) { $self->_introspect($c) });
    $r->post('/api/v1/auth/refresh'  => sub ($c) { $self->_refresh($c) });
    $r->post('/api/v1/auth/logout'   => sub ($c) { $self->_logout($c) });

    # --- Service registry (see Homelab::Common::Registry — this is what
    # every OTHER feature's register()/lookup() calls hit) ------------
    $r->post('/api/v1/registry/register' => sub ($c) { $self->_registry_register($c) });
    $r->get('/api/v1/registry/:feature'  => sub ($c) { $self->_registry_lookup($c) });

    return;
}

# POST /api/v1/auth/register {email, password}
# Deliberately open (no auth required) for now — this is a test/dev
# domain (test.mailmasker.org) and the fastest path to real test
# accounts. Revisit (admin-only, or an invite flow) before this is ever
# pointed at anything resembling production.
sub _register ($self, $c) {
    my $body     = $c->req->json // {};
    my $email    = $body->{email};
    my $password = $body->{password};

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    my $existing = $self->pg->db->query('SELECT id FROM api.users WHERE email = ?', $email)->hash;
    return $c->render(json => { error => 'email already registered' }, status => 409) if $existing;

    my $hash = hash_password($password);
    my $user = $self->pg->db->query(
        'INSERT INTO api.users (email, password_hash) VALUES (?, ?) RETURNING id',
        $email, $hash,
    )->hash;

    my $user_role_id = $self->pg->db->query(q{SELECT id FROM api.roles WHERE name = 'user'})->hash->{id};
    $self->pg->db->query(
        'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
        $user->{id}, $user_role_id,
    );

    return $c->render(json => { id => $user->{id}, email => $email }, status => 201);
}

sub _login ($self, $c) {
    my $body     = $c->req->json // {};
    my $email    = $body->{email};
    my $password = $body->{password};

    return $c->render(json => { error => 'email and password are required' }, status => 400)
        unless $email && $password;

    my $user = $self->pg->db->query(
        'SELECT id, password_hash, active FROM api.users WHERE email = ?', $email,
    )->hash;

    unless ($user && $user->{active} && verify_password($password, $user->{password_hash})) {
        return $c->render(json => { error => 'invalid email or password' }, status => 401);
    }

    my ($jwt, $expires_in) = generate_jwt($email, secret => $self->config->{jwt}{secret}, expires_in => $self->config->{jwt}{expiry_seconds});
    my $refresh_token = generate_refresh_token();
    my $refresh_ttl_days = $self->config->{jwt}{refresh_expiry_days} // 30;

    $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day'))},
        $user->{id}, $refresh_token, $refresh_ttl_days,
    );

    return $c->render(json => {
        success       => \1,
        token         => $jwt,
        refresh_token => $refresh_token,
        expires_in    => $expires_in,
        email         => $email,
    });
}

sub _introspect ($self, $c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    return $c->render(json => { error => 'Token required' }, status => 401) unless $jwt;

    my $payload = verify_jwt($jwt, secret => $self->config->{jwt}{secret});
    return $c->render(json => { error => 'invalid or expired token' }, status => 401) unless $payload;

    return $c->render(json => { email => $payload->{email}, exp => $payload->{exp} });
}

sub _refresh ($self, $c) {
    my $body          = $c->req->json // {};
    my $refresh_token = $body->{refresh_token};
    return $c->render(json => { error => 'refresh_token is required' }, status => 400) unless $refresh_token;

    my $row = $self->pg->db->query(
        q{SELECT rt.id, rt.user_id, u.email FROM api.refresh_tokens rt
          JOIN api.users u ON u.id = rt.user_id
          WHERE rt.token = ? AND rt.revoked = FALSE AND rt.expires_at > NOW()},
        $refresh_token,
    )->hash;
    return $c->render(json => { error => 'invalid or expired refresh_token' }, status => 401) unless $row;

    # Rotate: revoke the old token, issue a new one — a stolen, already-
    # used refresh token becomes immediately useless to an attacker on
    # the legitimate client's next refresh.
    $self->pg->db->query('UPDATE api.refresh_tokens SET revoked = TRUE WHERE id = ?', $row->{id});

    my ($jwt, $expires_in) = generate_jwt($row->{email}, secret => $self->config->{jwt}{secret}, expires_in => $self->config->{jwt}{expiry_seconds});
    my $new_refresh_token = generate_refresh_token();
    my $refresh_ttl_days  = $self->config->{jwt}{refresh_expiry_days} // 30;

    $self->pg->db->query(
        q{INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + (? * INTERVAL '1 day'))},
        $row->{user_id}, $new_refresh_token, $refresh_ttl_days,
    );

    return $c->render(json => {
        success       => \1,
        token         => $jwt,
        refresh_token => $new_refresh_token,
        expires_in    => $expires_in,
    });
}

sub _logout ($self, $c) {
    my $body          = $c->req->json // {};
    my $refresh_token = $body->{refresh_token};
    $self->pg->db->query('UPDATE api.refresh_tokens SET revoked = TRUE WHERE token = ?', $refresh_token)
        if $refresh_token;
    return $c->render(json => { success => \1 });
}

sub _registry_register ($self, $c) {
    my $body = $c->req->json // {};
    for my $field (qw(feature_name host port)) {
        return $c->render(json => { error => "$field is required" }, status => 400)
            unless defined $body->{$field};
    }
    $self->registry->register(%$body);
    return $c->render(json => { ok => \1 });
}

sub _registry_lookup ($self, $c) {
    my $feature = $c->param('feature');
    my $entry   = $self->registry->lookup($feature);
    return $c->render(json => { error => 'not found' }, status => 404) unless $entry;
    return $c->render(json => $entry);
}

1;
