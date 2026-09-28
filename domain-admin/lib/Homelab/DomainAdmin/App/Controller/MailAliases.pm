package Homelab::DomainAdmin::App::Controller::MailAliases;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AuditClient qw(enqueue);

# GET /internal/v1/domains/mail-aliases[?destination=<email>]
sub list ($c) {
    $c->authenticated_email or return;
    my $destination = $c->param('destination');
    my $rows = $destination
        ? $c->app->pg->db->query(
            'SELECT * FROM domainadmin.mail_aliases WHERE destination = ? ORDER BY source_pattern',
            $destination,
          )->hashes->to_array
        : $c->app->pg->db->query(
            'SELECT * FROM domainadmin.mail_aliases ORDER BY source_pattern',
          )->hashes->to_array;
    return $c->render(json => $rows);
}

# POST /internal/v1/domains/mail-aliases {source_pattern, destination, send_enabled?}
# Auto-creates the backing domainadmin.domains row (mail_enabled=false,
# dns_managed=true) if the domain named by source_pattern doesn't exist
# yet -- one command instead of a separate `dns domains add --no-mail`
# step first (see README.md's "Multi-domain send-as" section). DKIM
# rotation only needs the domain ROW to exist (no dependency on
# mail_enabled), so this doesn't block DKIM setup, it just doesn't
# force it either -- that stays a deliberately separate, later step.
# dns_managed=true means a real PowerDNS zone is expected to exist
# (DKIM rotation publishes its TXT record into it) -- so, same as
# Domains::create, this actually creates the zone too, not just the
# DB row claiming one exists. A real bug caught by the actual e2e
# verification flow, not by inspection: an earlier version of this set
# dns_managed=true without ever calling create_zone, so DKIM rotation
# 404'd trying to PATCH a zone PowerDNS had never heard of.
sub create ($c) {
    my $email = $c->authenticated_email or return;
    my $body = $c->req->json // {};
    my ($source_pattern, $destination) = @{$body}{qw(source_pattern destination)};
    return $c->render(json => { error => 'source_pattern and destination are required' }, status => 400)
        unless $source_pattern && $destination;

    my ($domain_name) = $source_pattern =~ /\@(.+)$/;
    return $c->render(json => { error => 'source_pattern must contain a domain (e.g. "@forge.name" or "sales@forge.name")' }, status => 400)
        unless $domain_name;

    my $send_enabled = exists $body->{send_enabled} ? ($body->{send_enabled} ? 1 : 0) : 1;

    my $existing_domain = $c->app->pg->db->query('SELECT id FROM domainadmin.domains WHERE domain_name = ?', $domain_name)->hash;
    unless ($existing_domain) {
        my $zone_created = 0;
        eval {
            unless ($c->app->powerdns->zone_exists($domain_name)) {
                $c->app->powerdns->create_zone($domain_name);
                $zone_created = 1;
            }
        };
        if ($@) {
            return $c->render(json => { error => "DNS zone creation failed: $@" }, status => 502);
        }
        $c->mark_pending_restart("new zone: $domain_name") if $zone_created;

        $c->app->pg->db->query(
            'INSERT INTO domainadmin.domains (domain_name, mail_enabled, dns_managed, created_by) VALUES (?, false, true, ?)',
            $domain_name, $email,
        );
    }

    my $row = $c->app->pg->db->query(
        q{INSERT INTO domainadmin.mail_aliases (source_pattern, destination, send_enabled, created_by)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (source_pattern) DO UPDATE
              SET destination = EXCLUDED.destination, send_enabled = EXCLUDED.send_enabled, updated_at = NOW()
          RETURNING *},
        $source_pattern, $destination, $send_enabled, $email,
    )->hash;
    # actor is whoever's making this API call; affected_user is the
    # GRANT'S DESTINATION -- a site_admin routing mail for someone else
    # is exactly the admin-on-behalf-of-another-account case
    # affected_user exists for, so ?affecting=<destination> surfaces
    # this grant even though the destination user never acted themselves.
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $destination,
        jti => $c->stash('current_jti'), action => 'mail_alias.create',
        resource_type => 'mail_alias', resource_id => $source_pattern, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { destination => $destination, send_enabled => ($send_enabled ? \1 : \0) },
    );
    return $c->render(json => $row, status => 201);
}

