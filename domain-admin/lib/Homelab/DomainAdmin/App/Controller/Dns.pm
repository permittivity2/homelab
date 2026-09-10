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

1;
