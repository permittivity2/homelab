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
has 'image_config';

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
    $self->image_config($config->{image} // {});

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
    $r->get('/folders/:id')    ->to('drive#index');
    $r->get('/login')          ->to('drive#login_form');
    $r->get('/oauth/callback') ->to('drive#oauth_callback');
    $r->post('/logout')        ->to('drive#logout');
    $r->post('/upload')        ->to('drive#upload');
    $r->post('/folders')            ->to('drive#create_folder');
    $r->post('/folders/:id/delete') ->to('drive#delete_folder');
    $r->get('/files/:id/download')->to('drive#download');
    $r->post('/files/:id/delete') ->to('drive#delete_file');
    $r->get('/files/:id/thumbnail')      ->to('drive#thumbnail');
    $r->get('/files/:id/slideshow-image')->to('drive#slideshow_image');

    # --- JSON API (Bearer-token authenticated, e.g. homelab-cli or any
    # third-party script -- see README.md and ../../CLAUDE.md). Not
    # session-cookie-based like the browser routes above: a CLI holds
    # its own homelab-api JWT directly, no SSO redirect dance needed. ---
    $r->get('/api/v1/files')        ->to('drive#api_list');
    $r->post('/api/v1/files')       ->to('drive#api_upload');
    $r->get('/api/v1/files/:id')    ->to('drive#download');
    $r->delete('/api/v1/files/:id') ->to('drive#api_delete');
    $r->get('/api/v1/folders')          ->to('drive#api_list_folders');
    $r->post('/api/v1/folders')         ->to('drive#api_create_folder');
    $r->delete('/api/v1/folders/:id')   ->to('drive#api_delete_folder');

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
use File::LibMagic;
use File::Path qw(make_path);
use Image::Magick;
use Mojo::URL;
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient qw(exchange_code);

my $MAGIC = File::LibMagic->new;

# Returns the logged-in user's email, or undef (and does NOT redirect —
# callers decide what "not logged in" means for their own route).
# Re-checks the JWT against homelab-api on every request rather than
# trusting the session blindly, same "don't assume, verify" reasoning
# as Homelab::Common::AuthClient exists for in the first place — a
# session that's still present but whose JWT expired must not keep
# working.
#
# Checks a Bearer Authorization header FIRST, falling back to the
# browser session cookie -- this is what lets the same handler back
# both the browser UI (session cookie, set via the SSO redirect flow)
# and the /api/v1/files JSON API below (a bearer token, e.g. homelab-cli
# holding its own homelab-api JWT directly -- no session/cookie
# involved at all for a CLI client).
sub _current_email ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    $jwt //= $c->session('token');
    return undef unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $result ? $result->{email} : undef;
}

# Walks the parent chain from the given folder up to the root,
# returning an arrayref of {id, name} from root-most to current --
# what the template renders as the clickable breadcrumb trail. Root
# itself isn't a row (see migrations/002-folders.sql: NULL parent_folder_id
# IS the root, no sentinel row needed), so it's never included here --
# the template renders its own fixed "Home" link for that.
sub _breadcrumb ($c, $email, $folder_id) {
    my @trail;
    while (defined $folder_id) {
        my $folder = $c->app->pg->db->query(
            'SELECT id, name, parent_folder_id FROM drive.folders WHERE id = ? AND user_email = ?',
            $folder_id, $email,
        )->hash;
        last unless $folder;
        unshift @trail, { id => $folder->{id}, name => $folder->{name} };
        $folder_id = $folder->{parent_folder_id};
    }
    return \@trail;
}

