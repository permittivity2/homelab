package Homelab::Audit::App::Controller::Audit;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON qw(decode_json);
use Homelab::Common::AuditClient qw(enqueue);

# GET /internal/v1/audit/log?user=<email>&since=<ts>&until=<ts>&action=<name>
# Self-scoped by default: a caller with no audit.view capability can
# only ever see their own user_email, regardless of what ?user= they
# pass -- same "clean 403, never a silently-narrowed result" convention
# as every other admin-visibility split this session (mail-aliases'
# ?destination=, sessions' ?user=). A caller WITH the capability
# (site_admin always has it; see App.pm's authenticated_email_any +
# introspect capability check) may query any user, or omit ?user=
# entirely for everyone.
#
# This endpoint logs its OWN reads (see the enqueue() call below) --
# not an oversight, a deliberate design point reached by discussion:
# the whole reason this feature exists is to reconstruct EVERYTHING
# that happened with an account, including a compromised account
# checking its own history, so a self-scoped view is exactly as
# forensically relevant as a cross-user one. No self-vs-cross-user
# exception here.
sub list ($c) {
    my ($email, $has_capability, $jti) = $c->authenticated_email_any or return;

    my $requested_user = $c->param('user');
    if (defined $requested_user && $requested_user ne $email && !$has_capability) {
        return $c->render(json => { error => 'audit.view capability required to query another user' }, status => 403);
    }

    my $since  = $c->param('since');
    my $until  = $c->param('until');
    my $action = $c->param('action');

    my @where;
    my @bind;
    # Also determines what THIS call's own audit entry (below) is keyed
    # on: a single target_email when one is in effect, or undef/'all'
    # when a capability-holder omitted ?user= to see everyone's.
    my $target_email;
    if ($has_capability) {
        if (defined $requested_user) {
            push @where, 'e.user_email = ?';
            push @bind, $requested_user;
            $target_email = $requested_user;
        }
    }
    else {
        push @where, 'e.user_email = ?';
        push @bind, $email;
        $target_email = $email;
    }

    if ($since) {
        push @where, 'e.occurred_at >= ?';
        push @bind, $since;
    }
    if ($until) {
        push @where, 'e.occurred_at <= ?';
        push @bind, $until;
    }
    if ($action) {
        push @where, 'at.name = ?';
        push @bind, $action;
    }

    my $where_sql = @where ? ('WHERE ' . join(' AND ', @where)) : '';
    my $rows = $c->app->pg->db->query(
        qq{SELECT e.id, e.occurred_at, e.user_email, e.jti, at.name AS action,
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

    # This view of the audit log is itself an audited action (see the
    # module comment above). Keyed on the ACCOUNT that was viewed
    # (user_email/resource_id = $target_email), not the viewer -- so
    # that pulling "everything that happened with account X" (?user=X)
    # surfaces "someone looked at X's history" regardless of who that
    # was, which is exactly the point for the compromised-account case
    # this feature exists for. The viewer is never lost, though: `jti`
    # identifies the exact session, and detail.viewed_by names them
    # directly so a human doesn't have to cross-reference a session
    # table just to answer "who looked at my stuff." The all-users case
    # (a capability holder omitting ?user=) has no single account to
    # attribute this to, so it falls back to the viewer themselves --
    # the only sensible choice when there's no target at all.
    my %detail = (viewed_by => $email);
    if (defined $target_email) {
        $detail{queried_as_self} = ($target_email eq $email) ? \1 : \0;
    }
    else {
        $detail{scope} = 'all';
    }
    $detail{since}         = $since  if defined $since;
    $detail{until}         = $until  if defined $until;
    $detail{action_filter} = $action if defined $action;

    enqueue(
        $c->app->pg->db,
        user_email => $target_email // $email,
        action => 'audit.view', resource_type => 'audit_query',
        (defined $target_email ? (resource_id => $target_email) : ()),
        jti => $jti, source_service => 'homelab-audit',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => \%detail,
    );

    return $c->render(json => $rows);
}

1;
