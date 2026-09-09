package Homelab::Drive::App;
use Mojo::Base 'Mojolicious', -signatures;

use File::Path qw(make_path);
use File::Basename qw(basename);

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Common::AuthClient qw(introspect);

has 'pg';
has 'api_base';
has 'storage_path';
has 'sso_base';
has 'sso_client_id';
has 'sso_client_secret';
has 'sso_redirect_uri';

sub startup ($self) {
    # Installed via EXE_FILES to /usr/bin/homelab-drive, with no
    # adjacent templates/ dir there — templates/ actually lands at
    # /usr/share/homelab-drive/templates. Same HOMELAB_*_HOME env-var
    # pattern the old sso-ui package used for the same reason.
    my $home = $ENV{HOMELAB_DRIVE_HOME} // '/usr/share/homelab-drive';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_DRIVE_CONFIG', '/etc/homelab/drive/config.yml');
    $self->config($config);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2501'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/drive-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->storage_path($config->{storage}{path} // '/var/lib/homelab/drive-storage');
    make_path($self->storage_path);

    my $sso = $config->{sso} // die "config: sso.* is required (see config/drive.example.yml)\n";
    $self->sso_base($sso->{base_url} // die "config: sso.base_url is required\n");
    $self->sso_client_id($sso->{client_id} // die "config: sso.client_id is required\n");
    $self->sso_client_secret($sso->{client_secret} // die "config: sso.client_secret is required\n");
    $self->sso_redirect_uri($sso->{redirect_uri} // die "config: sso.redirect_uri is required\n");

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); return 1 });

    # Announce ourselves in the registry so other features (and
    # eventually homelab-webproxy) can find us without a hardcoded
    # address — see Homelab::Common::Registry.
    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        eval {
            register(
                api_base => $self->api_base, feature_name => 'homelab-drive',
                host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            );
        };
        $self->log->warn("registry registration failed (continuing anyway): $@") if $@;
    }

    my $r = $self->routes;
    $r->get('/')               ->to('drive#index');
    $r->get('/login')          ->to('drive#login_form');
    $r->get('/oauth/callback') ->to('drive#oauth_callback');
    $r->post('/logout')        ->to('drive#logout');
    $r->post('/upload')        ->to('drive#upload');
    $r->get('/files/:id/download')->to('drive#download');
    $r->post('/files/:id/delete') ->to('drive#delete_file');

    return;
}

package Homelab::Drive::App::Controller::Drive;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# `use`/imports in the Homelab::Drive::App package block above do NOT
# carry over here — each `package` statement in a file starts a fresh
# namespace for unqualified sub calls, so anything called unqualified
# from this controller needs its own import. Missing this caused a real
# "Undefined subroutine" 500 at runtime (login() and basename() are
# both called below) — only caught by the actual integration test
# exercising the login path, not by anything that runs without a live
# homelab-api to log in against.
use File::Basename qw(basename);
use Mojo::URL;
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient qw(exchange_code);

# Returns the logged-in user's email, or undef (and does NOT redirect —
# callers decide what "not logged in" means for their own route).
# Re-checks the JWT against homelab-api on every request rather than
# trusting the session blindly, same "don't assume, verify" reasoning
# as Homelab::Common::AuthClient exists for in the first place — a
# session that's still present but whose JWT expired must not keep
# working.
sub _current_email ($c) {
    my $jwt = $c->session('token');
    return undef unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $result ? $result->{email} : undef;
}

sub index ($c) {
    my $email = _current_email($c);
    return $c->redirect_to('/login') unless $email;

    my $files = $c->app->pg->db->query(
        'SELECT id, filename, size_bytes, mime_type, uploaded_at FROM drive.files
         WHERE user_email = ? ORDER BY uploaded_at DESC',
        $email,
    )->hashes;

    return $c->render(template => 'index', email => $email, files => $files);
}

sub _random_state {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $state = '';
    $state .= $chars[int(rand(@chars))] for 1 .. 32;
    return $state;
}

