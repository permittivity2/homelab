package Homelab::DomainAdmin::App::Controller::RecipientAccess;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# GET /internal/v1/domains/recipient-access
sub list ($c) {
    $c->authenticated_email or return;
    my $rows = $c->app->pg->db->query(
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
    return $c->render(json => $row, status => 201);
}

# DELETE /internal/v1/domains/recipient-access/:recipient
sub delete_entry ($c) {
    $c->authenticated_email or return;
    my $row = $c->app->pg->db->query(
        'DELETE FROM domainadmin.recipient_access WHERE recipient = ? RETURNING *',
        $c->stash('recipient'),
    )->hash;
    return $c->render(json => { error => 'not found' }, status => 404) unless $row;
    return $c->render(json => { ok => \1 });
}

1;
