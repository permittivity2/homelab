package Homelab::Audit::App::Controller::Audit;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON qw(decode_json);

# GET /internal/v1/audit/log?user=<email>&affecting=<email>&since=<ts>&until=<ts>&action=<name>
#
# Two independent filters, answering the two things this trail exists
# for:
#   ?user=      -- filters on actor_email: "what did THIS ACCOUNT do"
#                  (self-troubleshooting/support).
#   ?affecting= -- filters on affected_user: "everything that touched
#                  THIS ACCOUNT," including admin actions performed ON
#                  it (role grants, session revokes, mail-alias grants
#                  routed to it) -- the incident-response case: a
#                  compromised account's OWN actions already show up
#                  under ?user=, but an admin's actions on that account
#                  only show up under ?affecting=.
# Both are self-scoped by default: a caller with no audit.view
# capability can only ever see their own email on either filter,
# regardless of what they pass -- same "clean 403, never a silently-
# narrowed result" convention as every other admin-visibility split
# this session (mail-aliases' ?destination=, sessions' ?user=). A
# caller WITH the capability (site_admin always has it) may query any
# user on either filter, or omit both entirely for everyone.
sub list ($c) {
    my ($email, $has_capability) = $c->authenticated_email_any or return;

    my $requested_actor    = $c->param('user');
    my $requested_affected = $c->param('affecting');
    for my $requested ($requested_actor, $requested_affected) {
        if (defined $requested && $requested ne $email && !$has_capability) {
            return $c->render(json => { error => 'audit.view capability required to query another user' }, status => 403);
        }
    }

    my @where;
    my @bind;
    if ($has_capability) {
        if (defined $requested_actor) {
            push @where, 'e.actor_email = ?';
            push @bind, $requested_actor;
        }
        if (defined $requested_affected) {
            push @where, 'e.affected_user = ?';
            push @bind, $requested_affected;
        }
    }
    else {
        # No capability: force both filters to the caller's own email
        # whenever either was actually requested, so `?user=me` and
        # `?affecting=me` both work (and combine) exactly like a
        # capability holder's would, just pinned to one identity. If
        # neither was requested at all, default to "my own actions" --
        # the more common of the two questions for a non-privileged
        # caller.
        if (defined $requested_actor || defined $requested_affected) {
            push(@where, 'e.actor_email = ?'),    push(@bind, $email) if defined $requested_actor;
            push(@where, 'e.affected_user = ?'), push(@bind, $email) if defined $requested_affected;
        }
        else {
            push @where, 'e.actor_email = ?';
            push @bind, $email;
        }
    }

    if (my $since = $c->param('since')) {
        push @where, 'e.occurred_at >= ?';
        push @bind, $since;
    }
    if (my $until = $c->param('until')) {
        push @where, 'e.occurred_at <= ?';
        push @bind, $until;
    }
    if (my $action = $c->param('action')) {
        push @where, 'at.name = ?';
        push @bind, $action;
    }

    my $where_sql = @where ? ('WHERE ' . join(' AND ', @where)) : '';
    my $rows = $c->app->pg->db->query(
        qq{SELECT e.id, e.occurred_at, e.actor_email, e.affected_user, e.jti, at.name AS action,
                  rt.name AS resource_type, e.resource_id, e.source_service,
                  e.ip_address, e.user_agent, e.detail
           FROM audit.entries e
           JOIN audit.action_types at ON at.id = e.action_type_id
           LEFT JOIN audit.resource_types rt ON rt.id = e.resource_type_id
           $where_sql
           ORDER BY e.occurred_at DESC, e.id DESC
           LIMIT 500},
        @bind,
    )->hashes->to_array;
    # Mojo::Pg's automatic {json => ...} encoding on the way IN has no
    # symmetric automatic decode on the way OUT -- ->hashes returns the
    # raw JSONB text representation as a plain Perl string, which
    # $c->render(json => ...) would then re-encode as a JSON *string*
    # value (e.g. "{\"filename\":...}") instead of a nested object,
    # breaking any caller that expects to navigate into it. Confirmed
    # by an actual failing JSON Pointer assertion against a real row,
    # not just by reading Mojo::Pg's docs.
    for my $row (@$rows) {
        $row->{detail} = decode_json($row->{detail}) if defined $row->{detail};
    }

    return $c->render(json => $rows);
}

1;
