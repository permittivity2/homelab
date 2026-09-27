package Homelab::Invite::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Invite::App::Controller::Invites;

has 'pg';
has 'api_base';
has 'invite_config';
has 'mailer_config';

sub startup ($self) {
    my $config = load_config('HOMELAB_INVITE_CONFIG', '/etc/homelab/invite/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2514'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/invite-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->invite_config($config->{invite} // die "config: invite.* is required (see config/invite.example.yml)\n");
    $self->mailer_config($config->{mailer} // die "config: mailer.* is required (see config/invite.example.yml)\n");

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-invite',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Invite mechanism: token issuance/quota (serves /api/v1/invites/*)'
                . ' + public acceptance page at invite.<domain>',
            log => $self->log,
        );
    }

    # Any logged-in user -- self-service (send/list/revoke their own
    # invites) is the default tier here, unlike domain-admin's
    # all-site_admin-by-default posture, since inviting people is
    # inherently a normal-user action. Stashes roles too (not just jti,
    # unlike domain-admin's own version of this helper) -- several
    # routes below need a per-request "is this ALSO a site_admin"
    # check without a second introspect() round trip.
    $self->helper(authenticated_email_any => sub ($c) {
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
        $c->stash(current_jti => $result->{jti});
        $c->stash(current_roles => $result->{roles} // []);
        return $result->{email};
    });

    $self->helper(is_site_admin => sub ($c) {
        return !!(grep { $_ eq 'site_admin' } @{ $c->stash('current_roles') // [] });
    });

    # site_admin required -- the quota-management routes have no
    # legitimate self-service use case (a sender lowering their own
    # rate limit isn't a real scenario worth building for).
    $self->helper(authenticated_site_admin => sub ($c) {
        my $email = $c->authenticated_email_any or return undef;
        unless ($c->is_site_admin) {
            $c->render(json => { error => 'site_admin role required' }, status => 403);
            return undef;
        }
        return $email;
    });

    # NOT a human -- this checks for the system_agent role instead,
    # same role/introspect mechanism homelab-api's own
    # _require_system_agent uses internally, just via introspect()
    # since this service (unlike homelab-api itself) doesn't hold the
    # JWT signing secret. The only caller is homelab-api's own
    # _register handler, presenting its own host's homelab-agent
    # credential (Homelab::Common::Registry::system_agent_token) --
    # see README.md's "Consume endpoint trust model" section for why
    # this is safe to expose on the same public vhost as the
    # unauthenticated /invite/* pages (every /internal/v1/* route
    # enforces its own auth regardless of which vhost reached it).
    $self->helper(authenticated_system_agent => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) {
            $c->render(json => { error => 'authentication required' }, status => 401);
            return undef;
        }
        my $result = introspect($jwt, api_base => $self->api_base);
        unless ($result && grep { $_ eq 'system_agent' } @{ $result->{roles} // [] }) {
            $c->render(json => { error => 'system_agent role required' }, status => 403);
            return undef;
        }
        return 1;
    });

    my $r = $self->routes;

    # --- Internal, gateway-fronted via homelab-api's /api/v1/invites/*
    # (strip "/api/v1", reprepend "/internal/v1" -- see api/lib/Homelab/
    # API/App.pm's own comment on why domains/jobs/audit all need this
    # same transform). Registered before the public /invite/:token
    # routes below purely for readability; Mojolicious's own route
    # matching doesn't depend on registration order between these two
    # non-overlapping prefixes. -------------------------------------
    $r->post('/internal/v1/invites')          ->to('invites#create');
    $r->get('/internal/v1/invites')           ->to('invites#list');
    $r->delete('/internal/v1/invites/:id')    ->to('invites#delete_entry');
    $r->get('/internal/v1/invites/quota')                          ->to('invites#quota_show_mine');
    $r->get('/internal/v1/invites/quota/:sender_email' => [sender_email => qr/[^\/]+/]) ->to('invites#quota_show');
    $r->put('/internal/v1/invites/quota/:sender_email' => [sender_email => qr/[^\/]+/]) ->to('invites#quota_set');
    # Server-to-server only (system_agent role) -- registered after the
    # plain "/internal/v1/invites/:id" DELETE route has no overlap risk
    # with it (different HTTP method AND a literal "consume" segment,
    # not a placeholder), but kept last for readability alongside the
    # quota routes above.
    $r->post('/internal/v1/invites/consume')  ->to('invites#consume');

    # --- Public, no auth: fronted by homelab-webproxy's own
    # invite.<domain> vhost (see README.md's "Deployment" section).
    # :token needs the same [^\/]+ placeholder-regex override every
    # other non-numeric identifier in this ecosystem needs (Mojolicious
    # excludes "." from its default placeholder pattern) -- a 64-hex-
    # char token never contains one in practice, but costs nothing to
    # guard against the same class of bug domain-admin's :domain/
    # :recipient routes already document hitting for real. ------------
    $r->get('/invite/:token' => [token => qr/[^\/]+/])           ->to('invites#show');
    $r->post('/invite/:token/username' => [token => qr/[^\/]+/])  ->to('invites#check_username');
    $r->post('/invite/:token/accept' => [token => qr/[^\/]+/])    ->to('invites#accept');

    return;
}

1;
