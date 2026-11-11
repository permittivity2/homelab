package Homelab::BlockLink::App::Controller::BlockLink;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(secure_compare url_escape);
use Homelab::Common::Registry qw(lookup system_agent_token);
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::Common::SSOClient qw(exchange_code);
use Homelab::BlockLink::Visibility qw(view refused_addresses);

my $API_UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

sub _home_domain ($email) {
    my ($domain) = $email =~ /\@(.+)$/;
    return $domain // '';
}

# Account override wins if set; otherwise the caller's own home
# domain's default; otherwise a hardcoded off/header fallback if
# neither row exists at all (a domain that's never touched this
# feature is off by default, matching domain_settings' own DEFAULT
# FALSE -- this branch only matters before any row has ever been
# written for that domain).
sub _effective_setting ($c, $email) {
    my $account = $c->app->pg->db->query(
        'SELECT enabled FROM block_link.account_settings WHERE user_email = ?', $email,
    )->hash;
    my $domain = $c->app->pg->db->query(
        'SELECT enabled, mode FROM block_link.domain_settings WHERE domain_name = ?', _home_domain($email),
    )->hash // { enabled => 0, mode => 'header' };

    my $enabled = (defined $account && defined $account->{enabled}) ? $account->{enabled} : $domain->{enabled};
    return { enabled => ($enabled ? \1 : \0), mode => $domain->{mode}, domain_default => ($domain->{enabled} ? \1 : \0) };
}

# GET /internal/v1/block-link/account
sub account_show ($c) {
    my $email = $c->authenticated_email_any or return;
    return $c->render(json => _effective_setting($c, $email));
}

# PUT /internal/v1/block-link/account {enabled}
# enabled: true/false sets an explicit override; null clears it back to
# "inherit the domain default".
sub account_set ($c) {
    my $email = $c->authenticated_email_any or return;
    my $body = $c->req->json // {};
    return $c->render(json => { error => 'enabled is required (true, false, or null to clear)' }, status => 400)
        unless exists $body->{enabled};

    $c->app->pg->db->query(
        q{INSERT INTO block_link.account_settings (user_email, enabled) VALUES (?, ?)
          ON CONFLICT (user_email) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = NOW()},
        $email, $body->{enabled},
    );
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => 'block_link.account_set', resource_type => 'block_link_account', resource_id => $email,
        source_service => 'homelab-block-link', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { enabled => $body->{enabled} },
    );
    return $c->render(json => _effective_setting($c, $email));
}

# GET /internal/v1/block-link/domains/:domain -- site_admin-only
sub domain_show ($c) {
    $c->authenticated_site_admin or return;
    my $row = $c->app->pg->db->query(
        'SELECT * FROM block_link.domain_settings WHERE domain_name = ?', $c->stash('domain'),
    )->hash // { domain_name => $c->stash('domain'), enabled => \0, mode => 'header' };
    return $c->render(json => $row);
}

# PUT /internal/v1/block-link/domains/:domain {enabled, mode}
sub domain_set ($c) {
    my $admin = $c->authenticated_site_admin or return;
    my $domain = $c->stash('domain');
    my $body = $c->req->json // {};
    my ($enabled, $mode) = @{$body}{qw(enabled mode)};
    return $c->render(json => { error => 'enabled and mode are required' }, status => 400)
        unless defined($enabled) && $mode;
    return $c->render(json => { error => "mode must be 'header', 'body', or 'both'" }, status => 400)
        unless grep { $_ eq $mode } qw(header body both);

    my $row = $c->app->pg->db->query(
        q{INSERT INTO block_link.domain_settings (domain_name, enabled, mode, updated_by_email)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (domain_name) DO UPDATE
              SET enabled = EXCLUDED.enabled, mode = EXCLUDED.mode,
                  updated_by_email = EXCLUDED.updated_by_email, updated_at = NOW()
          RETURNING *},
        $domain, $enabled, $mode, $admin,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $admin, affected_user => $admin, jti => $c->stash('current_jti'),
        action => 'block_link.domain_set', resource_type => 'block_link_domain', resource_id => $domain,
        source_service => 'homelab-block-link', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { enabled => $enabled, mode => $mode },
    );
    return $c->render(json => $row);
}

