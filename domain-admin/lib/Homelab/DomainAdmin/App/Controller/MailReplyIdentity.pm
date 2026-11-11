package Homelab::DomainAdmin::App::Controller::MailReplyIdentity;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AuditClient qw(enqueue);

# Post-cutover #67: the per-user "reply from the alias a message was sent
# to" switch (domainadmin.mail_reply_identity, migration 009). Self-service
# only -- a user may read and set their OWN row and nobody else's, the same
# JWT-only tier MailAliases::mine established (authenticated_email_any, no
# site_admin). Reached as GET/PUT /api/v1/domains/mail-reply-identity/mine
# through homelab-api's existing /api/v1/domains/* gateway; myaccount's
# Mail section and `homelab-cli mail reply-from-alias` are the clients.
#
# What the switch does is NOT implemented here: the homelab-postfix-block-
# link milter on the mail pool reads this table on every authenticated
# submission (587) and, when the switch is on and the reply's In-Reply-To
# names a message it recorded in domainadmin.mail_received_via, swaps the
# reply's From/envelope sender to the alias the original was sent to --
# after re-checking the user may still send as it (mail_aliases
# send_enabled). See that package's README, "Reply from the alias".

sub _state ($c, $email) {
    my $row = $c->app->pg->db->query(
        'SELECT reply_from_alias, updated_at FROM domainadmin.mail_reply_identity WHERE user_email = ?', $email,
    )->hash;
    return {
        reply_from_alias => ($row && $row->{reply_from_alias}) ? \1 : \0,
        updated_at       => $row ? $row->{updated_at} : undef,
    };
}

# GET /internal/v1/domains/mail-reply-identity/mine
sub mine ($c) {
    my $email = $c->authenticated_email_any or return;
    return $c->render(json => _state($c, $email));
}

# PUT /internal/v1/domains/mail-reply-identity/mine {reply_from_alias: true|false}
sub set_mine ($c) {
    my $email = $c->authenticated_email_any or return;
    my $body = $c->req->json // {};
    return $c->render(json => { error => 'reply_from_alias is required (true or false)' }, status => 400)
        unless exists $body->{reply_from_alias} && defined $body->{reply_from_alias};
    my $on = $body->{reply_from_alias} ? 1 : 0;

    $c->app->pg->db->query(
        q{INSERT INTO domainadmin.mail_reply_identity (user_email, reply_from_alias) VALUES (?, ?)
          ON CONFLICT (user_email) DO UPDATE SET reply_from_alias = EXCLUDED.reply_from_alias, updated_at = NOW()},
        $email, $on,
    );
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => ($on ? 'mail_reply_identity.enable' : 'mail_reply_identity.disable'),
        resource_type => 'mail_reply_identity', resource_id => $email,
        source_service => 'homelab-domain-admin', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { reply_from_alias => ($on ? \1 : \0) },
    );
    return $c->render(json => _state($c, $email));
}

1;
