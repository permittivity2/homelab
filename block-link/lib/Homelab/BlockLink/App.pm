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
# Sign-in through homelab-sso: the config's sso: block, or undef when it has
# none. Optional on purpose -- without it the page still works exactly as a
# link-only page, so a config written before sign-in existed needs no change
# to keep starting.
has 'sso';
has 'manage_account_url';

sub startup ($self) {
    # Templates ship in /usr/share/homelab-block-link/templates since
    # 2026-11-03; before that the public pages were qq{} HTML built in the
    # controller, which is why they were the last pages left off the shared
    # mailmasker look.
    my $home = $ENV{HOMELAB_BLOCK_LINK_HOME} // '/usr/share/homelab-block-link';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_BLOCK_LINK_CONFIG', '/etc/homelab/block-link/config.yml');
    $self->config($config);

    # Shared web chrome (homelab-webtheme): the top bar, the footer and
    # theme.css from static.mailmasker.org, the same as drive, search and
    # myaccount. Someone opening a link from an email is usually NOT signed
    # in here -- the link's token is enough to block that message's own
    # addresses -- and then the top bar shows just the logo and the app name.
    # Signed in, it shows the same account menu as every other app.
    my $theme = $config->{web_theme} // {};
    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'Block email',
        signout_url => '/logout',
        user_email  => sub ($c) { $c->session_email },
        ($theme->{base_url} ? (theme_base => $theme->{base_url}) : ()),
    });
    my $home_url = $theme->{home_url} // 'https://mailmasker.org/';

    # Sign-in. homelab-sso is the only place a password is ever typed; this
    # app holds the resulting token in its own session cookie, like drive,
    # search and myaccount. The session secret must be the SAME on all three
    # pool nodes (block-link-sso-provision.sh writes one): requests are not
    # sticky, and a node that cannot read the cookie it is handed would fail
    # one sign-in in three.
    if (my $sso = $config->{sso}) {
        my @missing = grep { !$sso->{$_} } qw(base_url client_id client_secret redirect_uri);
        die "config: sso: is present but missing @missing (see config/block-link.example.yml)\n" if @missing;
        $sso->{internal_base_url} //= $sso->{base_url};
        $self->sso($sso);
    }
    my $session = $config->{session} // {};
    die "config: session.secret is required once sso: is configured\n" if $self->sso && !$session->{secret};
    # With no sign-in configured nothing is ever written to the session, but
    # Mojolicious still wants a secret that is not its own default.
    $self->secrets([$session->{secret} // _random_hex(32)]);
    $self->sessions->cookie_name('homelab-block-link');
    $self->sessions->secure($session->{secure} // 1);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2515'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/block-link-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->block_link_config($config->{block_link} // die "config: block_link.* is required (see config/block-link.example.yml)\n");
    # Where the Manage Account buttons lead: myaccount's Mail section, which
    # lists, filters, blocks and unblocks the same addresses.
    $self->manage_account_url($self->block_link_config->{manage_account_url}
        // 'https://myaccount.mailmasker.org/#mailself');

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

    # The address signed in to THIS app's session, or '' -- resolved once per
    # request (the shared header asks too). A token that no longer
    # introspects (expired, or revoked by a sign-out anywhere) simply means
    # signed out: the page then behaves as a link-only page.
    $self->helper(session_email => sub ($c) {
        my $cached = $c->stash('block_link.session_email');
        return $cached if defined $cached;
        my $email = '';
        if ($self->sso and my $jwt = $c->session('token')) {
            my $result = eval { introspect($jwt, api_base => $self->api_base) };
            if ($result && $result->{email}) {
                $email = $result->{email};
                $c->stash('block_link.session_jwt' => $jwt);
            }
        }
        $c->stash('block_link.session_email' => $email);
        return $email;
    });
    $self->helper(session_jwt => sub ($c) {
        return $c->session_email ? $c->stash('block_link.session_jwt') : undef;
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

    # Sign-in, for the signed-in view of a link (see Visibility.pm). Without
    # an sso: block these lead back to the front page.
    $r->get('/login')          ->to('block_link#login');
    $r->get('/oauth/callback') ->to('block_link#oauth_callback');
    $r->post('/logout')        ->to('block_link#logout');

    # The shared top bar's logo links to "/", and this site has no page of
    # its own there: send it to the product's front page rather than a 404.
    $r->get('/' => sub ($c) { $c->redirect_to($home_url) });

    return;
}

sub _random_hex ($bytes) {
    open my $fh, '<:raw', '/dev/urandom' or die "cannot read /dev/urandom: $!\n";
    read($fh, my $buf, $bytes) == $bytes or die "short read from /dev/urandom\n";
    close $fh;
    return unpack 'H*', $buf;
}

1;
