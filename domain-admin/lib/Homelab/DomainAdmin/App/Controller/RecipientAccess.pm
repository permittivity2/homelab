package Homelab::DomainAdmin::App::Controller::RecipientAccess;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AuditClient qw(enqueue);

# Postfix's own action vocabulary is free text (REJECT/OK/DISCARD/DEFER/
# a literal "550 ..." string -- see 003-recipient-access.sql), but the
# audit trail wants a small, stable action_type catalog rather than one
# row per distinct string ever typed. 'OK' is the only real "allow"
# value either CLI tier ever sends (dns_set_recipient_access via
# recipient-access allow); anything else reads as block-shaped for
# audit purposes, same as it does for Postfix's own enforcement.
sub _recipient_access_action_name ($action) {
    return (uc($action // '') eq 'OK') ? 'recipient_access.allow' : 'recipient_access.block';
}

# GET /internal/v1/domains/recipient-access[?user=<email>]
# Site_admin-only, unchanged -- ?user= is new: support/troubleshooting
# visibility into one specific user's self-service blocks (same shape
# as MailAliases::list's own ?destination= filter). Read-only: a
# site_admin can SEE another user's blocks this way, but there is no
# route letting them create/remove on that user's behalf -- same
# "admin can see, not silently override a personal choice" line
# already drawn for mail_aliases sender permissions.
sub list ($c) {
    $c->authenticated_email or return;
    my $user = $c->param('user');
    my $rows = $user
        ? $c->app->pg->db->query(
            'SELECT * FROM domainadmin.recipient_access WHERE user_email = ? ORDER BY recipient',
            $user,
          )->hashes->to_array
        : $c->app->pg->db->query(
            'SELECT * FROM domainadmin.recipient_access ORDER BY recipient',
          )->hashes->to_array;
    return $c->render(json => $rows);
}

# POST /internal/v1/domains/recipient-access {recipient, action, reason?}
# Upsert, not insert-only -- re-blocking (or re-allowing) an address
# already in the table should update it in place, not 409.
sub upsert ($c) {
    my $email = $c->authenticated_email or return;
    my $body = $c->req->json // {};
    my ($recipient, $action) = @{$body}{qw(recipient action)};
    return $c->render(json => { error => 'recipient and action are required' }, status => 400)
        unless $recipient && $action;

    my $row = $c->app->pg->db->query(
        q{INSERT INTO domainadmin.recipient_access (recipient, action, reason, created_by)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (recipient) DO UPDATE
              SET action = EXCLUDED.action, reason = EXCLUDED.reason, updated_at = NOW()
          RETURNING *},
        $recipient, $action, $body->{reason}, $email,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => _recipient_access_action_name($action), resource_type => 'recipient_access',
        resource_id => $recipient, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { tier => 'admin', action => $action, reason => $body->{reason} },
    );
    return $c->render(json => $row, status => 201);
}

# DELETE /internal/v1/domains/recipient-access/:recipient
sub delete_entry ($c) {
    my $email = $c->authenticated_email or return;
    my $row = $c->app->pg->db->query(
        'DELETE FROM domainadmin.recipient_access WHERE recipient = ? RETURNING *',
        $c->stash('recipient'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => 'recipient_access.remove', resource_type => 'recipient_access',
        resource_id => $c->stash('recipient'), source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { tier => 'admin' },
    );
    return $c->render(json => { ok => \1 });
}

# True if $recipient is an address $email actually owns: their own
# login address, or covered by a domainadmin.mail_aliases grant where
# destination = $email (either an exact-address grant, or a catch-all
# '@domain' grant whose domain matches $recipient's). Same resolution
# MailAliases::mine already computes for the /mine listing, just
# collapsed into a single boolean instead of a full address/domain
# list -- reused rather than reinvented.
sub _owns_recipient ($c, $email, $recipient) {
    return 1 if lc($recipient) eq lc($email);
    my $row = $c->app->pg->db->query(
        q{SELECT 1 FROM domainadmin.mail_aliases
          WHERE destination = ? AND active = true
            AND (source_pattern = ? OR (source_pattern LIKE '@%' AND ? LIKE '%' || source_pattern))
          LIMIT 1},
        $email, $recipient, $recipient,
    )->hash;
    return $row ? 1 : 0;
}

# True if blocking $recipient would burn one of $email's own addresses
# outright: their own login address, or an *exact* (non-catch-all)
# mail_aliases grant that routes to them. Deliberately does NOT reject
# a catch-all domain grant they own ('@forge.name') -- there's no
# single address at risk there, only a specific address under it,
# which this same check independently catches when THAT address is
# the one actually being blocked.
sub _is_own_exact_address ($c, $email, $recipient) {
    return 1 if lc($recipient) eq lc($email);
    my $row = $c->app->pg->db->query(
        'SELECT 1 FROM domainadmin.mail_aliases WHERE destination = ? AND source_pattern = ? LIMIT 1',
        $email, $recipient,
    )->hash;
    return $row ? 1 : 0;
}

# POST /internal/v1/domains/recipient-access/mine {recipient, action, reason?}
# Self-service, JWT-auth only (authenticated_email_any, no site_admin
# requirement -- same tier as MailAliases::mine). Two guards run before
# the upsert, both hard rejections, not warnings: ownership (can only
# ever touch an address the caller actually owns -- see _owns_recipient)
# and self-block (can never burn one of the caller's OWN addresses --
# see _is_own_exact_address). The second guard exists because
# recipient-access is blanket: it rejects mail from EVERY sender, so
# blocking your own login address would permanently cut you off from
# all mail there, including anything account/security-related.
sub create_mine ($c) {
    my $email = $c->authenticated_email_any or return;
    my $body = $c->req->json // {};
    my ($recipient, $action) = @{$body}{qw(recipient action)};
    return $c->render(json => { error => 'recipient and action are required' }, status => 400)
        unless $recipient && $action;

    return $c->render(json => { error => "you can only block/allow an address you own -- see 'mail allowed-senders'" }, status => 403)
        unless _owns_recipient($c, $email, $recipient);

    return $c->render(json => { error => 'cannot block/allow your own account address -- this would cut off ALL mail to it, including account-related mail' }, status => 400)
        if _is_own_exact_address($c, $email, $recipient);

    my $row = $c->app->pg->db->query(
        q{INSERT INTO domainadmin.recipient_access (recipient, action, reason, created_by, user_email)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (recipient) DO UPDATE
              SET action = EXCLUDED.action, reason = EXCLUDED.reason,
                  user_email = EXCLUDED.user_email, updated_at = NOW()
          RETURNING *},
        $recipient, $action, $body->{reason}, $email, $email,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => _recipient_access_action_name($action), resource_type => 'recipient_access',
        resource_id => $recipient, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { tier => 'self_service', action => $action, reason => $body->{reason} },
    );
    return $c->render(json => $row, status => 201);
}

# GET /internal/v1/domains/recipient-access/mine[?q=<substring>]
# Self-service list, scoped strictly to the caller's own rows --
# server-side substring search on `recipient`, an improvement on
# production's client-side-only JS regex filter (irrelevant once
# there's no rendered page to filter in place, as with a CLI).
sub list_mine ($c) {
    my $email = $c->authenticated_email_any or return;
    my $q = $c->param('q');
    my $rows = defined($q) && length($q)
        ? $c->app->pg->db->query(
            'SELECT * FROM domainadmin.recipient_access WHERE user_email = ? AND recipient ILIKE ? ORDER BY recipient',
            $email, '%' . $q . '%',
          )->hashes->to_array
        : $c->app->pg->db->query(
            'SELECT * FROM domainadmin.recipient_access WHERE user_email = ? ORDER BY recipient',
            $email,
          )->hashes->to_array;
    return $c->render(json => $rows);
}

# DELETE /internal/v1/domains/recipient-access/mine/:recipient --
# scoped to `user_email = caller` in the WHERE clause itself, not just
# checked after the fact: this can only ever remove a row the caller
# themselves created, never another user's or an admin/global (NULL
# user_email) entry, even if they already know the exact recipient
# string.
sub delete_mine ($c) {
    my $email = $c->authenticated_email_any or return;
    my $row = $c->app->pg->db->query(
        'DELETE FROM domainadmin.recipient_access WHERE user_email = ? AND recipient = ? RETURNING *',
        $email, $c->stash('recipient'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => 'recipient_access.remove', resource_type => 'recipient_access',
        resource_id => $c->stash('recipient'), source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { tier => 'self_service' },
    );
    return $c->render(json => { ok => \1 });
}

1;
