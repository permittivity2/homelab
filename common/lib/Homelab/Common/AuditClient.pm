package Homelab::Common::AuditClient;
use Mojo::Base -strict;
use Exporter 'import';

our @EXPORT_OK = qw(enqueue);

# Writes ONE audit event -- not an HTTP client despite living alongside
# AuthClient/SSOClient in this shared module. Every homelab-* service
# already holds a direct Postgres connection to the one shared `homelab`
# database (via pgbouncer); this is a plain, synchronous, local
# INSERT INTO audit.queue using that SAME connection (a narrow, INSERT-
# only grant -- see each producing service's postinst for the new
# `GRANT INSERT ON audit.queue` line). homelab-audit's own recurring
# timer drains the queue asynchronously into the real, normalized,
# partitioned audit.entries fact table -- see homelab-audit/README.md.
#
# Deliberately no eval/best-effort wrapper in here: if this INSERT
# fails (permission denied, audit.queue doesn't exist yet because
# homelab-audit isn't installed, the DB is down), the exception
# propagates to the caller. That is the whole point of this design --
# audit durability is tied to "is Postgres up" (already a hard
# dependency for every mutating action in this ecosystem), not "is a
# separate service up." Callers that want atomicity with their own
# mutation should pass the SAME transaction handle they're already
# using for it.
#
# enqueue($db, user_email => ..., action => 'file.delete', resource_type => 'drive.file',
#         resource_id => $id, jti => $jti, source_service => 'homelab-drive',
#         ip_address => ..., user_agent => ..., detail => { ... })
#
# %fields required: user_email, action, source_service. Everything else
# is optional (jti/resource_type/resource_id/ip_address/user_agent/
# detail/occurred_at) -- a system-initiated entry has no jti, a bare
# action might have no specific resource, etc.
sub enqueue {
    my ($db, %fields) = @_;
    die "AuditClient::enqueue(): db handle required\n" unless $db;
    for my $required (qw(user_email action source_service)) {
        die "AuditClient::enqueue(): $required is required\n" unless defined $fields{$required} && length $fields{$required};
    }

    my %payload = map { $_ => $fields{$_} } grep { defined $fields{$_} } qw(
        user_email jti action resource_type resource_id source_service
        ip_address user_agent detail occurred_at
    );

    $db->query(
        q{INSERT INTO audit.queue (payload) VALUES (?)},
        { json => \%payload },
    );
    return 1;
}

1;