# GET /l/:token -- the page a link in a delivered email opens. Sign-in
# required (post-cutover item 69, 0.1.6): the link alone is no credential,
# because the footer that carries it is quoted into every reply and forward.
#
# Nobody signed in here: straight to homelab-sso and back, BEFORE the link is
# looked up, so an anonymous visitor (a stranger holding a forwarded link, a
# mail gateway's link-prescanner) learns nothing from this site, not even
# whether the link is valid. Someone already signed in to webmail or
# myaccount passes through homelab-sso without seeing its form. The one
# exception to the redirect is a session that holds a token which no longer
# introspects (expired, revoked by a sign-out elsewhere, or the api cannot be
# asked just now): that gets the page with a Sign in button instead, so a
# sign-in that comes back and still cannot be checked never loops between
# the two sites.
#
# No DB mutation here, ever -- see README.md's "Why GET never mutates".
#
# What the page shows depends on who is looking -- see Visibility.pm for the
# rule and why it exists. Signed in as the link's account, it also shows that
# account's whole block list, read with the visitor's OWN token from the same
# api call myaccount uses; nothing here can read a list any other way.
sub show ($c) {
    my $token = $c->stash('token');
    my $me    = $c->session_email;
    unless (length $me) {
        return $c->redirect_to(_login_url($token)) if $c->app->sso && !$c->session('token');
        delete @{ $c->session }{qw(token refresh_token)};
        return $c->render(
            template   => 'manage',
            token      => $token,
            view       => view([], ''),
            add        => [],
            blocked    => [],
            list_error => 0,
            signed_in  => '',
            can_sign_in => ($c->app->sso ? 1 : 0),
            manage_url => $c->app->manage_account_url,
        );
    }

    my $row = $c->app->pg->db->query(
        q{SELECT *, (expires_at <= NOW()) AS is_expired FROM block_link.pending_links WHERE token = ?}, $token,
    )->hash;
    return _notice($c, 404, 'Invalid link', 'This management link is not valid.') unless $row;
    return _notice($c, 410, 'Link expired', 'This management link has expired.') if $row->{is_expired};

    # candidates is a JSONB column -- Mojo::Pg/DBD::Pg hand it back as
    # the raw JSON text, not an inflated arrayref, so it must be
    # decoded explicitly before use (real bug hit on first live GET,
    # not caught by t/basic.t since that test asserts on rendered HTML
    # content, not on this code path directly).
    my $view = view(decode_json($row->{candidates}), $me);

    my ($blocked, $list_error) = ([], 0);
    if ($view->{mode} eq 'owner') {
        $blocked = _my_block_list($c);
        $list_error = 1 unless $blocked;
        $blocked //= [];
    }
    # Already blocked is already done: on a later visit only what is left
    # is offered, and once nothing is left the add section is not drawn.
    my %already = map { lc($_) => 1 } @$blocked;
    my @add = grep { !$already{ lc $_->{address} } } @{ $view->{offer} };

    return $c->render(
        template   => 'manage',
        token      => $token,
        view       => $view,
        add        => \@add,
        blocked    => $blocked,
        list_error => $list_error,
        signed_in  => $me,
        can_sign_in => ($c->app->sso ? 1 : 0),
        manage_url => $c->app->manage_account_url,
    );
}

# Where a signed-out visitor is sent: a sign-in that comes back to this link.
sub _login_url ($token) {
    return '/login?next=' . url_escape("/l/$token");
}

