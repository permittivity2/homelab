package Homelab::Notes::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(secure_compare);
use Homelab::Common::Config qw(load_config);
use Homelab::Common::DB qw(runtime_pg);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring lookup);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Notes::Model;
use Homelab::Notes::Gateway;

# The agents of a download (post-cutover #101): one fetches a note's images
# for the PDF (small and quick, 3 MB each at most), one talks to
# homelab-worker, which lays the PDF out (a note's PDF is small too).
has export_ua => sub { Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 8, inactivity_timeout => 8, max_redirects => 2, max_response_size => 3 * 1024 * 1024) };
has worker_ua => sub { Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 30, inactivity_timeout => 30, max_response_size => 50 * 1024 * 1024) };

has 'pg';
has 'model';
has 'gateway';
has 'api_base';
has 'sso';
has 'public_base_url';
has 'search_url';
has 'drive_url';
has 'csp';

# notes.<domain>: notebooks, folders, notes in Markdown, HTML or text, links
# to mail and drive files, sharing (post-cutover #71). The calendar's
# skeleton: sign-in through homelab-sso, the token held in this app's own
# session cookie and introspected against homelab-api on every request; the
# shared chrome from homelab-webtheme; one session secret for the pool; the
# same handlers behind a Bearer check under /internal/v1/notes/* for
# homelab-cli through homelab-api's gateway. See README.md.

