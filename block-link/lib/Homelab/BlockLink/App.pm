package Homelab::BlockLink::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::BlockLink::App::Controller::BlockLink;

has 'pg';
has 'api_base';
has 'block_link_config';

sub startup ($self) {
    my $config = load_config('HOMELAB_BLOCK_LINK_CONFIG', '/etc/homelab/block-link/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2515'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/block-link-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->block_link_config($config->{block_link} // die "config: block_link.* is required (see config/block-link.example.yml)\n");

    mount_health_route($self, check => sub {
        $self->pg->db->query('SELECT 1');
        return 1;
    });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-block-link',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Click-to-block-from-inbox settings + link resolution'
                . ' (serves /api/v1/block-link/*) + public management page at blockemail.<domain>',
            log => $self->log,
        );
    }

    # Same shape as homelab-invite's identical helper -- any logged-in
    # user, self-service tier.
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

    # site_admin required -- domain-wide defaults are an operational/
    # compliance choice for the domain owner, not a personal setting
    # (see the plan's decision on why mode is domain-wide only, and why
    # even the enabled default belongs to the domain owner, distinct
    # from each account's own override).
    $self->helper(authenticated_site_admin => sub ($c) {
        my $email = $c->authenticated_email_any or return undef;
        unless ($c->is_site_admin) {
            $c->render(json => { error => 'site_admin role required' }, status => 403);
            return undef;
        }
        return $email;
    });

    my $r = $self->routes;

    # --- Internal, gateway-fronted via homelab-api's /api/v1/block-link/*
    # (strip "/api/v1", reprepend "/internal/v1"). ---------------------
    $r->get('/internal/v1/block-link/account')                            ->to('block_link#account_show');
    $r->put('/internal/v1/block-link/account')                            ->to('block_link#account_set');
    $r->get('/internal/v1/block-link/domains/:domain' => [domain => qr/[^\/]+/]) ->to('block_link#domain_show');
    $r->put('/internal/v1/block-link/domains/:domain' => [domain => qr/[^\/]+/]) ->to('block_link#domain_set');

    # --- Public, no auth: fronted by homelab-webproxy's own
    # blockemail.<domain> vhost. :token needs the same [^\/]+
    # placeholder-regex override every other non-numeric identifier in
    # this ecosystem needs. ---------------------------------------------
    $r->get('/l/:token' => [token => qr/[^\/]+/])  ->to('block_link#show');
    $r->post('/l/:token' => [token => qr/[^\/]+/]) ->to('block_link#submit');

    return;
}

1;