# The signed-in account's blocked addresses, sorted the way the page first
# shows them (alphabetical, ignoring case), or undef if the api could not be
# asked. 'OK' rows are allow-list entries, not blocks -- homelab-domain-
# admin's own vocabulary: OK allows, every other action blocks.
sub _my_block_list ($c) {
    my $jwt = $c->session_jwt or return undef;
    my $tx = $API_UA->get($c->app->api_base . '/api/v1/domains/recipient-access/mine'
        => { Authorization => "Bearer $jwt" });
    return undef unless ($tx->res->code // 0) == 200;
    my $rows = eval { $tx->res->json };
    return undef unless ref $rows eq 'ARRAY';
    my %seen;
    return [
        sort { lc($a) cmp lc($b) || $a cmp $b }
        grep { !$seen{ lc $_ }++ }
        map  { $_->{recipient} }
        grep { ref $_ eq 'HASH' && length($_->{recipient} // '') && uc($_->{action} // '') ne 'OK' }
        @$rows
    ];
}

# POST /l/:token {block: [address, ...]} -- Add to Block List. Signed in
# only (post-cutover item 69, 0.1.6): the session is the credential, and the
# token only says which message. So the same guards as unblock, in the same
# order, before anything is looked up: the CSRF token the page was drawn
# with (the cookie alone can be made to travel cross-site; the page's token
# cannot), then a live sign-in. Then the link, then that the visitor is one
# of its accounts, then only what view() offers that account -- the same
# rule the page was drawn with. Calls homelab-domain-admin's own
# system_agent-gated on-behalf endpoint for each address -- this service
# never writes domainadmin.recipient_access directly (see README.md's
# architecture note: this is a new delivery path into an existing blocking
# mechanism, not a new one), and view() has already pinned every address to
# the signed-in account.
sub submit ($c) {
    my $csrf = $c->req->headers->header('X-CSRF-Token') // '';
    return $c->render(json => { error => 'This page is out of date. Reload it and try again.' }, status => 403)
        unless length $csrf && secure_compare($csrf, $c->csrf_token);
    my $me = $c->session_email;
    return $c->render(json => { error => 'Your sign-in has ended. Reload the page and sign in again.' }, status => 401)
        unless $me;

    my $token = $c->stash('token');
    my $row = $c->app->pg->db->query(
        q{SELECT * FROM block_link.pending_links WHERE token = ? AND expires_at > NOW()}, $token,
    )->hash;
    return $c->render(json => { error => 'this link is no longer valid' }, status => 410) unless $row;

    my $view = view(decode_json($row->{candidates}), $me);
    return $c->render(json => { error => 'This link is for another account.' }, status => 403)
        unless $view->{mode} eq 'owner';

    my $body = $c->req->json // {};
    my $list = ref $body->{block} eq 'ARRAY' ? $body->{block} : [];
    my %asked;
    my @asked = grep { !$asked{ lc $_ }++ } grep { defined($_) && !ref($_) && length($_) } @$list;
    return $c->render(json => { error => 'Tick at least one address to add.' }, status => 400) unless @asked;

    if (my @refused = @{ refused_addresses($view, \@asked) }) {
        my %main = map { lc($_->{address}) => 1 } @{ $view->{main} };
        my $error = (grep { $main{ lc $_ } } @refused)
            ? "Your account's main address can't be blocked: that would stop all of your mail."
            : 'These addresses can\'t be blocked from this link: ' . join(', ', @refused) . '.';
        return $c->render(json => { error => $error }, status => 403);
    }

    my $domain_admin = lookup('homelab-domain-admin', api_base => $c->app->api_base);
    return $c->render(json => { error => 'domain-admin service is not currently available' }, status => 502)
        unless $domain_admin && $domain_admin->{host} && $domain_admin->{port};

    my $agent_token = eval { system_agent_token() };
    return $c->render(json => { error => 'service credential unavailable' }, status => 502) unless $agent_token;

    my %offer = map { lc($_->{address}) => $_ } @{ $view->{offer} };
    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
    my (@done, @failed);
    for my $cand (map { $offer{ lc $_ } } @asked) {
        my $tx = $ua->post(
            "http://$domain_admin->{host}:$domain_admin->{port}/internal/v1/domains/recipient-access/on-behalf",
            { Authorization => "Bearer $agent_token" },
            json => {
                user_email => $cand->{account_email}, recipient => $cand->{address},
                action => 'REJECT', reason => 'blocked via inbox link',
            },
        );
        if ($tx->error) { push @failed, $cand->{address} } else { push @done, $cand->{address} }
    }
    return $c->render(json => { error => "could not block: @failed", blocked => \@done }, status => 502) if @failed;
    return $c->render(json => { ok => \1, blocked => \@done });
}

# POST /l/:token/unblock {address} -- signed in only. Takes one address off the
# signed-in account's own block list, with the visitor's OWN token and the
# same api call myaccount's Unblock button makes, which can only ever remove
# that account's own entries. Allowed only where the page draws the list --
# signed in as one of this link's accounts -- and only for an address that is
# on that list: an allow entry, or anything else, is not this page's to remove.
sub unblock ($c) {
    # Here the session cookie is the credential, so the request has to show it
    # came from this site's own page: the CSRF token drawn into it. Checked
    # before anything else is looked up.
    my $csrf = $c->req->headers->header('X-CSRF-Token') // '';
    return $c->render(json => { error => 'This page is out of date. Reload it and try again.' }, status => 403)
        unless length $csrf && secure_compare($csrf, $c->csrf_token);
    my $me = $c->session_email;
    return $c->render(json => { error => 'Your sign-in has ended. Reload the page and sign in again.' }, status => 401)
        unless $me;

    my $row = $c->app->pg->db->query(
        q{SELECT * FROM block_link.pending_links WHERE token = ? AND expires_at > NOW()}, $c->stash('token'),
    )->hash;
    return $c->render(json => { error => 'this link is no longer valid' }, status => 410) unless $row;
    return $c->render(json => { error => 'This link is for another account.' }, status => 403)
        unless view(decode_json($row->{candidates}), $me)->{mode} eq 'owner';

    my $address = ($c->req->json // {})->{address};
    return $c->render(json => { error => 'No address given.' }, status => 400)
        unless defined $address && !ref $address && length $address;

    my $list = _my_block_list($c);
    return $c->render(json => { error => "Your block list couldn't be read just now. Please try again." }, status => 502)
        unless $list;
    # The list's own spelling: the api removes an exact match only.
    my ($exact) = grep { lc($_) eq lc($address) } @$list;
    my $tx = defined $exact
        ? $API_UA->delete($c->app->api_base . '/api/v1/domains/recipient-access/mine/' . url_escape($exact)
            => { Authorization => 'Bearer ' . $c->session_jwt })
        : undef;
    my $code = $tx ? ($tx->res->code // 0) : 404;
    return $c->render(json => { ok => \1, unblocked => $exact }) if $code == 200;
    # Gone already (unblocked in myaccount meanwhile, say): what was asked for
    # is true, so the page takes it off the list and says so.
    return $c->render(json => { error => "$address isn't on your block list any more.", gone => \1 }, status => 404)
        if $code == 404;
    return $c->render(json => { error => "Couldn't unblock $address just now. Please try again." }, status => 502);
}

# Where a sign-in may return to: a link page on this site, or nowhere.
# Anything else -- another site, another path -- is an open redirect waiting
# to be used.
sub _safe_next ($next) {
    return (defined $next && $next =~ m{\A/l/[A-Za-z0-9_-]{16,128}\z}) ? $next : '';
}

# GET /login?next=/l/<token> -- start a sign-in through homelab-sso, then
# come back to the link that was open. Someone already signed in to webmail
# or myaccount passes straight through: homelab-sso skips its form when its
# own session is live.
sub login ($c) {
    my $sso = $c->app->sso or return $c->redirect_to('/');
    my $next = _safe_next($c->param('next'));
    my $state = Homelab::BlockLink::App::_random_hex(16);
    $c->session(oauth_state => $state, next => $next);
    return $c->redirect_to(Mojo::URL->new($sso->{base_url} . '/oauth/authorize')->query(
        response_type => 'code',
        client_id     => $sso->{client_id},
        redirect_uri  => $sso->{redirect_uri},
        state         => $state,
        scope         => 'openid',
    ));
}

sub oauth_callback ($c) {
    my $sso = $c->app->sso or return $c->redirect_to('/');
    my $code     = $c->param('code');
    my $state    = $c->param('state') // '';
    my $expected = $c->session('oauth_state') // '';
    my $next     = _safe_next($c->session('next'));
    delete @{ $c->session }{qw(oauth_state next)};

    return _notice($c, 400, 'Sign-in failed',
        'Sign-in expired or was not valid. Open the link from your email and try again.')
        unless $code && length $expected && secure_compare($state, $expected);

    my $r = exchange_code($code,
        sso_base      => $sso->{internal_base_url},
        client_id     => $sso->{client_id},
        client_secret => $sso->{client_secret},
        redirect_uri  => $sso->{redirect_uri},
    );
    return _notice($c, 502, 'Sign-in failed', 'Sign-in could not be completed just now. Please try again.')
        unless $r->{success} && $r->{access_token};

    $c->session(token => $r->{access_token}, refresh_token => $r->{refresh_token});
    return $c->redirect_to($next || '/');
}

# POST /logout -- forget this app's session and hand off to homelab-sso's
# single sign-out, which ends the session in every app, as everywhere else.
sub logout ($c) {
    $c->session(expires => 1);
    my $sso = $c->app->sso or return $c->redirect_to('/');
    return $c->redirect_to($sso->{base_url} . '/logout');
}

# The "invalid" and "expired" pages, on the same layout as the form.
sub _notice ($c, $status, $heading, $body) {
    return $c->render(template => 'notice', status => $status, heading => $heading, body => $body);
}

1;
