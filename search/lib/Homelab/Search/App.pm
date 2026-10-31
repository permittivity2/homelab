package Homelab::Search::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::Pg;
use Mojo::Asset::File;
use Encode qw(decode FB_DEFAULT);

use Homelab::Common::Config   qw(load_config);
use Homelab::Common::Health   qw(mount_health_route);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient  qw(exchange_code);

use Homelab::Search::Query;
use Homelab::Search::Paths qw(maildir_for mailbox_dir_for drive_blob_for);
use Homelab::Search::MailParse qw(parse_message);

# search.mailmasker.org -- one place that searches mail and drive together.
#
# Same thin-BFF shape as homelab-drive and homelab-accountmanage: the browser
# talks only to this app, login is delegated to homelab-sso, and the session
# cookie holds the resulting token. Unlike those two it does own data -- the
# `search` schema -- but it reads it through a single query module and only
# ever within the signed-in account's scope.
#
# WHAT THIS PHASE DELIBERATELY DOES NOT DO: there is no AI. The toggle is
# rendered and disabled, because the whole product has to be useful with the
# model switched off -- if Phase 3 is ever disabled, search still works.

has 'api_base';
has 'public_base_url';
has 'sso_base';
has 'sso_internal_base';
has 'sso_client_id';
has 'sso_client_secret';
has 'sso_redirect_uri';
has 'mail_root';
has 'drive_root';
has 'query';
has 'pg';

