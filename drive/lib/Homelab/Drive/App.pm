package Homelab::Drive::App;
use Mojo::Base 'Mojolicious', -signatures;

use File::Path qw(make_path);
use File::Basename qw(basename);

use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register);
use Homelab::Common::AuthClient qw(introspect login);

has 'pg';
has 'api_base';
has 'storage_path';

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
    $r->get('/')          ->to('drive#index');
    $r->get('/login')     ->to('drive#login_form');
    $r->post('/login')    ->to('drive#login_submit');
    $r->post('/logout')   ->to('drive#logout');
    $r->post('/upload')   ->to('drive#upload');
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
use Homelab::Common::AuthClient qw(introspect login);

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

sub login_form ($c) {
    return $c->redirect_to('/') if _current_email($c);
    return $c->render(template => 'login', error => undef);
}

sub login_submit ($c) {
    my $email    = $c->param('email');
    my $password = $c->param('password');
    return $c->render(template => 'login', error => 'Email and password are required')
        unless $email && $password;

    my $result = login($email, $password, api_base => $c->app->api_base);
    unless ($result->{success}) {
        return $c->render(template => 'login', error => $result->{error} // 'Login failed');
    }

    $c->session(token => $result->{token}, refresh_token => $result->{refresh_token});
    return $c->redirect_to('/');
}

sub logout ($c) {
    $c->session(expires => 1);
    return $c->redirect_to('/login');
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