# Backs both GET / (root) and GET /folders/:id (a specific folder) --
# :id is simply absent for the root case, and drive.folders.parent_folder_id
# IS NULL is what "root" means throughout this file (see
# migrations/002-folders.sql). Shows this folder's own subfolders (the
# "directories on the left" of the two-pane layout) and files (the main
# pane) side by side -- deliberately only direct children, not a full
# recursive tree view; see README.md's Folders section for why that's a
# deliberate v1 scope choice, not an oversight.
sub index ($c) {
    my $email = _current_email($c);
    return $c->redirect_to('/login') unless $email;

    my $folder_id = $c->param('id');

    if (defined $folder_id) {
        my $folder = $c->app->pg->db->query(
            'SELECT id FROM drive.folders WHERE id = ? AND user_email = ?', $folder_id, $email,
        )->hash;
        return $c->render(text => 'folder not found', status => 404) unless $folder;
    }

    # drive.folders self-references via parent_folder_id; drive.files
    # points at a folder via folder_id -- two different column names,
    # deliberately NOT reused as one shared filter string here (that
    # was a real bug once: querying drive.folders with a "folder_id ="
    # filter, a column that table doesn't have at all).
    my $subfolder_filter = defined $folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my $file_filter      = defined $folder_id ? 'folder_id = ?'        : 'folder_id IS NULL';
    my @folder_bind       = defined $folder_id ? ($folder_id) : ();

    my $subfolders = $c->app->pg->db->query(
        "SELECT id, name FROM drive.folders WHERE user_email = ? AND $subfolder_filter ORDER BY name",
        $email, @folder_bind,
    )->hashes;

    # uploaded_at_display is a browser-UI-only presentation column --
    # the JSON API (api_list) deliberately keeps selecting plain
    # uploaded_at with full precision and a numeric offset, since a
    # script consuming it might actually want that. to_char's TZ format
    # spec pulls the zone ABBREVIATION (e.g. "CDT") from the session's
    # `timezone` GUC (already a real IANA zone, "America/Chicago" --
    # confirmed via `SHOW timezone` -- not a bare offset), which is what
    # makes this DST-correct for free: to_char picks CDT or CST based on
    # the actual date of each row, not a hardcoded label. This also
    # drops fractional seconds as a side effect of the explicit format
    # string (no regex trimming needed, unlike the old plain-offset
    # version of this field).
    my $files = $c->app->pg->db->query(
        "SELECT id, filename, size_bytes, mime_type, uploaded_at,
                to_char(uploaded_at, 'YYYY-MM-DD HH24:MI:SS TZ') AS uploaded_at_display
         FROM drive.files
         WHERE user_email = ? AND $file_filter ORDER BY uploaded_at DESC",
        $email, @folder_bind,
    )->hashes;

    return $c->render(
        template => 'index', email => $email, files => $files, folders => $subfolders,
        current_folder_id => $folder_id, breadcrumb => _breadcrumb($c, $email, $folder_id),
        error => $c->flash('error'),
    );
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

# A folder_id param that's present-but-empty (an unset <select> in the
# upload form, or an omitted JSON/query field) means the same thing as
# absent entirely: root. Centralized here since every folder-aware
# handler below needs this exact normalization.
sub _normalize_folder_id ($raw) {
    return (defined $raw && length $raw) ? $raw : undef;
}

# undef unless the given folder both exists AND belongs to $email --
# used everywhere a caller-supplied folder_id needs validating before
# it's trusted (uploading into it, listing it, nesting a new folder
# under it).
sub _owned_folder ($c, $email, $folder_id) {
    return undef unless defined $folder_id;
    return $c->app->pg->db->query(
        'SELECT id FROM drive.folders WHERE id = ? AND user_email = ?', $folder_id, $email,
    )->hash;
}

# Shared by the browser form (upload()) and the JSON API (api_upload())
# below -- inserts the DB row and moves the uploaded file into storage,
# returning the new row (id, filename, size_bytes, mime_type,
# uploaded_at). Callers decide how to respond (redirect vs JSON).
sub _save_upload ($c, $email, $upload, $folder_id) {
    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.files (user_email, filename, size_bytes, mime_type, folder_id)
          VALUES (?, ?, ?, ?, ?) RETURNING id, filename, size_bytes, mime_type, uploaded_at, folder_id, uuid},
        $email, $upload->filename, $upload->size, $upload->headers->content_type, $folder_id,
    )->hash;

    my $dest = $c->app->storage_path . '/' . $row->{uuid};
    $upload->move_to($dest);

    # The client-declared Content-Type used in the INSERT above is never
    # trustworthy (a browser/script can send anything, including a
    # generic default) -- now that the real bytes are on disk, sniff
    # them for real and correct the stored mime_type if it disagrees.
    # This is also what decides whether image derivatives get generated
    # below, so the "does this file get a thumbnail" decision and the
    # "Type" column/sort-by-type feature (see README.md) both end up
    # looking at the same real answer instead of two signals that can
    # disagree -- a real, caught-by-its-own-test bug the first version
    # of this had: a client that didn't send a proper image/* Content-
    # Type still got real thumbnail/slideshow-image files generated
    # (sniffed correctly) but the file row never showed them (the
    # template trusted the client-declared type instead).
    my $sniffed = $MAGIC->checktype_filename($dest);
    if ($sniffed && $sniffed ne ($row->{mime_type} // '')) {
        $c->app->pg->db->query('UPDATE drive.files SET mime_type = ? WHERE id = ?', $sniffed, $row->{id});
        $row->{mime_type} = $sniffed;
    }

    _generate_image_derivatives($c, $dest, $row->{uuid}, $sniffed);

    delete $row->{uuid};    # internal storage detail, never exposed
    return $row;
}