# PATCH /internal/v1/domains/mail-aliases/:source_pattern {send_enabled}
# The suspend/restore toggle -- deliberately does NOT touch `active`
# (inbound routing), see README.md for why this has to be a separate
# flag from the one governing whether the alias exists at all.
sub update ($c) {
    my $email = $c->authenticated_email or return;
    my $body = $c->req->json // {};
    return $c->render(json => { error => 'send_enabled is required' }, status => 400)
        unless exists $body->{send_enabled};

    my $send_enabled = $body->{send_enabled} ? 1 : 0;
    my $row = $c->app->pg->db->query(
        'UPDATE domainadmin.mail_aliases SET send_enabled = ?, updated_at = NOW() WHERE source_pattern = ? RETURNING *',
        $send_enabled, $c->stash('source_pattern'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $row->{destination},
        jti => $c->stash('current_jti'),
        action => ($send_enabled ? 'mail_alias.enable_send' : 'mail_alias.disable_send'),
        resource_type => 'mail_alias', resource_id => $c->stash('source_pattern'),
        source_service => 'homelab-domain-admin', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent,
    );
    return $c->render(json => $row);
}

# DELETE /internal/v1/domains/mail-aliases/:source_pattern -- full
# revocation (stops both inbound routing and outbound authorization).
# Use the PATCH toggle above instead for a temporary suspension.
sub delete_entry ($c) {
    my $email = $c->authenticated_email or return;
    my $row = $c->app->pg->db->query(
        'DELETE FROM domainadmin.mail_aliases WHERE source_pattern = ? RETURNING *',
        $c->stash('source_pattern'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $row->{destination},
        jti => $c->stash('current_jti'), action => 'mail_alias.remove',
        resource_type => 'mail_alias', resource_id => $c->stash('source_pattern'),
        source_service => 'homelab-domain-admin', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent,
    );
    return $c->render(json => { ok => \1 });
}

# GET /internal/v1/domains/mail-aliases/mine -- self-service, JWT-auth
# only (authenticated_email_any, no site_admin requirement -- the one
# exception in this controller/service, see App.pm). Returns what the
# CALLER (never anyone else) is authorized to send as and receive at,
# split into `send` (active AND send_enabled) and `receive_only`
# (active but send_enabled=false -- e.g. suspended for non-payment) so
# a user can see WHY a send might be rejected, not just that it was.
# The caller's own address is always included in send.addresses --
# reaching this endpoint at all already proves it's a real, active
# api.users row.
sub mine ($c) {
    my $email = $c->authenticated_email_any or return;

    my $send_rows = $c->app->pg->db->query(
        q{SELECT source_pattern FROM domainadmin.mail_aliases
          WHERE destination = ? AND active = true AND send_enabled = true ORDER BY source_pattern},
        $email,
    )->hashes->to_array;
    my $receive_only_rows = $c->app->pg->db->query(
        q{SELECT source_pattern FROM domainadmin.mail_aliases
          WHERE destination = ? AND active = true AND send_enabled = false ORDER BY source_pattern},
        $email,
    )->hashes->to_array;

    my $send = _split_patterns($send_rows);
    unshift @{ $send->{addresses} }, $email;
    my $receive_only = _split_patterns($receive_only_rows);

    return $c->render(json => { send => $send, receive_only => $receive_only });
}

# ===== Domain catch-all routing ("all mail for a domain -> one mailbox") =====
# A catch-all IS just a mail_aliases row with source_pattern='@<domain>'
# (Postfix's virtual_alias_maps resolves it natively via its exact-then-
# @domain fallback -- no app-side wildcard). These handlers wrap that with
# the INBOUND-forwarding semantics the send-as create() path above does NOT
# provide: the backing domainadmin.domains row must be mail_enabled=true (the
# SOLE Postfix acceptance gate -- there is no virtual_alias_domains in this
# deployment), whereas create() deliberately sets it false for send-as-only
# domains. Destination existence (a real, active api.users mailbox) is
# validated in the accountmanage BFF before it calls these -- this service's
# DB role has no grant on the api schema, by design.

# GET /internal/v1/domains/catch-alls -- every managed domain + its current
# catch-all destination (null if none) + whether inbound mail is enabled.
# Drives the admin "search a domain" + "view all domains" (bulk) UI.
sub list_catchalls ($c) {
    $c->authenticated_email or return;
    my $rows = $c->app->pg->db->query(
        q{SELECT d.domain_name AS domain, d.mail_enabled, d.active,
                 a.destination, a.active AS catchall_active
            FROM domainadmin.domains d
            LEFT JOIN domainadmin.mail_aliases a
              ON a.source_pattern = '@' || d.domain_name
           ORDER BY d.domain_name}
    )->hashes->to_array;
    return $c->render(json => $rows);
}

# GET /internal/v1/domains/:domain/catch-all -- one domain's catch-all.
sub get_catchall ($c) {
    $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    my $row = $c->app->pg->db->query(
        q{SELECT d.domain_name AS domain, d.mail_enabled, d.active,
                 a.destination, a.active AS catchall_active
            FROM domainadmin.domains d
            LEFT JOIN domainadmin.mail_aliases a
              ON a.source_pattern = '@' || d.domain_name
           WHERE d.domain_name = ?}, $domain,
    )->hash;
    return $c->render(json => { %$row, managed => \1 }) if $row;
    # Unmanaged domain -- report it so the UI can still offer to set (which
    # creates + mail-enables it). destination null => "no catch-all".
    return $c->render(json => { domain => $domain, managed => \0, mail_enabled => \0, active => \0, destination => undef });
}

# PUT /internal/v1/domains/:domain/catch-all {destination}
# Upserts the '@domain' catch-all AND ensures the domain accepts inbound mail.
sub set_catchall ($c) {
    my $email = $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    my $body = $c->req->json // {};
    my $destination = $body->{destination};
    return $c->render(json => { error => 'destination is required (a real mailbox, e.g. user@base-domain)' }, status => 400)
        unless $destination && $destination =~ /\@/;
    my ($dest_domain) = $destination =~ /\@(.+)$/;
    # A catch-all whose destination is at the SAME domain always loops: the
    # rewritten target re-matches the '@domain' catch-all and is rewritten
    # again. Refuse it (unlike an exact alias, which Postfix stops on identity).
    return $c->render(json => { error => 'destination must not be at the same domain as the catch-all (it would loop)' }, status => 400)
        if lc($dest_domain // '') eq lc($domain);
    # Loop guard: refuse a destination that is itself an active alias source.
    my $dest_is_source = $c->app->pg->db->query(
        'SELECT 1 FROM domainadmin.mail_aliases WHERE source_pattern = ? AND active = true LIMIT 1', $destination,
    )->hash;
    return $c->render(json => { error => 'destination is itself a mail-alias source (it would loop)' }, status => 409)
        if $dest_is_source;

    my $source_pattern = '@' . $domain;
    # Ensure the domain is managed + mail-accepting (the inbound gate). New
    # domains are created dns_managed=false: a catch-all/forward domain's MX
    # is pointed here externally, so we do NOT auto-create a PowerDNS zone for
    # a domain we may not host DNS for (unlike the send-as create() path).
    my $existing = $c->app->pg->db->query('SELECT id FROM domainadmin.domains WHERE domain_name = ?', $domain)->hash;
    if ($existing) {
        $c->app->pg->db->query('UPDATE domainadmin.domains SET mail_enabled = true, active = true, updated_at = NOW() WHERE domain_name = ?', $domain);
    } else {
        $c->app->pg->db->query(
            'INSERT INTO domainadmin.domains (domain_name, mail_enabled, dns_managed, active, created_by) VALUES (?, true, false, true, ?)',
            $domain, $email);
    }
    my $row = $c->app->pg->db->query(
        q{INSERT INTO domainadmin.mail_aliases (source_pattern, destination, active, send_enabled, created_by)
          VALUES (?, ?, true, false, ?)
          ON CONFLICT (source_pattern) DO UPDATE
              SET destination = EXCLUDED.destination, active = true, updated_at = NOW()
          RETURNING *}, $source_pattern, $destination, $email,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $destination,
        jti => $c->stash('current_jti'), action => 'mail_alias.set_catchall',
        resource_type => 'mail_alias', resource_id => $source_pattern, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { domain => $domain, destination => $destination },
    );
    return $c->render(json => { ok => \1, domain => $domain, destination => $destination, mail_enabled => \1 });
}

# DELETE /internal/v1/domains/:domain/catch-all -- remove the catch-all
# (leaves the domain row + mail_enabled as-is; disable mail separately if
# the whole domain should stop accepting).
sub clear_catchall ($c) {
    my $email = $c->authenticated_email or return;
    my $domain = $c->stash('domain');
    my $row = $c->app->pg->db->query(
        'DELETE FROM domainadmin.mail_aliases WHERE source_pattern = ? RETURNING *', '@' . $domain,
    )->hash;
    return $c->render(json => { error => 'no catch-all set for this domain' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $row->{destination},
        jti => $c->stash('current_jti'), action => 'mail_alias.clear_catchall',
        resource_type => 'mail_alias', resource_id => '@' . $domain, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
    );
    return $c->render(json => { ok => \1, domain => $domain });
}

# Splits a list of {source_pattern => ...} rows into {addresses =>
# [...], domains => [...]} -- a catch-all row ('@forge.name') becomes a
# domain entry, anything else (an exact address) becomes an address
# entry.
sub _split_patterns ($rows) {
    my (@addresses, @domains);
    for my $row (@$rows) {
        my $pattern = $row->{source_pattern};
        if ($pattern =~ /^\@/) {
            push @domains, $pattern;
        } else {
            push @addresses, $pattern;
        }
    }
    return { addresses => \@addresses, domains => \@domains };
}

1;
