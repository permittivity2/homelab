package Homelab::Search::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::Pg;
use Mojo::Asset::File;
use Mojo::Util qw(url_escape);
use Encode qw(decode FB_DEFAULT);

use Homelab::Common::Config   qw(load_config);
use Homelab::Common::Health   qw(mount_health_route);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::SSOClient  qw(exchange_code);

use Homelab::Search::Query;
use Homelab::Search::Paths qw(maildir_for mailbox_dir_for drive_blob_for);
use Homelab::Search::MailParse qw(parse_message);
use Homelab::Search::AI;
use Homelab::Search::AI::Client;
use Homelab::Search::AI::Consent ();

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
has 'ai';

sub startup ($self) {
    my $home = $ENV{HOMELAB_SEARCH_HOME} // '/usr/share/homelab-search';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);

    my $config = load_config('HOMELAB_SEARCH_CONFIG', '/etc/homelab/search/config.yml');
    $self->config($config);

    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'Search',
        signout_url => '/logout',
        # NO theme_base override. Homelab::WebTheme's own default is
        # https://static.mailmasker.org/theme/v1 -- the version lives in the
        # PATH -- and no other app overrides it. Setting it from config here
        # is how it went wrong once already: the value written was
        # https://static.mailmasker.org, theme.css 404'd, and every CSS rule
        # using a var(--...) silently evaluated to nothing, so the whole page
        # fell back to unstyled browser defaults. A config key that merely
        # restates a default only exists to drift away from it.
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

    # AI mode. Constructed even when switched off, so every gate lives in
    # one place and `enabled` is a value rather than a branch around a
    # missing object. With no api_key the orchestrator records `disabled`
    # and the page falls back to keyword search -- which is the shipping
    # default: the feature is dark until a key is configured AND
    # ai.enabled is true.
    my $ai_cfg = $config->{ai} // {};
    $self->ai(Homelab::Search::AI->new(
        query  => $self->query,
        log    => $self->log,
        config => $ai_cfg,
        client => Homelab::Search::AI::Client->new(
            api_key    => $ai_cfg->{api_key},
            model      => ($ai_cfg->{model}      // 'claude-opus-5-5'),
            gate_model => ($ai_cfg->{gate_model} // 'claude-haiku-5-5'),
            effort     => ($ai_cfg->{effort}     // 'low'),
            max_tokens => ($ai_cfg->{max_tokens} // 16000),
            log        => $self->log,
        ),
    ));

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
    # NO SECONDS. Nobody scans a result list or a photo's details to the
    # second, and it is three characters of noise on every row.
    #
    # Done HERE rather than at the one place it was noticed, because a
    # photo shows the same instant twice -- the taken-at date becomes the
    # file's content_created_at, so it is both the headline date and the
    # "Taken" chip. Trimming one would have rendered one timestamp two
    # different ways on one line.
    #
    # The pattern needs HH:MM in front of the seconds it removes. A bare
    # `:\d\d$` would turn an already-secondless '14:30' into '14'.
    $self->helper(short_date => sub ($c, $ts) {
        return '' unless defined $ts && length $ts;
        my $t = "$ts";
        $t =~ s/\.\d+//;
        # THE OFFSET IS ONLY AN OFFSET AFTER A TIME. Unanchored, the old
        # pattern ate the '-19' off a date-only '2026-09-19' and returned
        # '2026-09' -- the day, silently gone. Every column feeding this is
        # timestamptz so Postgres always sends a time and it never showed,
        # but one of these values comes out of a stranger's EXIF.
        $t =~ s/(\d{2}:\d{2}(?::\d{2})?)\s*(?:[+-]\d{2}(?::?\d{2})?|Z)\z/$1/;
        $t =~ s/([T ]\d{2}:\d{2}):\d{2}\z/$1/;
        $t =~ s/\s+\z//;
        return $t;
    });

    # 30419 is harder to read than 30,419, and the exact-type list is a
    # column of counts whose whole job is to be compared at a glance.
    $self->helper(commify => sub ($c, $n) {
        return '' unless defined $n;
        my $s = reverse "$n";
        $s =~ s/(\d{3})(?=\d)/$1,/g;
        return scalar reverse $s;
    });

    # "Clear all filters" is an <a>, so it has to work with the script off.
    # It keeps the query and drops everything else.
    # Clearing the filters keeps the panel open, because the only place this
    # link exists is inside the open panel. Dropping fopen here would let the
    # derived fallback decide, and with every filter just cleared that means
    # closed -- so the panel you were working in would slam shut at the exact
    # moment you cleared it to set something else.
    $self->helper(clear_href => sub ($c, $q) {
        my $keep = 'fopen=1';
        return "/?$keep" unless defined $q && length $q;
        return '/?q=' . url_escape($q) . "&$keep";
    });

    # "Everything else with this person in it", from the name under a
    # photo. The one control for this used to be a text box labelled
    # "From or to" in the Email-only section, so the quickest way to ask
    # the question was to not know it was possible.
    $self->helper(personal_href => sub ($c, $name, $src) {
        return '#' unless defined $name && length $name;
        return '/?person=' . url_escape($name) . '&src=' . url_escape($src // 'drive');
    });

    # Metadata as a person reads it. 40.166 is a duration of 0:40, 0.0125
    # is an exposure of 1/80, and 1.8 is f/1.8 -- the index stores the
    # number because that is what sorts and filters, and this is the only
    # place that turns it back into the notation on the camera body.
    $self->helper(meta_value => sub ($c, $kv) {
        my ($k, $v, $kind) = @{$kv}{qw(key_name value kind)};
        return '' unless defined $v;
        return $c->short_date($v) if $kind eq 'at';
        if ($kind eq 'num') {
            return sprintf('%d:%02d', int($v / 60), int($v) % 60) if $k eq 'media.duration_s';
            # The shutter speed as written on a lens: a reciprocal under a
            # second, a plain number above it.
            return $v >= 1 ? sprintf('%.3gs', $v) : sprintf('1/%d', int(1 / $v + 0.5))
                if $k eq 'image.exposure_s' && $v > 0;
            return sprintf('f/%.3g', $v)          if $k eq 'image.f_number';
            return sprintf('%.3g mm', $v)         if $k eq 'image.focal_length_mm';
            return sprintf('%.1f m', $v)          if $k eq 'gps.altitude_m';
            return sprintf('%.5f', $v)            if $k =~ /^gps\.(?:latitude|longitude)$/;
            return sprintf('%.1f Mbps', $v / 1_000_000) if $k eq 'media.bitrate' && $v > 1_000_000;
            return sprintf('%.3g fps', $v)        if $k eq 'video.frame_rate';
            # Orientation is an EXIF enum, and the number means nothing to
            # anyone who has not read the spec.
            if ($k eq 'image.orientation') {
                my %o = (1 => 'Normal', 3 => 'Upside down',
                         6 => 'Rotated right', 8 => 'Rotated left');
                return $o{$v} // "Orientation $v";
            }
            return $v == int($v) ? int($v) : sprintf('%.4g', $v);
        }
        return $v;
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
    $r->post('/ai/consent')     ->to('search#ai_consent');
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
use Mojo::Util                  qw(url_escape);
use Homelab::Search::Paths      qw(mailbox_dir_for drive_blob_for);
use Homelab::Search::Mime       ();
use Homelab::Search::AI::Consent ();
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
    # Source arrives two ways, and both have to keep working.
    #
    # `source=both|mail|drive` is the WIRE contract -- homelab-cli sends it,
    # /api/v1/search documents it, and a bookmarked URL carries it. The form
    # sends `src` instead, repeatable, one value per ticked checkbox, because
    # "search email, files, or both" is two yes/no answers and modelling it
    # as a three-option <select> hid the answer inside a control you had to
    # read before you could tell why half the panel was greyed out.
    #
    # Neither ticked means BOTH, deliberately: that is also exactly what a
    # browser with JavaScript off sends when you clear both boxes, and a
    # search over nothing at all is never what was meant. The page says so
    # in as many words rather than silently correcting it.
    my %src = map { $_ => 1 } grep { /\A(?:mail|drive)\z/ } @{ $c->every_param('src') };
    if (keys %src == 1) { ($f{source}) = keys %src }
    elsif (keys %src)   { $f{source} = 'both' }
    else {
        $f{source} = ($c->param('source') // 'both');
        $f{source} = 'both' unless $f{source} =~ /\A(?:both|mail|drive)\z/;
    }

    # Type include/exclude. Repeatable, and capped at 40 tokens each purely
    # to bound the generated boolean -- a request with 5,000 of them should
    # be a short query, not a long one. Homelab::Search::Mime drops anything
    # malformed, so no validation belongs here.
    for my $k (qw(type_in type_ex)) {
        my @v = @{ $c->every_param($k) };
        @v = @v[0 .. 39] if @v > 40;
        $f{$k} = [ grep { defined && length } @v ];
    }
    return \%f;
}

# Did the user actually ask for anything? An empty form is a landing page,
# not a search for everything.
sub _searched ($f) {
    return 1 if length($f->{q} // '') || length($f->{person} // '')
             || length($f->{from} // '') || length($f->{to} // '')
             || length($f->{mime} // '') || length($f->{mailbox} // '')
             || $f->{in_trash} || $f->{has_attachments}
             || $f->{min_size} || $f->{max_size}
             || @{ $f->{type_in} // [] } || @{ $f->{type_ex} // [] };
    return 0;
}

sub _run ($c, $acct, $f) {
    my ($mail, $drive) = ([], []);
    return ($mail, $drive) unless $acct;
    # Nothing asked for, nothing run. The page already renders "type something
    # above" in this case -- but it used to compute both result sets first and
    # then discard them, and an unfiltered mail query over 25,798 messages
    # takes 5.2 SECONDS because ORDER BY ... LIMIT 50 still has to sort every
    # row. That was the whole of the delay between clicking Deep Search and
    # seeing the page.
    return ($mail, $drive) unless _searched($f);
    $mail  = $c->app->query->search_mail($acct->{account_id}, $f)  if $f->{source} ne 'drive';
    $drive = $c->app->query->search_drive($acct->{account_id}, $f) if $f->{source} ne 'mail';
    return ($mail, $drive);
}

# Is AI mode even offerable here? Three separate things, and the page has
# to tell them apart: the operator switched it on, a key is configured, and
# THIS person has agreed to the current wording.
sub _ai_state ($c, $acct) {
    my $cfg = $c->app->config->{ai} // {};
    my $on  = ($cfg->{enabled} && length($cfg->{api_key} // '')) ? 1 : 0;
    my %s = (available => $on, consented => 0, notice => Homelab::Search::AI::Consent::notice_body());
    return \%s unless $on && $acct;
    $s{consented} = Homelab::Search::AI::Consent::state_for(
        $c->app->query, $acct->{account_id})->{consented};
    return \%s;
}

sub index ($c) {
    my ($email, $acct) = _scope($c);
    return $c->redirect_to('/login') unless $email;

    my $f = _filters($c);
    my ($mail, $drive) = _run($c, $acct, $f);

    # AI runs only when asked for, and only on top of a real question. The
    # keyword results above are computed either way, which is what makes
    # the deterministic fallback free: every failure path below simply
    # renders them without an AI block.
    my $ai_state = _ai_state($c, $acct);
    my $ai;
    if ($ai_state->{available} && $acct && $c->param('ai') && length($f->{q} // '')) {
        $ai = eval {
            $c->app->ai->answer($acct->{account_id}, $f->{q});
        };
        if (!$ai) {
            # A bug in the AI path must not take the search page down with
            # it. Logged loudly, invisible to the user beyond the notice.
            $c->app->log->error("ai: answer() died: $@");
            $ai = { state => 'api_error', answer => '', results => [] };
        }
    }

    return $c->render(
        template   => 'index',
        email      => $email,
        account    => $acct,
        f          => $f,
        mail       => $mail,
        drive      => $drive,
        ai         => $ai,
        ai_state   => $ai_state,
        mailboxes  => ($acct ? $c->app->query->mailboxes($acct->{account_id}) : []),
        counts     => ($acct ? $c->app->query->counts($acct->{account_id})    : {}),
        mime_cats  => Homelab::Search::Mime::categories(),
        mime_groups => _mime_groups($acct ? $c->app->query->mime_facets($acct->{account_id}) : []),
        # Per-type metadata for the file results on this page, in ONE query
        # rather than one per row. 'all' here, not 'safe': this is the
        # owner's own page, and the sensitive filter exists for what leaves
        # the building, not for what they can already see.
        drive_meta => (($acct && @$drive)
            ? $c->app->query->metadata_for($acct->{account_id},
                  [ map { $_->{drive_item_id} } @$drive ], 'all')
            : {}),
        # Who is in the photo, and where its owner filed it.
        #
        # This used to arrive in drive_meta, because tagged people were one
        # joined string in a metadata row. Normalizing them into
        # search.people and search.photo_faces was right, and it moved the
        # fact out of the one place every consumer read from -- so the page
        # silently stopped showing it, and a photo matched on a name gave no
        # hint why. faces_and_tags_for was written for this and then never
        # called by anything.
        drive_faces => (($acct && @$drive)
            ? $c->app->query->faces_and_tags_for($acct->{account_id},
                  [ map { $_->{drive_item_id} } @$drive ])
            : {}),
        searched   => _searched($f),
    );
}

# Turning AI mode on or off. A POST, because it changes something.
#
# THE CONSENT IS ENFORCED HERE AND IN AI.pm, not in the template. Hiding a
# toggle is a UI nicety; the gate that matters is that answer() re-checks
# consent itself, so calling /?ai=1 directly with a valid session and no
# consent gets `not_consented` and nothing else.
sub ai_consent ($c) {
    my ($email, $acct) = _scope($c);
    return $c->redirect_to('/login') unless $email;
    return $c->redirect_to('/') unless $acct;

    # Turning something privacy-affecting OFF is never harder than turning
    # it on: no confirmation, no second step, same endpoint.
    my $granted = $c->param('granted') ? 1 : 0;

    # The hash recorded is of the notice THIS PAGE rendered. A client that
    # posts a stale hash agreed to wording we are no longer showing, so it
    # is refused rather than silently upgraded.
    if ($granted) {
        my $seen = $c->param('notice_sha256') // '';
        my $want = Homelab::Search::AI::Consent::notice_sha256();
        if (lc $seen ne $want) {
            $c->app->log->warn("ai: consent posted for stale notice by $email");
            return $c->redirect_to('/?ai_notice=stale');
        }
    }

    Homelab::Search::AI::Consent::record(
        $c->app->query, $acct->{account_id}, $granted, $c->req->headers->user_agent);

    my $q = $c->param('q') // '';
    return $c->redirect_to($granted && length $q
        ? '/?ai=1&q=' . url_escape($q)
        : (length $q ? '/?q=' . url_escape($q) : '/'));
}

# The account's own leaf types, grouped for the picker.
#
# Built here rather than in the template because a type belongs to SEVERAL
# categories now -- text/csv is Text and a Spreadsheet -- so this is a
# fan-out, a per-group name collision pass and an "everything else" bucket,
# which is three pieces of logic that have no business inside an .ep.
#
# A type appears under every category it belongs to. The template renders
# only the FIRST copy with a form name, so one type is never submitted
# twice, and the script keeps the copies ticked together.
sub _mime_groups ($facets) {
    my (%by_cat, @loose);
    for my $f (@$facets) {
        my $keys = Homelab::Search::Mime::categories_of($f->{mime});
        if (@$keys) { push @{ $by_cat{$_} }, $f for @$keys }
        else        { push @loose, $f }
    }

    my @groups;
    for my $cat (@{ Homelab::Search::Mime::categories() },
                 { key => '', label => 'Everything else' }) {
        my $list = length $cat->{key} ? ($by_cat{ $cat->{key} } || []) : \@loose;
        next unless @$list;
        # friendly_set resolves names that collide WITHIN this group --
        # image/jpeg and image/jpg are both "JPEG image .jpg", and two
        # identical rows with different counts is worse than no friendly
        # name at all.
        my $named = Homelab::Search::Mime::friendly_set([ map { $_->{mime} } @$list ]);
        # Per-source counts ride along so the picker can drop a type that
        # cannot match the sources currently ticked.
        for my $i (0 .. $#$list) {
            $named->[$i]{$_} = $list->[$i]{$_} for qw(n drive_n mail_n);
        }
        push @groups, { key => $cat->{key}, label => $cat->{label}, rows => $named };
    }
    return \@groups;
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

# Why a file cannot be served, told apart properly.
#
# "no longer on disk" was reported for all three of these, and for the one
# that mattered it was the wrong answer: drive stored every blob over 256 KB
# as 0600, so this app (uid 5000) got EACCES on exactly the photos and PDFs
# people click, and said the file was gone. It was not gone; it was ours to
# fix. An unreadable file is an operator fault, it gets a 503 and a logged
# error, and it never again looks to a user like their data vanished.
sub _unservable ($c, $path, $what) {
    return ("that $what is not available", 404) unless defined $path;
    return () if -r $path;
    unless (-e $path) {
        $c->app->log->info("serve: $what gone from disk: $path");
        return ("that $what is no longer on disk", 410);
    }
    $c->app->log->error("serve: $what is present but UNREADABLE by uid $> -- "
        . "check the blob's mode/group and the export: $path");
    return ("that $what is on disk but this server cannot read it; "
        . "the error has been logged for an administrator", 503);
}

sub mail_preview ($c) {
    my ($email, $acct) = _scope($c);
    return $c->render(text => 'not logged in', status => 401) unless $email && $acct;
    my $m = $c->app->query->message($acct->{account_id}, $c->stash('id'))
        or return $c->render(text => 'not found', status => 404);

    my $path = _message_path($c, $m);
    my ($why, $status) = _unservable($c, $path, 'message');
    return $c->render(text => $why, status => $status) if $why;

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
    my ($why, $status) = _unservable($c, $path, 'message');
    return $c->render(text => $why, status => $status) if $why;

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
    my ($why, $status) = _unservable($c, $path, 'file');
    return $c->render(text => $why, status => $status) if $why;

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