# Best-effort: a thumbnail/slideshow-image failure must never fail the
# upload itself -- the real file already landed on disk successfully,
# only these two derivatives are at risk. $mime_type is the already-
# sniffed (not client-declared) type from _save_upload above -- feeding
# attacker-controlled bytes into Image::Magick under a spoofed image/*
# Content-Type is exactly the kind of format-confusion ImageMagick has a
# real CVE history around, so the decision to even attempt decoding
# never rests on client input.
#
# Generated synchronously, inline with the upload request: this repo has
# no background job queue yet (unlike the old homelab-drive-web-ui,
# which offloaded this to homelab-api-backend-processor), and
# ImageMagick thumbnailing typical photos is fast enough that this is
# the simpler choice for now -- revisit with a real queue (see
# ../../CLAUDE.md's Minion plans) if large/frequent image uploads ever
# make upload latency a real problem.
sub _generate_image_derivatives ($c, $path, $uuid, $mime_type) {
    return unless ($mime_type // '') =~ m{^image/};

    my $cfg = $c->app->image_config;
    my %variant = (
        thumbnails => [$cfg->{thumbnail_geometry} // '200x200>',   $cfg->{thumbnail_quality} // 80],
        slideshow  => [$cfg->{slideshow_geometry}  // '1280x1280>', $cfg->{slideshow_quality} // 82],
    );

    for my $subdir (sort keys %variant) {
        my ($geometry, $quality) = @{ $variant{$subdir} };
        my $dest_dir = $c->app->storage_path . "/.$subdir";
        make_path($dest_dir) unless -d $dest_dir;
        my $dest = "$dest_dir/$uuid.jpg";

        eval {
            my $img = Image::Magick->new;
            my $err = $img->Read($path);
            die "$err\n" if $err;
            $img->Thumbnail(geometry => $geometry);
            $img->Set(quality => $quality);
            $err = $img->Write("jpeg:$dest");
            die "$err\n" if $err;
        };
        $c->app->log->warn("homelab-drive: $subdir generation failed for $uuid: $@") if $@;
    }
    return;
}

# Derivative files (thumbnail, slideshow-image) are looked up purely by
# uuid, never queried for -- unlinked alongside the original here and in
# _delete_folder()'s bulk cleanup below. A missing derivative (non-image
# file, or generation failed/skipped) is silently a no-op, same as the
# original file's own "unlink if -f" convention.
sub _unlink_derivatives ($c, $uuid) {
    for my $subdir (qw(thumbnails slideshow)) {
        my $path = $c->app->storage_path . "/.$subdir/$uuid.jpg";
        unlink($path) if -f $path;
    }
    return;
}

sub upload ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    my $back = $folder_id ? "/folders/$folder_id" : '/';

    my $upload = $c->req->upload('file');
    return $c->redirect_to($back) unless $upload;

    # A tampered/stale folder_id (deleted since the page was loaded, or
    # someone else's id) silently falls back to root rather than 500ing
    # or trusting an unowned folder -- same "fail to somewhere safe, not
    # to an error page" spirit as this file's other browser-facing
    # handlers.
    $folder_id = undef unless _owned_folder($c, $email, $folder_id);

    _save_upload($c, $email, $upload, $folder_id);
    return $c->redirect_to($folder_id ? "/folders/$folder_id" : '/');
}

# POST /api/v1/files (multipart, field name "file", optional field
# "folder_id") -- Bearer-authed equivalent of the browser upload form
# above, for homelab-cli (`homelab-cli drive upload`) or any third-party
# script (see ../../CLAUDE.md and this package's own README on why a
# real JSON API matters here, not just the browser UI).
sub api_upload ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $upload = $c->req->upload('file');
    return $c->render(json => { error => 'no file provided (multipart field name must be "file")' }, status => 400)
        unless $upload;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    if (defined $folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $folder_id);
    }

    my $row = _save_upload($c, $email, $upload, $folder_id);
    return $c->render(json => $row, status => 201);
}