# There is no local password form any more — homelab-sso is the one
# place a password ever gets typed, so every relying party (this one
# included) redirects there instead of collecting credentials itself.
# `state` is a one-time CSRF nonce: stashed in Drive's own session here,
# checked against what the callback actually receives back, so a
# forged/replayed callback can't complete a login on this browser's
# behalf.
sub login_form ($c) {
    return $c->redirect_to('/') if _current_email($c);

    my $state = _random_state();
    $c->session(oauth_state => $state);

    my $url = Mojo::URL->new($c->app->sso_base . '/oauth/authorize')->query(
        client_id    => $c->app->sso_client_id,
        redirect_uri => $c->app->sso_redirect_uri,
        state        => $state,
        scope        => 'openid',
    );
    return $c->redirect_to($url);
}

# GET /oauth/callback?code=...&state=... — homelab-sso sends the
# browser here after a successful login (or an already-live IdP
# session, in which case the user never even saw a form). The code
# exchange itself is server-to-server (Homelab::Common::SSOClient),
# never exposed to the browser.
sub oauth_callback ($c) {
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state');
    $c->session(oauth_state => undef);

    unless ($code && $expected && $state eq $expected) {
        return $c->render(template => 'login', error => 'Login failed: the request expired or was invalid. Please try again.');
    }

    my $result = exchange_code($code,
        sso_base      => $c->app->sso_base,
        client_id     => $c->app->sso_client_id,
        client_secret => $c->app->sso_client_secret,
        redirect_uri  => $c->app->sso_redirect_uri,
    );
    unless ($result->{success}) {
        return $c->render(template => 'login', error => 'Login failed: could not complete sign-in. Please try again.');
    }

    $c->session(token => $result->{access_token}, refresh_token => $result->{refresh_token});
    return $c->redirect_to('/');
}

# Deliberately does NOT revoke the token itself (homelab-api's
# AuthClient::revoke() is still there, but calling it here would only
# be half of "logout everywhere"). Instead this redirects to
# homelab-sso's own /logout, which revokes the shared session centrally
# AND clears the IdP cookie — the single place that mechanism lives, so
# every relying party's logout button just routes through it. See
# ../../sso/README.md.
sub logout ($c) {
    $c->session(expires => 1);
    my $post_logout_uri = Mojo::URL->new($c->app->sso_redirect_uri)->path('/login');
    my $url = Mojo::URL->new($c->app->sso_base . '/logout')->query(redirect_uri => $post_logout_uri);
    return $c->redirect_to($url);
}

sub upload ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $upload = $c->req->upload('file');
    return $c->redirect_to('/') unless $upload;

    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type)
          VALUES (?, ?, ?, ?) RETURNING id, uuid},
        $email, $upload->filename, $upload->size, $upload->headers->content_type,
    )->hash;

    my $dest = $c->app->storage_path . '/' . $row->{uuid};
    $upload->move_to($dest);

    return $c->redirect_to('/');
}

sub download ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;

    my $id = $c->param('id');
    my $file = $c->app->pg->db->query(
        'SELECT filename, uuid, mime_type FROM drive.files WHERE id = ? AND user_email = ?',
        $id, $email,
    )->hash;
    return $c->render(text => 'not found', status => 404) unless $file;

    my $path = $c->app->storage_path . '/' . $file->{uuid};
    return $c->render(text => 'file missing on disk', status => 404) unless -f $path;

    $c->res->headers->content_type($file->{mime_type} || 'application/octet-stream');
    $c->res->headers->content_disposition(qq{attachment; filename="} . basename($file->{filename}) . qq{"});
    return $c->reply->file($path);
}

sub delete_file ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $id = $c->param('id');
    my $file = $c->app->pg->db->query(
        'SELECT uuid FROM drive.files WHERE id = ? AND user_email = ?', $id, $email,
    )->hash;
    if ($file) {
        $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $id);
        my $path = $c->app->storage_path . '/' . $file->{uuid};
        unlink($path) if -f $path;
    }
    return $c->redirect_to('/');
}

1;
