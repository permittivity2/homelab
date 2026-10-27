package Homelab::DomainAdmin::App::Controller::Dns;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub _domain_row ($c, $domain) {
    return $c->app->pg->db->query('SELECT * FROM domainadmin.domains WHERE domain_name = ?', $domain)->hash;
}

# GET /internal/v1/domains/:domain/dns/records
sub list_records ($c) {
    $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    return $c->render(json => { error => 'domain not found' }, status => 404) unless _domain_row($c, $domain);

    my $zone = eval { $c->app->powerdns->get_zone($domain) };
    return $c->render(json => { error => "could not read DNS zone: $@" }, status => 502) if $@;
    return $c->render(json => { error => 'DNS zone not found' }, status => 404) unless $zone;

    my @records = map {
        {
            name    => $_->{name},
            type    => $_->{type},
            ttl     => $_->{ttl},
            content => [ map { $_->{content} } @{ $_->{records} // [] } ],
        }
    } @{ $zone->{rrsets} // [] };
    return $c->render(json => \@records);
}

# POST /internal/v1/domains/:domain/dns/records {name, type, content, ttl?}
# content may be a single string or an array (multiple records of the
# same name+type, e.g. two MX hosts). changetype REPLACE means this call
# always sends the COMPLETE desired record set for (name, type) -- not
# an incremental "add one more" -- matching PowerDNS's own API shape.
sub upsert_record ($c) {
    $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    return $c->render(json => { error => 'domain not found' }, status => 404) unless _domain_row($c, $domain);

    my $body = $c->req->json // {};
    my ($name, $type, $content) = @{$body}{qw(name type content)};
    my $ttl = $body->{ttl} // 3600;
    return $c->render(json => { error => 'name, type, and content are required' }, status => 400)
        unless $name && $type && $content;
    my @values = ref($content) eq 'ARRAY' ? @$content : ($content);

    my $is_new_name = eval { !$c->app->powerdns->rrset_exists($domain, $name, $type) };
    eval { $c->app->powerdns->upsert_rrset($domain, $name, $type, $ttl, \@values) };
    return $c->render(json => { error => "DNS record write failed: $@" }, status => 502) if $@;

    $c->mark_pending_restart("new record: $name $type ($domain)") if $is_new_name;

    return $c->render(json => { ok => \1, restart_pending => ($is_new_name ? \1 : \0) }, status => 201);
}

# DELETE /internal/v1/domains/:domain/dns/records {name, type}
sub delete_record ($c) {
    $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    return $c->render(json => { error => 'domain not found' }, status => 404) unless _domain_row($c, $domain);

    my $body = $c->req->json // {};
    my ($name, $type) = @{$body}{qw(name type)};
    return $c->render(json => { error => 'name and type are required' }, status => 400) unless $name && $type;

    eval { $c->app->powerdns->delete_rrset($domain, $name, $type) };
    return $c->render(json => { error => "DNS record delete failed: $@" }, status => 502) if $@;

    # Deletion is treated the same as an add for the restart gotcha --
    # the documented PowerDNS behavior only confirms the add case;
    # conservative until proven otherwise (see README.md).
    $c->mark_pending_restart("deleted record: $name $type ($domain)");

    return $c->render(json => { ok => \1, restart_pending => \1 });
}


# --- ACME DNS-01 challenge records -----------------------------------
# A deliberately NARROW pair of endpoints so the cert server can solve a
# DNS-01 challenge with its system_agent credential instead of a site_admin
# login. The gate (authenticated_system_agent) says WHO may call; the checks
# below say WHAT may be written:
#
#   * the record name must be exactly "_acme-challenge" or
#     "_acme-challenge.<something>" within the target zone, and
#   * the type is forced to TXT -- it is never taken from the caller.
#
# So an agent token leaked off the cert server cannot be used to repoint MX,
# A, or NS records. That containment is the reason this exists as its own
# route rather than as a relaxed gate on upsert_record/delete_record.

# Normalize + validate the challenge name, returning the FQDN to write or
# undef if it is not a legitimate _acme-challenge name for this zone.
sub _acme_name ($domain, $name) {
    return undef unless defined $name && length $name;
    $name =~ s/\.\z//;                      # tolerate a trailing dot
    my $fqdn = ($name =~ /\Q$domain\E\z/) ? $name : "$name.$domain";
    # must sit at/under _acme-challenge within THIS zone
    return undef unless $fqdn =~ /\A_acme-challenge(?:\.[^.]+)*\.\Q$domain\E\z/;
    return $fqdn;
}

sub acme_challenge_set ($c) {
    $c->authenticated_system_agent or return;
    my $domain = $c->stash('domain');
    return $c->render(json => { error => 'domain not found' }, status => 404) unless _domain_row($c, $domain);

    my $body = $c->req->json // {};
    my $fqdn = _acme_name($domain, $body->{name} // "_acme-challenge.$domain");
    return $c->render(json => { error => 'name must be an _acme-challenge record within the domain' }, status => 400)
        unless $fqdn;

    my $value = $body->{value};
    my @values = ref($value) eq 'ARRAY' ? @$value : (defined $value ? ($value) : ());
    return $c->render(json => { error => 'value is required' }, status => 400) unless @values;
    # ACME tokens are base64url; refuse anything else rather than letting an
    # arbitrary string into the zone.
    for my $v (@values) {
        return $c->render(json => { error => 'value must be a base64url ACME token' }, status => 400)
            unless $v =~ /\A[A-Za-z0-9_-]{20,128}\z/;
    }
    # PowerDNS stores TXT content quoted.
    my @quoted = map { qq{"$_"} } @values;

    # TTL 60: the challenge lives for seconds, and a short TTL keeps a failed
    # attempt from being cached against the next one.
    eval { $c->app->powerdns->upsert_rrset($domain, $fqdn, 'TXT', 60, \@quoted) };
    return $c->render(json => { error => "ACME challenge write failed: $@" }, status => 502) if $@;

    return $c->render(json => { ok => \1, name => $fqdn, count => scalar(@values) }, status => 201);
}

sub acme_challenge_clear ($c) {
    $c->authenticated_system_agent or return;
    my $domain = $c->stash('domain');
    return $c->render(json => { error => 'domain not found' }, status => 404) unless _domain_row($c, $domain);

    my $body = $c->req->json // {};
    my $fqdn = _acme_name($domain, $body->{name} // "_acme-challenge.$domain");
    return $c->render(json => { error => 'name must be an _acme-challenge record within the domain' }, status => 400)
        unless $fqdn;

    eval { $c->app->powerdns->delete_rrset($domain, $fqdn, 'TXT') };
    return $c->render(json => { error => "ACME challenge delete failed: $@" }, status => 502) if $@;

    return $c->render(json => { ok => \1, name => $fqdn });
}

1;
