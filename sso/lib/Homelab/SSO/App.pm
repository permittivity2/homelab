package Homelab::SSO::App;
use Mojo::Base 'Mojolicious', -signatures;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);

has 'pg';
has 'api_base';
has 'oauth_clients';

sub startup ($self) {
    # Installed via EXE_FILES to /usr/bin/homelab-sso, with no adjacent
    # templates/ dir there -- same HOMELAB_*_HOME pattern every other
    # homelab-* Mojolicious app uses for the same reason.
    my $home = $ENV{HOMELAB_SSO_HOME} // '/usr/share/homelab-sso';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_SSO_CONFIG', '/etc/homelab/sso/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2502'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/sso-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    # This app's OWN IdP session -- separate cookie name from any
    # relying party's session, holding the current user's homelab-api
    # jwt/refresh_token/email. Its mere presence (and validity, checked
    # via introspect() on every /oauth/authorize) is what lets a second,
    # third, Nth client's authorize request skip the login form entirely
    # -- that's the actual "single" in single sign-on. Deliberately NOT
    # a shared cross-app cookie the way the old system's cross-app-
    # logout mechanism was (see Controller::Oauth's own comment on
    # logout) -- this cookie is read only by this app.
    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);
    $self->sessions->cookie_name('homelab-sso');
    $self->sessions->secure($config->{session}{secure} // 1);
    $self->sessions->default_expiration($config->{session}{expiry} // 30 * 24 * 60 * 60);

    $self->pg($self->config->{database} ? runtime_pg(%{ $self->config->{database} }) : undef);
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->oauth_clients($config->{clients} // []);

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); return 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-sso',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    my $r = $self->routes;
    $r->namespaces(['Homelab::SSO::Controller']);

    $r->get('/oauth/authorize')->to('oauth#authorize');
    $r->post('/oauth/authorize')->to('oauth#authorize_submit');
    $r->post('/oauth/token')->to('oauth#token');
    $r->get('/oauth/userinfo')->to('oauth#userinfo');
    $r->get('/logout')->to('oauth#logout');

    return;
}

1;
