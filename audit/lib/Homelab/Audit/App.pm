package Homelab::Audit::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::JSON qw(encode_json);

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Common::AuthClient qw(introspect);

has 'pg';
has 'api_base';

sub startup ($self) {
    my $config = load_config('HOMELAB_AUDIT_CONFIG', '/etc/homelab/audit/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2513'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/audit-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-audit',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    # Self-scoped-by-default auth helper, mirroring homelab-domain-
    # admin's authenticated_email_any exactly, extended to also surface
    # the audit.view capability (see api/migrations/008-role-
    # permissions.sql and _introspect's ?capability= extension) --
    # homelab-audit has no in-process way to check role_permissions
    # itself (those tables live only in homelab-api's own schema), so
    # this is a remote introspect call, same as every other "who is
    # this" check in this ecosystem. Returns an EMPTY LIST (not
    # (undef, undef)) on failure so `my (...) = $c->authenticated_
    # email_any or return;` actually short-circuits -- a 2-element list
    # of undefs would count as 2 in scalar context and defeat `or return`.
    $self->helper(authenticated_email_any => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) {
            $c->render(json => { error => 'not logged in' }, status => 401);
            return ();
        }
        my $result = introspect($jwt, api_base => $self->api_base, capability => 'audit.view');
        unless ($result) {
            $c->render(json => { error => 'not logged in' }, status => 401);
            return ();
        }
        return ($result->{email}, $result->{has_capability} ? 1 : 0, $result->{jti});
    });

    my $r = $self->routes;
    $r->get('/internal/v1/audit/log') ->to('audit#list');

    # Single timer: drain a batch of audit.queue into audit.entries.
    # Same recurring-timer + FOR UPDATE SKIP LOCKED claim idiom as
    # homelab-worker's job claim and homelab-domain-admin's DKIM/
    # PowerDNS timers -- this service never sits on the write path (see
    # README.md), it only ever consumes.
    #
    # Deliberately does NOT also manage partitions here (an earlier
    # version of this timer tried to `CREATE TABLE ... PARTITION OF`
    # on every tick) -- that's DDL, and this app's own `pg` handle is
    # the RUNTIME role, which by this project's own split-role design
    # never holds DDL privileges (see homelab-bootstrap-app-role's own
    # comment). Partitions are pre-created 24 months ahead by migration
    # instead (migrations/002-more-partitions.sql), which runs as the
    # DDL-capable migrate role at install/upgrade time. Caught for real
    # ("permission denied for schema audit" from the live service), not
    # by inspection.
    Mojo::IOLoop->recurring(5 => sub {
        $self->_drain_queue;
    });

    return;
}


# Claims a batch of queued rows (SKIP LOCKED -- safe under a multi-
# worker hypnotoad, same as every other claim timer in this codebase),
# normalizes each payload's free-text action/resource_type into
# action_type_id/resource_type_id (find-or-create, race-safe via
# ON CONFLICT DO NOTHING + a follow-up SELECT), inserts into
# audit.entries, then deletes the processed queue rows. A malformed
# payload fails that ONE row loudly into the log rather than wedging
# the whole batch -- still deleted from the queue either way, since
# retrying a payload that will never parse is pointless.
sub _drain_queue ($self) {
    my $db  = $self->pg->db;
    my $tx  = $db->begin;
    my $rows = $db->query(
        q{SELECT id, payload FROM audit.queue ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 100},
    )->expand->hashes->to_array;
    return unless @$rows;

    my @done_ids;
    for my $row (@$rows) {
        my $p = $row->{payload};
        # Per-row SAVEPOINT, not just a Perl eval{} -- a failed INSERT
        # aborts the surrounding Postgres transaction outright (any
        # further statement on it errors with "current transaction is
        # aborted" until a ROLLBACK), which would silently kill every
        # OTHER row still left in this batch, including the final
        # DELETE. The savepoint isolates one row's failure without
        # losing the FOR UPDATE SKIP LOCKED claim this whole batch holds.
        $db->query('SAVEPOINT audit_row');
        my $ok = eval {
            my $action_type_id   = $self->_find_or_create_id('action_types', $p->{action});
            my $resource_type_id = defined $p->{resource_type}
                ? $self->_find_or_create_id('resource_types', $p->{resource_type}) : undef;
            $db->query(
                q{INSERT INTO audit.entries
                    (occurred_at, user_email, jti, action_type_id, resource_type_id,
                     resource_id, source_service, ip_address, user_agent, detail)
                  VALUES (COALESCE(?::timestamptz, NOW()), ?, ?, ?, ?, ?, ?, ?, ?, ?)},
                $p->{occurred_at}, $p->{user_email}, $p->{jti}, $action_type_id, $resource_type_id,
                $p->{resource_id}, $p->{source_service}, $p->{ip_address}, $p->{user_agent},
                $p->{detail} ? { json => $p->{detail} } : undef,
            );
            1;
        };
        if ($ok) {
            $db->query('RELEASE SAVEPOINT audit_row');
        }
        else {
            $db->query('ROLLBACK TO SAVEPOINT audit_row');
            $self->log->error("audit queue row $row->{id} failed to normalize/insert: $@ (payload: " . encode_json($p) . ')');
        }
        # Still removed from the queue either way -- a payload that
        # can't parse today will never parse on a later retry either,
        # so leaving it queued forever would just accumulate dead rows.
        push @done_ids, $row->{id};
    }
    if (@done_ids) {
        my $placeholders = join(',', ('?') x scalar @done_ids);
        $db->query("DELETE FROM audit.queue WHERE id IN ($placeholders)", @done_ids);
    }
    $tx->commit;
    return;
}

sub _find_or_create_id ($self, $table, $name) {
    die "missing name for $table lookup\n" unless defined $name && length $name;
    my $db = $self->pg->db;
    $db->query(qq{INSERT INTO audit.$table (name) VALUES (?) ON CONFLICT (name) DO NOTHING}, $name);
    return $db->query(qq{SELECT id FROM audit.$table WHERE name = ?}, $name)->hash->{id};
}

1;
