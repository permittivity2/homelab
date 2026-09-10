package Homelab::DomainAdmin::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::DomainAdmin::PowerDNS;

has 'pg';
has 'api_base';
has 'powerdns';

sub startup ($self) {
    my $config = load_config('HOMELAB_DOMAIN_ADMIN_CONFIG', '/etc/homelab/domain-admin/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2511'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/domain-admin-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");

    my $pdns_cfg = $config->{powerdns} // die "config: powerdns.* is required (see config/domain-admin.example.yml)\n";
    # die(...) MUST be parenthesized here: bare `die "msg"` is a
    # low-precedence list operator that otherwise swallows every
    # subsequent comma-separated argument in this ->new(...) call as
    # ITS OWN (never-evaluated, since // already short-circuited)
    # argument list -- silently dropping api_key from the constructor
    # entirely rather than raising the intended error. Caught by a real
    # `homelab-cli dns domains add` call failing PowerDNS auth with a
    # genuinely blank API key, not by inspection -- see README.md.
    $self->powerdns(Homelab::DomainAdmin::PowerDNS->new(
        base_url => $pdns_cfg->{api_base_url} // die("config: powerdns.api_base_url is required\n"),
        api_key  => $pdns_cfg->{api_key} // die("config: powerdns.api_key is required\n"),
    ));

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-domain-admin',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    # Shared per-request auth check -- every route in this service
    # requires a valid, authenticated caller. Role-gating to site_admin
    # specifically is added in a later phase (needs Homelab::Common::
    # AuthClient::introspect's response extended with a `roles` field,
    # a homelab-api-side change tracked separately) -- for now this is
    # the same bar every other backend applies before ITS OWN additional
    # checks, matching this project's "verify at every hop" convention.
    # Renders 401 itself and returns undef on failure, so callers can
    # just do `my $email = $c->authenticated_email or return;`.
    $self->helper(authenticated_email => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) {
            $c->render(json => { error => 'not logged in' }, status => 401);
            return undef;
        }
        my $result = introspect($jwt, api_base => $self->api_base);
        unless ($result) {
            $c->render(json => { error => 'not logged in' }, status => 401);
            return undef;
        }
        return $result->{email};
    });

    # Marks that PowerDNS needs a restart before a just-written zone/
    # record NAME becomes servable (see README.md's "PowerDNS caches its
    # zone list at process start" gotcha) -- a plain upsert on a
    # single-row table, so a burst of writes collapses into one pending
    # restart rather than queuing several.
    $self->helper(mark_pending_restart => sub ($c, $reason) {
        $c->app->pg->db->query(
            q{INSERT INTO domainadmin.pending_restart (id, reason, marked_at) VALUES (TRUE, ?, NOW())
              ON CONFLICT (id) DO UPDATE SET reason = EXCLUDED.reason, marked_at = NOW()},
            $reason,
        );
    });

    # Bare lowercase controller name -- Mojolicious prepends this app's
    # own namespace (Homelab::DomainAdmin::App::Controller::*) itself;
    # spelling the full namespace out here would break resolution (it
    # would try to camelize the WHOLE "App::Controller::Domains" string
    # as one segment). Matches homelab-mailbridge's own '#'-shorthand
    # routes exactly.
    # :domain needs an explicit placeholder regex -- Mojolicious's default
    # placeholder pattern excludes "." (reserved for :name.format-style
    # extension detection, e.g. a route ending in :id matching "5.json"
    # as id=5 format=json), so an unqualified :domain silently truncates
    # any real domain at its first dot ("test.forge.name" -> "test").
    # Caught by a real `homelab-cli dns domains show test.forge.name`
    # call 404ing, not by inspection -- every route below that embeds
    # :domain needs this same [domain => qr/[^\/]+/] override, not just
    # the first one.
    my $r = $self->routes;
    $r->get('/internal/v1/domains')            ->to('domains#list');
    $r->post('/internal/v1/domains')           ->to('domains#create');
    $r->get('/internal/v1/domains/:domain'    => [domain => qr/[^\/]+/])->to('domains#show');
    $r->patch('/internal/v1/domains/:domain'  => [domain => qr/[^\/]+/])->to('domains#update');
    $r->delete('/internal/v1/domains/:domain' => [domain => qr/[^\/]+/])->to('domains#disable');

    $r->get('/internal/v1/domains/:domain/dns/records'    => [domain => qr/[^\/]+/])->to('dns#list_records');
    $r->post('/internal/v1/domains/:domain/dns/records'   => [domain => qr/[^\/]+/])->to('dns#upsert_record');
    $r->delete('/internal/v1/domains/:domain/dns/records' => [domain => qr/[^\/]+/])->to('dns#delete_record');

    # Restart-debounce timer: fires every 10s, but only actually restarts
    # pdns if a write was marked >=10s ago (the debounce window -- lets
    # one composite "add domain" operation's several writes settle
    # before paying for a restart) and claims the row via FOR UPDATE
    # SKIP LOCKED so a multi-worker hypnotoad (workers => 2 above) never
    # races two workers into restarting pdns at once.
    Mojo::IOLoop->recurring(10 => sub { $self->_maybe_restart_pdns });

    return;
}

sub _maybe_restart_pdns ($self) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    my $row = $db->query(
        q{SELECT reason FROM domainadmin.pending_restart WHERE id = TRUE
          AND marked_at <= NOW() - INTERVAL '10 seconds' FOR UPDATE SKIP LOCKED},
    )->hash;
    return unless $row;

    $db->query('DELETE FROM domainadmin.pending_restart WHERE id = TRUE');
    $tx->commit;

    $self->log->info("restarting pdns ($row->{reason})");
    system('/usr/bin/sudo', '/usr/bin/systemctl', 'restart', 'pdns');
    $self->log->warn('pdns restart may have failed (exit code ' . ($? >> 8) . ')') if $? != 0;
    return;
}

1;
