package Homelab::BlockLink::App::Controller::BlockLink;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);
use Homelab::Common::Registry qw(lookup system_agent_token);
use Homelab::Common::AuditClient qw(enqueue);

sub _home_domain ($email) {
    my ($domain) = $email =~ /\@(.+)$/;
    return $domain // '';
}

# Account override wins if set; otherwise the caller's own home
# domain's default; otherwise a hardcoded off/header fallback if
# neither row exists at all (a domain that's never touched this
# feature is off by default, matching domain_settings' own DEFAULT
# FALSE -- this branch only matters before any row has ever been
# written for that domain).
sub _effective_setting ($c, $email) {
    my $account = $c->app->pg->db->query(
        'SELECT enabled FROM block_link.account_settings WHERE user_email = ?', $email,
    )->hash;
    my $domain = $c->app->pg->db->query(
        'SELECT enabled, mode FROM block_link.domain_settings WHERE domain_name = ?', _home_domain($email),
    )->hash // { enabled => 0, mode => 'header' };

    my $enabled = (defined $account && defined $account->{enabled}) ? $account->{enabled} : $domain->{enabled};
    return { enabled => ($enabled ? \1 : \0), mode => $domain->{mode}, domain_default => ($domain->{enabled} ? \1 : \0) };
}

# GET /internal/v1/block-link/account
sub account_show ($c) {
    my $email = $c->authenticated_email_any or return;
    return $c->render(json => _effective_setting($c, $email));
}

# PUT /internal/v1/block-link/account {enabled}
# enabled: true/false sets an explicit override; null clears it back to
# "inherit the domain default".
sub account_set ($c) {
    my $email = $c->authenticated_email_any or return;
    my $body = $c->req->json // {};
    return $c->render(json => { error => 'enabled is required (true, false, or null to clear)' }, status => 400)
        unless exists $body->{enabled};

    $c->app->pg->db->query(
        q{INSERT INTO block_link.account_settings (user_email, enabled) VALUES (?, ?)
          ON CONFLICT (user_email) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = NOW()},
        $email, $body->{enabled},
    );
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => 'block_link.account_set', resource_type => 'block_link_account', resource_id => $email,
        source_service => 'homelab-block-link', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { enabled => $body->{enabled} },
    );
    return $c->render(json => _effective_setting($c, $email));
}

# GET /internal/v1/block-link/domains/:domain -- site_admin-only
sub domain_show ($c) {
    $c->authenticated_site_admin or return;
    my $row = $c->app->pg->db->query(
        'SELECT * FROM block_link.domain_settings WHERE domain_name = ?', $c->stash('domain'),
    )->hash // { domain_name => $c->stash('domain'), enabled => \0, mode => 'header' };
    return $c->render(json => $row);
}

# PUT /internal/v1/block-link/domains/:domain {enabled, mode}
sub domain_set ($c) {
    my $admin = $c->authenticated_site_admin or return;
    my $domain = $c->stash('domain');
    my $body = $c->req->json // {};
    my ($enabled, $mode) = @{$body}{qw(enabled mode)};
    return $c->render(json => { error => 'enabled and mode are required' }, status => 400)
        unless defined($enabled) && $mode;
    return $c->render(json => { error => "mode must be 'header', 'body', or 'both'" }, status => 400)
        unless grep { $_ eq $mode } qw(header body both);

    my $row = $c->app->pg->db->query(
        q{INSERT INTO block_link.domain_settings (domain_name, enabled, mode, updated_by_email)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (domain_name) DO UPDATE
              SET enabled = EXCLUDED.enabled, mode = EXCLUDED.mode,
                  updated_by_email = EXCLUDED.updated_by_email, updated_at = NOW()
          RETURNING *},
        $domain, $enabled, $mode, $admin,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $admin, affected_user => $admin, jti => $c->stash('current_jti'),
        action => 'block_link.domain_set', resource_type => 'block_link_domain', resource_id => $domain,
        source_service => 'homelab-block-link', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { enabled => $enabled, mode => $mode },
    );
    return $c->render(json => $row);
}

# GET /l/:token -- public, unauthenticated. No DB mutation here -- see
# README.md's "Why GET never mutates" section: automated mail-security
# link-prescanners fetch every link in incoming mail before a human opens
# it, and this link lives INSIDE a real delivered email.
#
# Rendered from templates/manage.html.ep on the shared mailmasker layout
# (homelab-webtheme). The renderer escapes every value, which replaces the
# hand-rolled xml_escape() calls the old qq{} page needed.
sub show ($c) {
    my $token = $c->stash('token');
    my $row = $c->app->pg->db->query(
        q{SELECT *, (expires_at <= NOW()) AS is_expired FROM block_link.pending_links WHERE token = ?}, $token,
    )->hash;
    return _notice($c, 404, 'Invalid link', 'This management link is not valid.') unless $row;
    return _notice($c, 410, 'Link expired', 'This management link has expired.') if $row->{is_expired};

    # candidates is a JSONB column -- Mojo::Pg/DBD::Pg hand it back as
    # the raw JSON text, not an inflated arrayref, so it must be
    # decoded explicitly before use (real bug hit on first live GET,
    # not caught by t/basic.t since that test asserts on rendered HTML
    # content, not on this code path directly).
    return $c->render(template => 'manage', candidates => decode_json($row->{candidates}), token => $token);
}

# POST /l/:token {block: [address, ...]} -- public, unauthenticated.
# The token itself IS the authentication for this action -- an
# unguessable 32-byte value, validated server-side against
# pending_links, same trust model as every other capability-token
# design in this ecosystem. Calls homelab-domain-admin's own
# system_agent-gated on-behalf endpoint for each address the visitor
# left checked -- this service never writes domainadmin.recipient_
# access directly (see README.md's architecture note: this is a new
# delivery path into an existing blocking mechanism, not a new one).
sub submit ($c) {
    my $token = $c->stash('token');
    my $row = $c->app->pg->db->query(
        q{SELECT * FROM block_link.pending_links WHERE token = ? AND expires_at > NOW()}, $token,
    )->hash;
    return $c->render(json => { error => 'this link is no longer valid' }, status => 410) unless $row;

    my $body = $c->req->json // {};
    my %checked = map { $_ => 1 } @{ $body->{block} // [] };

    my $domain_admin = lookup('homelab-domain-admin', api_base => $c->app->api_base);
    return $c->render(json => { error => 'domain-admin service is not currently available' }, status => 502)
        unless $domain_admin && $domain_admin->{host} && $domain_admin->{port};

    my $agent_token = eval { system_agent_token() };
    return $c->render(json => { error => 'service credential unavailable' }, status => 502) unless $agent_token;

    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
    my @failed;
    my $candidates = decode_json($row->{candidates});
    for my $cand (@$candidates) {
        next unless $checked{ $cand->{address} };
        my $tx = $ua->post(
            "http://$domain_admin->{host}:$domain_admin->{port}/internal/v1/domains/recipient-access/on-behalf",
            { Authorization => "Bearer $agent_token" },
            json => {
                user_email => $cand->{account_email}, recipient => $cand->{address},
                action => 'REJECT', reason => 'blocked via inbox link',
            },
        );
        push @failed, $cand->{address} if $tx->error;
    }
    return $c->render(json => { error => "could not block: @failed" }, status => 502) if @failed;
    return $c->render(json => { ok => \1, blocked => [keys %checked] });
}

# The "invalid" and "expired" pages, on the same layout as the form.
sub _notice ($c, $status, $heading, $body) {
    return $c->render(template => 'notice', status => $status, heading => $heading, body => $body);
}

1;
