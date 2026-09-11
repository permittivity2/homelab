package Homelab::Common::AuthClient;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Exporter 'import';

our @EXPORT_OK = qw(introspect login refresh revoke);

# Verifies a bearer JWT against homelab-api's /api/v1/auth/introspect —
# the one place identity actually lives (see CLAUDE.md). Every feature
# that needs "who is this request from" calls this rather than
# verifying JWTs itself, so there's exactly one place that knows how to
# do that, same reasoning as the registry client.
#
# introspect($jwt, api_base => 'http://10.10.0.x:3000') => { email => ..., exp => ... } or undef
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

sub introspect {
    my ($jwt, %opts) = @_;
    my $api_base = $opts{api_base} // die "introspect(): api_base required\n";
    return undef unless $jwt;

    my $tx  = $UA->get("$api_base/api/v1/auth/introspect", { Authorization => "Bearer $jwt" });
    my $err = $tx->error;
    return undef if $err && !$err->{code};    # transport failure — treat as "not authenticated", don't die
    return undef unless $tx->result->code == 200;
    return $tx->result->json;
}

# Logs in against homelab-api's /api/v1/auth/login on behalf of a
# browser-facing BFF-style app (homelab-drive, later homelab-roundcube)
# that wants to hold the resulting token/refresh_token in its own
# session cookie rather than making the browser talk to homelab-api
# directly. Returns the decoded JSON body (success/token/refresh_token/...
# on success, error/_status on failure) — callers check `success`
# themselves rather than this module deciding what counts as an error,
# since e.g. a 409 on registration and a 401 on login mean different
# things to different callers.
#
# Optional client_user_agent/client_ip: this call is itself server-to-
# server (this module's own Mojo::UserAgent, running inside e.g.
# homelab-sso's backend) — without these, homelab-api's session-
# tracking (migrations/007-session-metadata.sql) would record THIS
# module's own request, not the real browser sitting behind the caller.
# homelab-sso's authorize_submit passes the actual submitting browser's
# own headers/remote_address through here for exactly that reason.
sub login {
    my ($email, $password, %opts) = @_;
    my $api_base = $opts{api_base} // die "login(): api_base required\n";

    my %payload = (email => $email, password => $password);
    $payload{client_user_agent} = $opts{client_user_agent} if defined $opts{client_user_agent};
    $payload{client_ip}         = $opts{client_ip}         if defined $opts{client_ip};

    my $tx  = $UA->post("$api_base/api/v1/auth/login", json => \%payload);
    my $err = $tx->error;
    return { success => 0, error => $err->{message} // 'connection error', _status => 0 }
        if $err && !$err->{code};

    my $res  = $tx->result;
    my $body = eval { $res->json } // {};
    $body->{_status} = $res->code;
    $body->{success} = ($res->code == 200) ? 1 : 0;
    return $body;
}

# Exchanges a refresh_token for a new token/refresh_token pair via
# homelab-api's /api/v1/auth/refresh — used by homelab-sso's silent-
# session-resume path (an IdP session whose cached JWT has expired but
# whose refresh_token hasn't) and by any BFF-style app that wants the
# same "don't force a re-login just because the short-lived access
# token expired" behavior. Same success/_status shape as login().
sub refresh {
    my ($refresh_token, %opts) = @_;
    my $api_base = $opts{api_base} // die "refresh(): api_base required\n";

    my $tx  = $UA->post("$api_base/api/v1/auth/refresh", json => { refresh_token => $refresh_token });
    my $err = $tx->error;
    return { success => 0, error => $err->{message} // 'connection error', _status => 0 }
        if $err && !$err->{code};

    my $res  = $tx->result;
    my $body = eval { $res->json } // {};
    $body->{_status} = $res->code;
    $body->{success} = ($res->code == 200) ? 1 : 0;
    return $body;
}

# Revokes a refresh_token (and, since homelab-api 0.1.2's session
# tracking, the access token/jti it's associated with too — see
# api/migrations/005-sessions.sql) via /api/v1/auth/logout.
# Best-effort by design: callers (homelab-sso's own /logout) should
# clear their local session regardless of whether this succeeds, not
# block logout on it.
sub revoke {
    my ($refresh_token, %opts) = @_;
    my $api_base = $opts{api_base} // die "revoke(): api_base required\n";

    my $tx = $UA->post("$api_base/api/v1/auth/logout", json => { refresh_token => $refresh_token });
    my $err = $tx->error;
    return 0 if $err && !$err->{code};
    return $tx->result->code == 200 ? 1 : 0;
}

1;
