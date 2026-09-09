package Homelab::Common::SSOClient;
use Mojo::Base -strict;
use Mojo::UserAgent;
use Exporter 'import';

our @EXPORT_OK = qw(exchange_code);

# Talks to homelab-sso, not homelab-api directly — kept as its own
# module (mirroring Homelab::Common::AuthClient's one-module-per-
# upstream-service shape) rather than folded into AuthClient, since a
# relying party's OIDC code exchange and homelab-api's own auth
# endpoints are different upstream services with different contracts.
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);

# Server-to-server step of the authorization-code flow: a relying party
# (homelab-drive, or any future Perl-based homelab-* web app) that just
# received `?code=...` on its /oauth/callback exchanges it here for the
# actual access_token/refresh_token — see ../../sso/README.md for the
# full flow this is one half of. Same success/_status response shape as
# AuthClient's login()/refresh(), except the JSON body's own keys are
# left as-is (access_token/refresh_token/expires_in, not token/
# refresh_token) since that's the real OAuth token-endpoint contract,
# not homelab-api's own login response shape.
#
# exchange_code($code, sso_base => ..., client_id => ..., client_secret => ..., redirect_uri => ...)
sub exchange_code {
    my ($code, %opts) = @_;
    my $sso_base      = $opts{sso_base}      // die "exchange_code(): sso_base required\n";
    my $client_id     = $opts{client_id}     // die "exchange_code(): client_id required\n";
    my $client_secret = $opts{client_secret} // die "exchange_code(): client_secret required\n";
    my $redirect_uri  = $opts{redirect_uri}  // die "exchange_code(): redirect_uri required\n";

    my $tx = $UA->post("$sso_base/oauth/token", form => {
        grant_type    => 'authorization_code',
        code          => $code,
        client_id     => $client_id,
        client_secret => $client_secret,
        redirect_uri  => $redirect_uri,
    });
    my $err = $tx->error;
    return { success => 0, error => $err->{message} // 'connection error', _status => 0 }
        if $err && !$err->{code};

    my $res  = $tx->result;
    my $body = eval { $res->json } // {};
    $body->{_status} = $res->code;
    $body->{success} = ($res->code == 200) ? 1 : 0;
    return $body;
}

1;