# GET /api/v1/files -- this user's own files, as JSON. Optional
# ?folder_id=<id> query param scopes to one folder's direct contents,
# same as index()'s own browser view; omitted means root, NOT "every
# file everywhere" (see README.md's Folders section -- this is a
# deliberate behavior change from before folders existed, but a
# backward-compatible one: every file uploaded before this migration
# has folder_id NULL, i.e. already "at the root").
sub api_list ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $folder_id = _normalize_folder_id($c->param('folder_id'));
    if (defined $folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $folder_id);
    }
    my $folder_filter = defined $folder_id ? 'folder_id = ?' : 'folder_id IS NULL';
    my @folder_bind   = defined $folder_id ? ($folder_id) : ();

    my $files = $c->app->pg->db->query(
        "SELECT id, filename, size_bytes, mime_type, uploaded_at, folder_id FROM drive.files
         WHERE user_email = ? AND $folder_filter ORDER BY uploaded_at DESC",
        $email, @folder_bind,
    )->hashes;
    return $c->render(json => $files);
}

# --- Folders -------------------------------------------------------

# Shared by the browser form (create_folder()) and the JSON API
# (api_create_folder()) below. Returns (row, undef) on success or
# (undef, error_message) on failure -- a duplicate name in the same
# parent, or a parent_folder_id that doesn't exist/isn't this user's.
# No UNIQUE constraint backs the duplicate-name check (see
# migrations/002-folders.sql for why NULL parent_folder_id made that
# not work cleanly) -- this check-then-insert has the usual narrow
# TOCTOU race under real concurrent requests, accepted here the same
# way homelab-api's own register() accepts one for email uniqueness:
# annoying on a collision, not a security or data-integrity problem
# (worst case is two folders sharing a name, not silent data loss).
sub _create_folder ($c, $email, $name, $parent_folder_id) {
    if (defined $parent_folder_id) {
        return (undef, 'parent folder not found') unless _owned_folder($c, $email, $parent_folder_id);
    }

    my $folder_filter = defined $parent_folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my @folder_bind   = defined $parent_folder_id ? ($parent_folder_id) : ();
    my $existing = $c->app->pg->db->query(
        "SELECT id FROM drive.folders WHERE user_email = ? AND name = ? AND $folder_filter",
        $email, $name, @folder_bind,
    )->hash;
    return (undef, 'a folder with that name already exists here') if $existing;

    my $row = $c->app->pg->db->query(
        q{INSERT INTO drive.folders (user_email, name, parent_folder_id)
          VALUES (?, ?, ?) RETURNING id, name, parent_folder_id},
        $email, $name, $parent_folder_id,
    )->hash;
    return ($row, undef);
}

