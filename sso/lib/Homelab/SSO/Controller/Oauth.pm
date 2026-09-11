package Homelab::SSO::Controller::Oauth;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::URL;
use Mojo::Util qw(secure_compare);

use Homelab::Common::AuthClient qw(login introspect refresh revoke);

# One-time authorization codes live in Postgres (sso.oauth_codes), not
# in-process -- a code minted by one hypnotoad worker must be visible
# when a different worker handles the /oauth/token exchange. See
# migrations/001-oauth-codes.sql.
#
# Deliberately NO shared cross-app "session epoch" cookie here, unlike
# the older cross-app-logout mechanism this design replaces (see
# logout() below) -- that cookie was a real, proven-fragile point of
# failure (browser privacy features silently blocking it broke logout
# propagation in production once already). Logout here works instead
# because homelab-api 0.1.2+ can revoke a session's access token
# immediately (api/migrations/005-sessions.sql) and every relying party
# already re-verifies via introspect() on its own -- see this repo's
# CLAUDE.md and homelab-api's README for the full reasoning. Nothing
# below needs to know which OTHER apps have a live session at all.

sub _find_client ($c, $client_id) {
    return undef unless defined $client_id;
    for my $client (@{ $c->app->oauth_clients }) {
        return $client if $client->{client_id} eq $client_id;
    }
    return undef;
}

sub _random_code {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $code = '';
    $code .= $chars[int(rand(@chars))] for 1 .. 48;
    return $code;
}

use constant CODE_TTL_SECONDS => 60;

sub _store_code ($c, %fields) {
    $c->app->pg->db->query(
        q{INSERT INTO sso.oauth_codes
            (code, client_id, email, redirect_uri, scope, jwt, refresh_token, expires_in, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW() + (? * INTERVAL '1 second'))},
        @fields{qw(code client_id email redirect_uri scope jwt refresh_token expires_in)},
        CODE_TTL_SECONDS,
    );
    return;
}

# One-time use: atomically deletes and returns the row so a concurrent
# double-exchange (or a replay) can't both succeed.
sub _take_code ($c, $code) {
    return $c->app->pg->db->query(
        q{DELETE FROM sso.oauth_codes WHERE code = ? AND expires_at >= NOW() RETURNING *},
        $code,
    )->hash;
}

sub _purge_expired ($c) {
    $c->app->pg->db->query(q{DELETE FROM sso.oauth_codes WHERE expires_at < NOW()});
    return;
}

# Mints a one-time code for the given tokens and redirects the browser
# back to the client with it -- shared by both the "already has an IdP
# session" fast path and the "just typed a password" path.
sub _issue_code_and_redirect ($c, $client_id, $redirect_uri, $state, $email, $scope, $jwt, $refresh_token, $expires_in) {
    _purge_expired($c);
    my $code = _random_code();
    _store_code($c,
        code => $code, client_id => $client_id, email => $email, redirect_uri => $redirect_uri,
        scope => $scope, jwt => $jwt, refresh_token => $refresh_token, expires_in => $expires_in,
    );

    my $target = Mojo::URL->new($redirect_uri);
    $target->query->append(code => $code, state => $state);
    $c->redirect_to($target);
}

# Establishes (or refreshes) the IdP session -- not scoped to any one
# client, since a valid session should let a request for *any*
# registered client skip the login form. This is what makes it real SSO
# instead of a per-app login.
sub _establish_session ($c, $jwt, $refresh_token, $email) {
    $c->session(jwt => $jwt, refresh_token => $refresh_token, email => $email);
}

# Is the given URL's origin (scheme+host+port) one of our registered
# clients' redirect_uri origins? Looser than the OAuth redirect_uri
# check (which requires an exact match) -- a sensible post-logout
# landing page reasonably differs in path from the OAuth callback path.
# This is what stands between /logout and being an open redirect.
sub _origin_allowed ($c, $url) {
    my $target = Mojo::URL->new($url);
    return 0 unless $target->scheme && $target->host;
    for my $client (@{ $c->app->oauth_clients }) {
        my $reg = Mojo::URL->new($client->{redirect_uri});
        return 1 if $reg->scheme eq $target->scheme
            && $reg->host eq $target->host
            && ($reg->port // '') eq ($target->port // '');
    }
    return 0;
}

# GET /oauth/authorize?response_type=code&client_id=...&redirect_uri=...&state=...
sub authorize ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';
    my $scope        = $c->param('scope') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error', status => 400,
            message => 'Unknown client or redirect_uri.',
        );
    }

    # Already have a live IdP session? Skip the form entirely.
    if (my $jwt = $c->session('jwt')) {
        my $info = introspect($jwt, api_base => $c->app->api_base);
        if ($info && $info->{email}) {
            return _issue_code_and_redirect(
                $c, $client_id, $redirect_uri, $state, $info->{email}, $scope,
                $jwt, $c->session('refresh_token'), $c->app->config->{jwt_expiry_hint} // 1800,
            );
        }

        # JWT's expired/invalid -- try a silent refresh before giving up.
        if (my $refresh_token = $c->session('refresh_token')) {
            my $result = refresh($refresh_token, api_base => $c->app->api_base);
            if ($result->{success}) {
                _establish_session($c, $result->{token}, $result->{refresh_token}, $c->session('email'));
                return _issue_code_and_redirect(
                    $c, $client_id, $redirect_uri, $state, $c->session('email'), $scope,
                    $result->{token}, $result->{refresh_token}, $result->{expires_in},
                );
            }
        }

        # Both the JWT and the refresh attempt failed -- the session is
        # dead, clear it so we don't keep retrying it on every request.
        $c->session(expires => 1);
    }

    $c->render(
        template => 'oauth/login', error => undef,
        client_id => $client_id, redirect_uri => $redirect_uri, state => $state, scope => $scope,
    );
}