sub startup ($self) {
    my $home = $ENV{HOMELAB_SEARCH_HOME} // '/usr/share/homelab-search';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_SEARCH_CONFIG', '/etc/homelab/search/config.yml');
    $self->config($config);

    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'Search',
        signout_url => '/logout',
        ($config->{web_theme}{base_url} ? (theme_base => $config->{web_theme}{base_url}) : ()),
        user_email  => sub ($c) { $c->stash('email') // '' },
        menu_links  => [
            { href => 'https://mail.mailmasker.org/',      label => 'Email' },
            { href => 'https://drive.mailmasker.org/',      label => 'Drive' },
            { href => 'https://myaccount.mailmasker.org/',  label => 'My Account' },
        ],
    });

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://0.0.0.0:2517'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/search-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);
    # Distinct cookie name, same convention as drive/accountmanage/sso. This
    # app is a three-node pool behind the edge, so webproxy needs
    # sticky_cookie: homelab-search for the OAuth round trip to land back on
    # the node that minted the state.
    $self->sessions->cookie_name('homelab-search');

    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->public_base_url($config->{public_base_url} // die "config: public_base_url is required\n");
    $self->mail_root($config->{mail_root}   // '/srv/mail-ro');
    $self->drive_root($config->{drive_root} // '/srv/drive-ro');

    my $sso = $config->{sso} // die "config: sso.* is required (see config/search.example.yml)\n";
    $self->sso_base($sso->{base_url} // die "config: sso.base_url is required\n");
    $self->sso_internal_base($sso->{internal_base_url} // $sso->{base_url});
    $self->sso_client_id($sso->{client_id} // die "config: sso.client_id is required\n");
    $self->sso_client_secret($sso->{client_secret} // die "config: sso.client_secret is required\n");
    $self->sso_redirect_uri($sso->{redirect_uri} // die "config: sso.redirect_uri is required\n");

    my $db = $config->{database} // die "config: database.* is required\n";
    my $pg = Mojo::Pg->new->dsn(sprintf('dbi:Pg:dbname=%s;host=%s;port=%s',
                                        $db->{name}, $db->{host}, $db->{port}))
                          ->username($db->{user})->password($db->{password});
    $self->pg($pg);
    $self->query(Homelab::Search::Query->new(pg => $pg, log => $self->log));

    mount_health_route($self, check => sub { $self->pg->db->query('SELECT 1'); 1 });

    # No register_recurring here, unlike the other web apps: it reads
    # /etc/homelab/agent/credential.yml (0600 homelab:homelab) and this app
    # runs as vmail, because it has to read a mail store where dovecot creates
    # maildirs 0700. Loosening a credential's permissions for a registry entry
    # is the wrong trade; homelab-agent reports this service from
    # /etc/homelab/services/search.yml instead.

    # Formatting helpers live here, NOT in the template. Mojolicious compiles
    # a template into a package that does not enable the `signatures`
    # feature, so `my $f = sub ($x) {...}` inside an .ep is parsed as a
    # PROTOTYPE and every use of $x is an undeclared global -- which fails at
    # render time with "Global symbol \"$s\" requires explicit package name",
    # not at build or install. A helper is both the correct place for this and
    # a context where signatures work.
    $self->helper(human_size => sub ($c, $bytes) {
        return '' unless defined $bytes;
        my @u = ('B', 'KB', 'MB', 'GB', 'TB');
        my ($n, $i) = ($bytes, 0);
        while ($n >= 1024 && $i < $#u) { $n /= 1024; $i++ }
        return sprintf($i ? '%.1f %s' : '%d %s', $n, $u[$i]);
    });
    # Postgres hands back '2026-01-01 10:00:00+00'; the page wants the day and
    # the time, not the fractional seconds or the offset.
    $self->helper(short_date => sub ($c, $ts) {
        return '' unless defined $ts && length $ts;
        my $t = "$ts";
        $t =~ s/\.\d+//;
        $t =~ s/[+-]\d\d(?::?\d\d)?\z//;
        $t =~ s/\s+\z//;
        return $t;
    });

    # The template asks the SAME function the server uses, rather than
    # re-deriving the rule in markup.
    $self->helper(viewable => sub ($c, $mime) {
        require Homelab::Search::Serve;
        return Homelab::Search::Serve::viewable($mime);
    });

    my $r = $self->routes;
    $r->get('/')                ->to('search#index');
    $r->get('/login')           ->to('search#login_form');
    $r->get('/oauth/callback')  ->to('search#oauth_callback');
    $r->post('/logout')         ->to('search#logout');
    $r->get('/api/v1/search')   ->to('search#api_search');
    # Viewing one result. Both ids are re-resolved under the account's own
    # scope inside Query, so an id belonging to someone else does not resolve
    # and there is no separate ownership check to forget.
    $r->get('/mail/:id/preview')  ->to('search#mail_preview');
    $r->get('/mail/:id/download') ->to('search#mail_download');
    $r->get('/drive/:id/view')    ->to('search#drive_view');
    $r->get('/drive/:id/download')->to('search#drive_download', force => 1);
    return;
}

package Homelab::Search::App::Controller::Search;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::URL;
use Mojo::Asset::File;
use Encode qw(decode FB_DEFAULT);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient  qw(exchange_code);
use Homelab::Search::Paths      qw(mailbox_dir_for drive_blob_for);
use Homelab::Search::MailParse  qw(parse_message);
use Homelab::Search::Serve      qw(serve_mode);

sub _random_state { return join '', map { sprintf '%02x', int rand 256 } 1 .. 16 }

sub _current_auth ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    $jwt //= $c->session('token');
    return (undef, undef) unless $jwt;
    my $r = introspect($jwt, api_base => $c->app->api_base);
    return $r ? ($r->{email}, $jwt) : (undef, undef);
}

# The signed-in address and its indexed account row. The account id comes
# from here and nowhere else -- never from a request parameter.
sub _scope ($c) {
    my ($email) = _current_auth($c);
    return (undef, undef) unless $email;
    my $acct = $c->app->query->account_for($email);
    return ($email, $acct);
}

sub login_form ($c) {
    my ($email) = _current_auth($c);
    return $c->redirect_to('/') if $email;
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

sub oauth_callback ($c) {
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state');
    $c->session(oauth_state => undef);

    unless ($code && $expected && $state eq $expected) {
        return $c->render(template => 'login',
            error => 'Sign-in expired or was invalid. Please try again.', status => 400);
    }
    my $r = exchange_code($code,
        sso_base      => $c->app->sso_internal_base,
        client_id     => $c->app->sso_client_id,
        client_secret => $c->app->sso_client_secret,
        redirect_uri  => $c->app->sso_redirect_uri,
    );
    unless ($r->{success}) {
        return $c->render(template => 'login',
            error => 'Could not complete sign-in. Please try again.', status => 502);
    }
    $c->session(token => $r->{access_token}, refresh_token => $r->{refresh_token});
    return $c->redirect_to('/');
}

sub logout ($c) {
    $c->session(expires => 1);
    return $c->redirect_to($c->app->sso_base . '/logout');
}

# Normalized filters. Everything is clamped here rather than trusted: a limit
# of 10,000,000 is a denial-of-service request, not a search.
sub _filters ($c) {
    my $limit = $c->param('limit') // 50;
    $limit = 50  unless $limit =~ /\A\d+\z/;
    $limit = 200 if $limit > 200;
    my $off = $c->param('offset') // 0;
    $off = 0 unless $off =~ /\A\d+\z/;
    $off = 100_000 if $off > 100_000;

    my %f = (
        q        => scalar($c->param('q')      // ''),
        person   => scalar($c->param('person') // ''),
        from     => scalar($c->param('from')   // ''),
        to       => scalar($c->param('to')     // ''),
        mailbox  => scalar($c->param('mailbox') // ''),
        mime     => scalar($c->param('mime')   // ''),
        limit    => $limit,
        offset   => $off,
        in_trash        => ($c->param('in_trash')        ? 1 : 0),
        has_attachments => ($c->param('has_attachments') ? 1 : 0),
    );
    for my $k (qw(min_size max_size)) {
        my $v = $c->param($k);
        $f{$k} = $v if defined $v && $v =~ /\A\d+\z/ && $v > 0;
    }
    $f{source} = ($c->param('source') // 'both');
    $f{source} = 'both' unless $f{source} =~ /\A(?:both|mail|drive)\z/;
    return \%f;
}

sub _run ($c, $acct, $f) {
    my ($mail, $drive) = ([], []);
    return ($mail, $drive) unless $acct;
    $mail  = $c->app->query->search_mail($acct->{account_id}, $f)  if $f->{source} ne 'drive';
    $drive = $c->app->query->search_drive($acct->{account_id}, $f) if $f->{source} ne 'mail';
    return ($mail, $drive);
}

sub index ($c) {
    my ($email, $acct) = _scope($c);
    return $c->redirect_to('/login') unless $email;

    my $f = _filters($c);
    my ($mail, $drive) = _run($c, $acct, $f);

    return $c->render(
        template   => 'index',
        email      => $email,
        account    => $acct,
        f          => $f,
        mail       => $mail,
        drive      => $drive,
        mailboxes  => ($acct ? $c->app->query->mailboxes($acct->{account_id}) : []),
        counts     => ($acct ? $c->app->query->counts($acct->{account_id})    : {}),
        searched   => (length($f->{q}) || length($f->{person}) || length($f->{from})
                    || length($f->{to}) || length($f->{mime}) || $f->{in_trash}
                    || $f->{has_attachments} ? 1 : 0),
    );
}

sub api_search ($c) {
    my ($email, $acct) = _scope($c);
    return $c->render(json => { error => 'not logged in' }, status => 401) unless $email;
    my $f = _filters($c);
    my ($mail, $drive) = _run($c, $acct, $f);
    return $c->render(json => {
        account => ($acct ? $acct->{email} : $email),
        indexed => ($acct ? \1 : \0),
        filters => $f,
        mail    => $mail,
        drive   => $drive,
    });
}

# ----------------------------------------------------- serving one result
#
# The per-mime policy lives in Homelab::Search::Serve so the template and the
# server read the same answer. See that module for why html/svg are never
# served inline.

# Applied to every response that carries user content. nosniff is what stops
# a browser second-guessing text/plain back into HTML.
sub _harden ($c) {
    $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
    $c->res->headers->header('Content-Security-Policy' =>
        "default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'; sandbox");
    $c->res->headers->header('Referrer-Policy' => 'no-referrer');
    return;
}

sub _message_path ($c, $m) {
    return eval {
        my $dir = mailbox_dir_for($c->app->mail_root, $m->{domain}, $m->{local_part},
                                  $m->{mailbox}, $m->{maildir_sub});
        "$dir/$m->{file_name}";
    };
}

sub mail_preview ($c) {
    my ($email, $acct) = _scope($c);
    return $c->render(text => 'not logged in', status => 401) unless $email && $acct;
    my $m = $c->app->query->message($acct->{account_id}, $c->stash('id'))
        or return $c->render(text => 'not found', status => 404);

    my $path = _message_path($c, $m);
    return $c->render(text => 'message file is no longer on disk', status => 410)
        unless $path && -r $path;

    open(my $fh, '<', $path) or return $c->render(text => 'unreadable', status => 500);
    binmode $fh; local $/ = undef; my $raw = <$fh>; close $fh;

    # Parsed to TEXT, deliberately. The HTML part of a stranger's email is
    # never rendered as HTML here -- it is reduced to text by the same parser
    # the indexer uses. A mail preview that renders remote HTML is a tracking
    # pixel and an exfiltration channel.
    my $p = parse_message($raw, { size => $m->{size_bytes} });
    _harden($c);
    return $c->render(template => 'preview', format => 'html',
        email => $email, m => $m, parsed => $p);
}

sub mail_download ($c) {
    my ($email, $acct) = _scope($c);
    return $c->render(text => 'not logged in', status => 401) unless $email && $acct;
    my $m = $c->app->query->message($acct->{account_id}, $c->stash('id'))
        or return $c->render(text => 'not found', status => 404);
    my $path = _message_path($c, $m);
    return $c->render(text => 'message file is no longer on disk', status => 410)
        unless $path && -r $path;

    my $name = $m->{subject} // 'message';
    $name =~ s/[^\w.\- ]+/_/g;
    $name = substr($name, 0, 80);
    _harden($c);
    $c->res->headers->content_type('message/rfc822');
    $c->res->headers->content_disposition(qq{attachment; filename="$name.eml"});
    return $c->reply->asset(Mojo::Asset::File->new(path => $path));
}

sub drive_view ($c) { return _drive_serve($c, 0) }
sub drive_download ($c) { return _drive_serve($c, 1) }

sub _drive_serve ($c, $force_download) {
    my ($email, $acct) = _scope($c);
    return $c->render(text => 'not logged in', status => 401) unless $email && $acct;
    my $i = $c->app->query->drive_item($acct->{account_id}, $c->stash('id'))
        or return $c->render(text => 'not found', status => 404);

    my $path = eval { drive_blob_for($c->app->drive_root, $i->{file_uuid}) };
    return $c->render(text => 'file is no longer on disk', status => 410)
        unless $path && -r $path;

    my ($mode, $ctype) = serve_mode($i->{mime_type});
    $mode = 'download' if $force_download;
    # Any text type is served as text/plain regardless of its own subtype.
    $ctype = 'text/plain; charset=utf-8' if $mode eq 'inline' && ($i->{mime_type} // '') =~ m{^text/};

    my $name = $i->{file_name} // 'file';
    $name =~ s/[^\w.\- ]+/_/g;
    $name = substr($name, 0, 120);

    _harden($c);
    if ($mode eq 'download') {
        $c->res->headers->content_type('application/octet-stream');
        $c->res->headers->content_disposition(qq{attachment; filename="$name"});
    }
    else {
        $c->res->headers->content_type($ctype);
        $c->res->headers->content_disposition(qq{inline; filename="$name"});
    }
    return $c->reply->asset(Mojo::Asset::File->new(path => $path));
}

1;