sub create_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $parent_folder_id = _normalize_folder_id($c->param('parent_folder_id'));
    my $back = $parent_folder_id ? "/folders/$parent_folder_id" : '/';
    my $name = $c->param('name');

    unless (defined $name && length $name) {
        $c->flash(error => 'Folder name is required');
        return $c->redirect_to($back);
    }

    my (undef, $error) = _create_folder($c, $email, $name, $parent_folder_id);
    $c->flash(error => $error) if $error;
    return $c->redirect_to($back);
}

# POST /api/v1/folders {name, parent_folder_id} (parent_folder_id
# omitted/null means root) -- Bearer-authed equivalent of the browser
# form above.
sub api_create_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $body = $c->req->json // {};
    my $name = $body->{name};
    return $c->render(json => { error => 'name is required' }, status => 400) unless defined $name && length $name;

    my ($row, $error) = _create_folder($c, $email, $name, $body->{parent_folder_id});
    return $c->render(json => { error => $error }, status => 409) if $error;
    return $c->render(json => $row, status => 201);
}

# GET /api/v1/folders?parent_id=<id> -- this user's own subfolders of
# the given parent (omitted means root), as JSON. Same query index()
# uses for the browser's own sidebar.
sub api_list_folders ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my $parent_folder_id = _normalize_folder_id($c->param('parent_id'));
    if (defined $parent_folder_id) {
        return $c->render(json => { error => 'folder not found' }, status => 404)
            unless _owned_folder($c, $email, $parent_folder_id);
    }
    my $folder_filter = defined $parent_folder_id ? 'parent_folder_id = ?' : 'parent_folder_id IS NULL';
    my @folder_bind   = defined $parent_folder_id ? ($parent_folder_id) : ();

    my $folders = $c->app->pg->db->query(
        "SELECT id, name, parent_folder_id FROM drive.folders WHERE user_email = ? AND $folder_filter ORDER BY name",
        $email, @folder_bind,
    )->hashes;
    return $c->render(json => $folders);
}

# Shared by the browser form (delete_folder()) and the JSON API
# (api_delete_folder()) below. Deleting a folder deletes everything
# inside it, recursively -- every subfolder and file, via the ON DELETE
# CASCADE chains in migrations/002-folders.sql. The DB cascade only
# removes rows, though; it has no idea these files also have real
# on-disk blobs, so this walks the whole subtree FIRST (a recursive
# CTE) to collect every uuid that's about to be orphaned, then unlinks
# them from disk after the DB delete succeeds -- skipping this would
# leak storage forever on every folder delete. Returns (1,
# parent_folder_id_of_the_deleted_folder) on success, (0, undef) if
# there was nothing to delete (nonexistent id, or someone else's --
# deliberately indistinguishable, same reasoning as this file's other
# "not found" checks).
sub _delete_folder ($c, $email, $id) {
    my $folder = $c->app->pg->db->query(
        'SELECT parent_folder_id FROM drive.folders WHERE id = ? AND user_email = ?', $id, $email,
    )->hash;
    return (0, undef) unless $folder;

    my $orphaned = $c->app->pg->db->query(
        q{WITH RECURSIVE subtree AS (
            SELECT id FROM drive.folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM drive.folders f JOIN subtree s ON f.parent_folder_id = s.id
          )
          SELECT uuid FROM drive.files WHERE folder_id IN (SELECT id FROM subtree)},
        $id,
    )->hashes;

    $c->app->pg->db->query('DELETE FROM drive.folders WHERE id = ?', $id);

    for my $row (@$orphaned) {
        my $path = $c->app->storage_path . '/' . $row->{uuid};
        unlink($path) if -f $path;
        _unlink_derivatives($c, $row->{uuid});
    }
    return (1, $folder->{parent_folder_id});
}