sub startup ($self) {
    my $home = $ENV{HOMELAB_NOTES_HOME} // '/usr/share/homelab-notes';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);
    $self->static->paths([("$home/public"), @{ $self->static->paths }]);

    my $config = load_config('HOMELAB_NOTES_CONFIG', '/etc/homelab/notes/config.yml');
    $self->config($config);

    my $nc = $config->{notes} // {};
    my $base = ($nc->{public_base_url} // 'https://notes.test.mailmasker.org') =~ s{/\z}{}r;
    $self->public_base_url($base);
    # The search and drive apps live beside this one unless the config says where.
    my $sibling = sub ($name) { my $u = Mojo::URL->new($base); my $h = $u->host // 'notes.example'; $h =~ s/\A[^.]+/$name/; return $u->host($h)->path('/')->to_string =~ s{/\z}{}r };
    $self->search_url(($nc->{search_url} // $sibling->('search')) =~ s{/\z}{}r);
    $self->drive_url(($nc->{drive_url} // $sibling->('drive')) =~ s{/\z}{}r);

    my $theme = $config->{web_theme} // {};
    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'Notes',
        signout_url => '/logout',
        user_email  => sub ($c) { $c->session_email },
        ($theme->{base_url} ? (theme_base => $theme->{base_url}) : ()),
    });

    # Belt and braces for the one gate (Clean.pm): no inline script runs on
    # any page of this app, so a note's HTML could not run anything even if
    # the cleaner let something through. The app's own script is a file.
    my $theme_host = Mojo::URL->new($theme->{base_url} // Homelab::WebTheme::DEFAULT_THEME_BASE())->host // 'static.mailmasker.org';
    $self->csp(join '; ',
        "default-src 'self'",
        "script-src 'self' https://$theme_host",
        "style-src 'self' 'unsafe-inline' https://$theme_host https://fonts.googleapis.com",
        "font-src 'self' https://$theme_host https://fonts.gstatic.com",
        "img-src 'self' https: data:",
        "connect-src 'self'",
        "frame-ancestors 'none'", "base-uri 'none'", "form-action 'self' https:", "object-src 'none'",
    );
    $self->hook(before_dispatch => sub ($c) {
        my $h = $c->res->headers;
        $h->header('Content-Security-Policy' => $self->csp);
        $h->header('X-Content-Type-Options' => 'nosniff');
        $h->header('Referrer-Policy' => 'strict-origin-when-cross-origin');
        $h->header('X-Frame-Options' => 'DENY');
    });

    if (my $sso = $config->{sso}) {
        my @missing = grep { !$sso->{$_} } qw(base_url client_id client_secret redirect_uri);
        die "config: sso: is present but missing @missing (see config/notes.example.yml)\n" if @missing;
        $sso->{internal_base_url} //= $sso->{base_url};
        $self->sso($sso);
    }
    my $session = $config->{session} // {};
    die "config: session.secret is required once sso: is configured\n" if $self->sso && !$session->{secret};
    $self->secrets([$session->{secret} // Homelab::Notes::Model::_random_hex(32)]);
    $self->sessions->cookie_name('homelab-notes');
    $self->sessions->secure($session->{secure} // 1);
    $self->sessions->default_expiration(14 * 86400);

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2518'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/notes-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });
    # A note may be up to max_body_bytes; the request a little more.
    my $max_body = ($nc->{max_body_bytes} // 1048576) =~ /\A\d+\z/ ? $nc->{max_body_bytes} // 1048576 : 1048576;
    $self->max_request_size($max_body + 65536);

    $self->pg(runtime_pg(%{ $config->{database} }));
    $self->model(Homelab::Notes::Model->new(pg => $self->pg, max_body_bytes => $max_body,
        versions_kept => (($nc->{versions_kept} // 20) =~ /\A\d+\z/ ? $nc->{versions_kept} // 20 : 20)));
    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->gateway(Homelab::Notes::Gateway->new(api_base => $self->api_base, log => $self->log));

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-notes',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Notes web app: notebooks, folders, Markdown/HTML/text notes, links to mail and files, sharing at notes.<domain>',
            log => $self->log,
        );
    }

    # The address signed in here, or ''. One introspect per request; a token
    # that no longer introspects (expired, revoked by a sign-out anywhere, the
    # api unreachable) simply means signed out.
    $self->helper(session_email => sub ($c) {
        my $cached = $c->stash('notes.session_email');
        return $cached if defined $cached;
        my $email = '';
        if ($self->sso and my $jwt = $c->session('token')) {
            my $result = eval { introspect($jwt, api_base => $self->api_base) };
            if ($result && $result->{email}) {
                $email = lc $result->{email};
                $c->stash('notes.session_jwt' => $jwt);
                $c->stash('notes.session_jti' => $result->{jti});
            }
        }
        $c->stash('notes.session_email' => $email);
        return $email;
    });

    # The gateway-fronted routes (/internal/v1/notes/*, reached through
    # homelab-api's /api/v1/notes/* by homelab-cli): a Bearer JWT, introspected.
    $self->helper(authenticated_email_any => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) { $c->render(json => { error => 'not logged in' }, status => 401); return undef }
        my $result = eval { introspect($jwt, api_base => $self->api_base) };
        unless ($result && $result->{email}) { $c->render(json => { error => 'not logged in' }, status => 401); return undef }
        $c->stash(current_jti => $result->{jti});
        $c->stash('notes.session_jwt' => $jwt);
        return lc $result->{email};
    });

    # The viewer's own token, for the pickers that ask the gateway as them.
    $self->helper(viewer_jwt => sub ($c) { return $c->stash('notes.session_jwt') // $c->session('token') // '' });

    # Pages: send a visitor to sign in; JSON routes: 401. Both return the
    # address or an empty string after rendering.
    $self->helper(require_login => sub ($c) {
        my $email = $c->session_email;
        return $email if length $email;
        if ($c->req->url->path =~ m{^/api/}) {
            $c->render(json => { error => 'Your sign-in has ended. Reload the page and sign in again.' }, status => 401);
            return '';
        }
        delete @{ $c->session }{qw(token refresh_token)};
        my $next = $c->req->url->path->to_string;
        $c->redirect_to('/login' . (length $next && $next ne '/' ? '?next=' . Mojo::Util::url_escape($next) : ''));
        return '';
    });

    # Every JSON write must carry the CSRF token the page was drawn with: the
    # session cookie is the credential, so the request has to prove it came
    # from this site's own page and not from another site.
    $self->helper(csrf_ok => sub ($c) {
        return 1 if $c->stash('notes.bearer');    # a Bearer caller has no page and no token
        my $csrf = $c->req->headers->header('X-CSRF-Token') // '';
        return 1 if length $csrf && secure_compare($csrf, $c->csrf_token);
        $c->render(json => { error => 'This page is out of date. Reload it and try again.' }, status => 403);
        return 0;
    });

    my $r = $self->routes;
    my $id  = [id => qr/\d+/];
    my $tok = [token => qr/[0-9a-f]{64}/];
    my $kind = [kind => qr/source|text|html|pdf/];    # a download (#101)

    # The app itself.
    $r->get('/')                        ->to('auth#index');
    $r->get('/n/:id' => $id)            ->to('auth#index');
    $r->get('/login')                   ->to('auth#login');
    $r->get('/oauth/callback')          ->to('auth#oauth_callback');
    $r->post('/logout')                 ->to('auth#logout');

    # A link to a note or a notebook: anyone holding it (or the account it was
    # shared with). Format detection off: nothing here has an extension.
    $r->get('/s/:token' => $tok => [format => 0])                       ->to('public#share_page');
    $r->get('/s/:token/n/:id' => $tok => $id => [format => 0])          ->to('public#share_page');

    # JSON, same-origin, signed in (session + CSRF on writes).
    $r->get('/api/notebooks')                                   ->to('api#notebooks');
    $r->post('/api/notebooks')                                  ->to('api#create_notebook');
    $r->patch('/api/notebooks/:id' => $id)                      ->to('api#update_notebook');
    $r->post('/api/notebooks/:id/delete' => $id)                ->to('api#delete_notebook');
    $r->get('/api/notebooks/:id/folders' => $id)                ->to('api#folders');
    $r->post('/api/notebooks/:id/folders' => $id)               ->to('api#create_folder');
    $r->get('/api/notebooks/:id/shares' => $id)                 ->to('api#notebook_shares');
    $r->post('/api/notebooks/:id/shares' => $id)                ->to('api#create_notebook_share');
    $r->patch('/api/folders/:id' => $id)                        ->to('api#update_folder');
    $r->post('/api/folders/:id/delete' => $id)                  ->to('api#delete_folder');
    $r->get('/api/notes')                                       ->to('api#notes');
    $r->post('/api/notes')                                      ->to('api#create_note');
    $r->get('/api/notes/:id' => $id)                            ->to('api#note');
    $r->get('/api/notes/:id/download/:kind' => $id => $kind)    ->to('api#download');
    $r->patch('/api/notes/:id' => $id)                          ->to('api#update_note');
    $r->post('/api/notes/:id/delete' => $id)                    ->to('api#delete_note');
    $r->post('/api/notes/:id/restore' => $id)                   ->to('api#restore_note');
    $r->post('/api/notes/:id/move' => $id)                      ->to('api#move_note');
    $r->get('/api/notes/:id/versions' => $id)                   ->to('api#versions');
    $r->get('/api/notes/:id/links' => $id)                      ->to('api#links');
    $r->post('/api/notes/:id/links' => $id)                     ->to('api#add_link');
    $r->get('/api/notes/:id/shares' => $id)                     ->to('api#note_shares');
    $r->post('/api/notes/:id/shares' => $id)                    ->to('api#create_note_share');
    $r->get('/api/versions/:id' => $id)                         ->to('api#version');
    $r->post('/api/versions/:id/restore' => $id)                ->to('api#restore_version');
    $r->post('/api/links/:id/remove' => $id)                    ->to('api#remove_link');
    $r->post('/api/shares/:id/revoke' => $id)                   ->to('api#revoke_share');
    $r->get('/api/trash')                                       ->to('api#trash');
    $r->post('/api/trash/empty')                                ->to('api#empty_trash');
    $r->get('/api/search')                                      ->to('api#search');
    $r->get('/api/pick/mail')                                   ->to('api#pick_mail');
    $r->get('/api/pick/drive')                                  ->to('api#pick_drive');
    $r->post('/api/preview')                                    ->to('api#preview');
    $r->get('/api/prefs')                                       ->to('api#prefs');
    $r->put('/api/prefs')                                       ->to('api#save_prefs');

    # homelab-cli through the api gateway: Bearer, no CSRF; the same handlers.
    # (Literal paths on purpose: the developer site's t/reference.t reads them.)
    $r->get('/internal/v1/notes/notebooks')                                 ->to('api#i_notebooks');
    $r->post('/internal/v1/notes/notebooks')                                ->to('api#i_create_notebook');
    $r->patch('/internal/v1/notes/notebooks/:id' => $id)                    ->to('api#i_update_notebook');
    $r->post('/internal/v1/notes/notebooks/:id/delete' => $id)              ->to('api#i_delete_notebook');
    $r->get('/internal/v1/notes/notebooks/:id/folders' => $id)              ->to('api#i_folders');
    $r->post('/internal/v1/notes/notebooks/:id/folders' => $id)             ->to('api#i_create_folder');
    $r->get('/internal/v1/notes/notebooks/:id/shares' => $id)               ->to('api#i_notebook_shares');
    $r->post('/internal/v1/notes/notebooks/:id/shares' => $id)              ->to('api#i_create_notebook_share');
    $r->patch('/internal/v1/notes/folders/:id' => $id)                      ->to('api#i_update_folder');
    $r->post('/internal/v1/notes/folders/:id/delete' => $id)                ->to('api#i_delete_folder');
    $r->get('/internal/v1/notes/notes')                                     ->to('api#i_notes');
    $r->post('/internal/v1/notes/notes')                                    ->to('api#i_create_note');
    $r->get('/internal/v1/notes/notes/:id' => $id)                          ->to('api#i_note');
    $r->get('/internal/v1/notes/notes/:id/download/:kind' => $id => $kind)    ->to('api#i_download');
    $r->patch('/internal/v1/notes/notes/:id' => $id)                        ->to('api#i_update_note');
    $r->post('/internal/v1/notes/notes/:id/delete' => $id)                  ->to('api#i_delete_note');
    $r->post('/internal/v1/notes/notes/:id/restore' => $id)                 ->to('api#i_restore_note');
    $r->post('/internal/v1/notes/notes/:id/move' => $id)                    ->to('api#i_move_note');
    $r->get('/internal/v1/notes/notes/:id/versions' => $id)                 ->to('api#i_versions');
    $r->get('/internal/v1/notes/notes/:id/links' => $id)                    ->to('api#i_links');
    $r->post('/internal/v1/notes/notes/:id/links' => $id)                   ->to('api#i_add_link');
    $r->get('/internal/v1/notes/notes/:id/shares' => $id)                   ->to('api#i_note_shares');
    $r->post('/internal/v1/notes/notes/:id/shares' => $id)                  ->to('api#i_create_note_share');
    $r->get('/internal/v1/notes/versions/:id' => $id)                       ->to('api#i_version');
    $r->post('/internal/v1/notes/versions/:id/restore' => $id)              ->to('api#i_restore_version');
    $r->post('/internal/v1/notes/links/:id/remove' => $id)                  ->to('api#i_remove_link');
    $r->post('/internal/v1/notes/shares/:id/revoke' => $id)                 ->to('api#i_revoke_share');
    $r->get('/internal/v1/notes/trash')                                     ->to('api#i_trash');
    $r->post('/internal/v1/notes/trash/empty')                              ->to('api#i_empty_trash');
    $r->get('/internal/v1/notes/search')                                    ->to('api#i_search');
    $r->get('/internal/v1/notes/pick/mail')                                 ->to('api#i_pick_mail');
    $r->get('/internal/v1/notes/pick/drive')                                ->to('api#i_pick_drive');
    $r->post('/internal/v1/notes/preview')                                  ->to('api#i_preview');
    $r->get('/internal/v1/notes/prefs')                                     ->to('api#i_prefs');
    $r->put('/internal/v1/notes/prefs')                                     ->to('api#i_save_prefs');

    # Prometheus: the fleet's scraper reads this on the service port.
    $r->get('/metrics')                                     ->to('api#metrics');

    return;
}

1;