# POST /oauth/authorize -- credential submission
sub authorize_submit ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';
    my $scope        = $c->param('scope') // '';
    my $email        = $c->param('email')    // '';
    my $password     = $c->param('password') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error', status => 400,
            message => 'Unknown client or redirect_uri.',
        );
    }

    my $render_form_error = sub ($msg) {
        $c->render(
            template => 'oauth/login', error => $msg,
            client_id => $client_id, redirect_uri => $redirect_uri, state => $state, scope => $scope,
        );
    };

    return $render_form_error->('Email and password are required.') unless $email && $password;

    # client_user_agent/client_ip: this app's own directly-observed
    # values from the real browser's form submission, right here, right
    # now -- relayed through so homelab-api's session tracking records
    # the actual browser/device, not this backend's own server-to-server
    # call to it (see Homelab::Common::AuthClient::login's own comment).
    my $result = login(
        $email, $password, api_base => $c->app->api_base,
        client_user_agent => $c->req->headers->user_agent,
        client_ip         => $c->tx->remote_address,
    );
    unless ($result->{success}) {
        my $msg = ($result->{_status} // 0) == 429
            ? 'Too many login attempts. Please wait 15 minutes.'
            : ($result->{error} // 'Login failed. Check your email and password.');
        return $render_form_error->($msg);
    }

    _establish_session($c, $result->{token}, $result->{refresh_token}, $email);
    _issue_code_and_redirect(
        $c, $client_id, $redirect_uri, $state, $email, $scope,
        $result->{token}, $result->{refresh_token}, $result->{expires_in},
    );
}

# POST /oauth/token -- server-to-server code exchange, or refresh_token grant
sub token ($c) {
    my $grant_type    = $c->param('grant_type')    // '';
    my $code          = $c->param('code')          // '';
    my $client_id     = $c->param('client_id')     // '';
    my $client_secret = $c->param('client_secret') // '';
    my $redirect_uri  = $c->param('redirect_uri')  // '';

    return $c->render(json => { error => 'unsupported_grant_type' }, status => 400)
        unless $grant_type eq 'authorization_code' || $grant_type eq 'refresh_token';

    my $client = _find_client($c, $client_id);
    return $c->render(json => { error => 'invalid_client' }, status => 401)
        unless $client && secure_compare($client->{client_secret}, $client_secret);

    # refresh_token grant: a client nearing its cached access token's
    # expiry exchanges its refresh_token directly for a new one, without
    # a round-trip through /oauth/authorize. Pure pass-through to
    # homelab-api's own refresh -- same call authorize()'s own silent-
    # refresh fast path above makes.
    if ($grant_type eq 'refresh_token') {
        my $refresh_token = $c->param('refresh_token') // '';
        return $c->render(json => { error => 'invalid_request' }, status => 400)
            unless length $refresh_token;

        my $result = refresh($refresh_token, api_base => $c->app->api_base);
        return $c->render(json => { error => 'invalid_grant' }, status => 400)
            unless $result->{success};

        return $c->render(json => {
            access_token  => $result->{token},
            refresh_token => $result->{refresh_token},
            token_type    => 'Bearer',
            expires_in    => $result->{expires_in},
        });
    }

    my $entry = _take_code($c, $code);
    unless ($entry
        && $entry->{client_id} eq $client_id
        && $entry->{redirect_uri} eq $redirect_uri)
    {
        return $c->render(json => { error => 'invalid_grant' }, status => 400);
    }

    return $c->render(json => {
        access_token  => $entry->{jwt},
        refresh_token => $entry->{refresh_token},
        token_type    => 'Bearer',
        expires_in    => $entry->{expires_in},
    });
}

# GET /oauth/userinfo -- Bearer-auth passthrough to homelab-api's
# introspect endpoint. This is what Roundcube's native OAuth support
# calls (oauth_identity_uri) to learn the logged-in user's email when
# no id_token is issued -- see roundcube/README.md; this deployment
# doesn't mint id_tokens (no RS256 signing key to manage) since nothing
# here needs one yet.
sub userinfo ($c) {
    my $auth_header = $c->req->headers->authorization // '';
    my ($jwt) = $auth_header =~ /^Bearer\s+(.+)$/;

    return $c->render(json => { error => 'Token required' }, status => 401) unless $jwt;

    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $c->render(json => { error => 'invalid or expired token' }, status => 401) unless $result;

    return $c->render(json => $result);
}

# GET /logout?redirect_uri=... -- single logout. Revokes the
# refresh_token via homelab-api (which, since homelab-api 0.1.2, also
# immediately revokes the access token's own session row -- see
# api/migrations/005-sessions.sql) and clears the local IdP session.
# That revocation is the ENTIRE cross-app propagation mechanism: every
# relying party re-checks introspect() on its own (homelab-drive on
# every request; homelab-roundcube via its native OAuth refresh/
# keep-alive hooks), so there is nothing else for this endpoint to
# actively notify -- no per-client backchannel-logout-uri list, no
# cross-app cookie.
sub logout ($c) {
    if (my $refresh_token = $c->session('refresh_token')) {
        eval { revoke($refresh_token, api_base => $c->app->api_base) };
    }
    $c->session(expires => 1);

    my $redirect_uri = $c->param('redirect_uri');
    if ($redirect_uri && _origin_allowed($c, $redirect_uri)) {
        return $c->redirect_to($redirect_uri);
    }

    $c->render(template => 'oauth/logged_out');
}

1;