sub delete_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my (undef, $parent_folder_id) = _delete_folder($c, $email, $c->param('id'));
    return $c->redirect_to($parent_folder_id ? "/folders/$parent_folder_id" : '/');
}

# DELETE /api/v1/folders/:id -- Bearer-authed equivalent of the browser
# delete form above.
sub api_delete_folder ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my ($deleted) = _delete_folder($c, $email, $c->param('id'));
    return $c->render(json => { error => 'not found' }, status => 404) unless $deleted;
    return $c->render(json => { ok => \1 });
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

# GET /files/:id/thumbnail and GET /files/:id/slideshow-image -- both
# serve a pre-generated JPEG derivative (see _generate_image_derivatives
# above), never the original file data, and never as an attachment (an
# <img> tag/the lightbox need these inline, not downloaded). Same
# ownership check and "someone else's id -> 404, not 403" reasoning as
# download() above. 404 for a missing derivative is expected, not an
# error -- a non-image file, a failed generation, or a file uploaded
# before this feature existed all land here, and both callers (the file
# row's thumbnail <img> and the lightbox image) have an onerror fallback
# for exactly that -- see templates/index.html.ep.
sub _serve_derivative ($c, $email, $subdir) {
    my $id   = $c->param('id');
    my $file = $c->app->pg->db->query(
        'SELECT uuid FROM drive.files WHERE id = ? AND user_email = ?', $id, $email,
    )->hash;
    return $c->render(text => 'not found', status => 404) unless $file;

    my $path = $c->app->storage_path . "/.$subdir/$file->{uuid}.jpg";
    return $c->render(text => 'not found', status => 404) unless -f $path;

    $c->res->headers->content_type('image/jpeg');
    return $c->reply->file($path);
}

sub thumbnail ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;
    return _serve_derivative($c, $email, 'thumbnails');
}

sub slideshow_image ($c) {
    my $email = _current_email($c);
    return $c->render(text => 'not logged in', status => 401) unless $email;
    return _serve_derivative($c, $email, 'slideshow');
}

# Shared by the browser form (delete_file()) and the JSON API
# (api_delete()) below. Returns (1, folder_id_the_file_was_in) if a
# matching file was found and deleted, (0, undef) if there was nothing
# to delete (nonexistent id, or one belonging to a different user --
# deliberately indistinguishable, same as download()'s own "not found"
# for the same reason: a bare id in a URL shouldn't confirm/deny
# another user's file exists).
sub _delete_file ($c, $email, $id) {
    my $file = $c->app->pg->db->query(
        'SELECT uuid, folder_id FROM drive.files WHERE id = ? AND user_email = ?', $id, $email,
    )->hash;
    return (0, undef) unless $file;

    $c->app->pg->db->query('DELETE FROM drive.files WHERE id = ?', $id);
    my $path = $c->app->storage_path . '/' . $file->{uuid};
    unlink($path) if -f $path;
    _unlink_derivatives($c, $file->{uuid});
    return (1, $file->{folder_id});
}

sub delete_file ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my (undef, $folder_id) = _delete_file($c, $email, $c->param('id'));
    return $c->redirect_to($folder_id ? "/folders/$folder_id" : '/');
}

# DELETE /api/v1/files/:id -- Bearer-authed equivalent of the browser
# delete form above.
sub api_delete ($c) {
    my $email = _current_email($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;

    my ($deleted) = _delete_file($c, $email, $c->param('id'));
    return $c->render(json => { error => 'not found' }, status => 404) unless $deleted;
    return $c->render(json => { ok => \1 });
}

1;
