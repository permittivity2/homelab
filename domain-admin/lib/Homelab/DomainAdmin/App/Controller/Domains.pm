package Homelab::DomainAdmin::App::Controller::Domains;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AuditClient qw(enqueue);

# GET /internal/v1/domains
sub list ($c) {
    $c->authenticated_email or return;
    my $rows = $c->app->pg->db->query('SELECT * FROM domainadmin.domains ORDER BY domain_name')->hashes->to_array;
    return $c->render(json => $rows);
}

# POST /internal/v1/domains {domain_name, mail_enabled?, dns_managed?, nameservers?}
# If dns_managed (default true), creates the PowerDNS zone first (only
# if it doesn't already exist -- an idempotent "add" for a domain whose
# zone was already provisioned some other way, e.g. by hand during
# initial bring-up, same as test.mailmasker.org's own history).
sub create ($c) {
    my $email = $c->authenticated_email or return;
    my $body = $c->req->json // {};
    my $domain_name = $body->{domain_name};
    return $c->render(json => { error => 'domain_name is required' }, status => 400) unless $domain_name;

    my $mail_enabled = exists $body->{mail_enabled} ? ($body->{mail_enabled} ? 1 : 0) : 1;
    my $dns_managed  = exists $body->{dns_managed}  ? ($body->{dns_managed}  ? 1 : 0) : 1;

    my $existing = $c->app->pg->db->query('SELECT id FROM domainadmin.domains WHERE domain_name = ?', $domain_name)->hash;
    return $c->render(json => { error => 'domain already exists' }, status => 409) if $existing;

    if ($dns_managed) {
        my $zone_created = 0;
        eval {
            unless ($c->app->powerdns->zone_exists($domain_name)) {
                $c->app->powerdns->create_zone($domain_name, nameservers => $body->{nameservers});
                $zone_created = 1;
            }
        };
        if ($@) {
            return $c->render(json => { error => "DNS zone creation failed: $@" }, status => 502);
        }
        $c->mark_pending_restart("new zone: $domain_name") if $zone_created;
    }

    my $row = $c->app->pg->db->query(
        'INSERT INTO domainadmin.domains (domain_name, mail_enabled, dns_managed, created_by) VALUES (?, ?, ?, ?) RETURNING *',
        $domain_name, $mail_enabled, $dns_managed, $email,
    )->hash;
    enqueue(
        $c->app->pg->db, user_email => $email, jti => $c->stash('current_jti'), action => 'domain.create',
        resource_type => 'domain', resource_id => $domain_name, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { mail_enabled => ($mail_enabled ? \1 : \0), dns_managed => ($dns_managed ? \1 : \0) },
    );
    return $c->render(json => $row, status => 201);
}

# GET /internal/v1/domains/:domain
sub show ($c) {
    $c->authenticated_email or return;
    my $row = $c->app->pg->db->query('SELECT * FROM domainadmin.domains WHERE domain_name = ?', $c->stash('domain'))->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    return $c->render(json => $row);
}

# PATCH /internal/v1/domains/:domain {mail_enabled?, dns_managed?, active?}
sub update ($c) {
    $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    my $body = $c->req->json // {};

    my $existing = $c->app->pg->db->query('SELECT id FROM domainadmin.domains WHERE domain_name = ?', $domain)->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $existing;

    my (@sets, @vals);
    for my $field (qw(mail_enabled dns_managed active)) {
        if (exists $body->{$field}) {
            push @sets, "$field = ?";
            push @vals, ($body->{$field} ? 1 : 0);
        }
    }
    unless (@sets) {
        my $row = $c->app->pg->db->query('SELECT * FROM domainadmin.domains WHERE domain_name = ?', $domain)->hash;
        return $c->render(json => $row);
    }

    push @sets, 'updated_at = NOW()';
    push @vals, $domain;
    my $sql = 'UPDATE domainadmin.domains SET ' . join(', ', @sets) . ' WHERE domain_name = ? RETURNING *';
    my $updated = $c->app->pg->db->query($sql, @vals)->hash;
    return $c->render(json => $updated);
}

# DELETE /internal/v1/domains/:domain -- soft: active=false. Never
# deletes the PowerDNS zone (see README.md) -- dns_managed/active are
# independent flags precisely so "stop accepting mail" doesn't imply
# "stop serving DNS for this domain at all".
sub disable ($c) {
    $c->authenticated_email or return;
    my $row = $c->app->pg->db->query(
        'UPDATE domainadmin.domains SET active = FALSE, updated_at = NOW() WHERE domain_name = ? RETURNING *',
        $c->stash('domain'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    return $c->render(json => { ok => \1 });
}

1;
