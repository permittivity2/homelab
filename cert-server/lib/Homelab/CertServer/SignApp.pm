package Homelab::CertServer::SignApp;
use Mojo::Base 'Mojolicious', -signatures;
use MIME::Base64 qw(encode_base64);

use Homelab::Common::AppleProfile qw(build_mail_profile);
use Homelab::Common::AuthClient qw(introspect);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::CertServer::Signer qw(load_sign_config lineage_names signable_lineages sign_profile_bytes);

our $VERSION = '0.1.0';

# The signing endpoint. One instance, on the certificate issuer, because
# that is the only host where signing adds no new key exposure at all --
# see Homelab::CertServer::Signer for the full argument.
#
# NOT PUBLIC, and not fronted by homelab-webproxy. It listens on the
# service plane and every route carries its own authentication, because
# "it is only reachable internally" has been the premise of enough
# incidents in this fleet to not be a security control.
#
# Callers: homelab-invite (30/31/32) and homelab-accountmanage (27/28/29)
# via Homelab::Common::ProfileSigner. Each presents its own host's
# homelab-agent credential -- the same system_agent mechanism every other
# service-to-service call here uses, so there is no new secret to
# distribute to the pool and nothing per-host to get wrong.

sub startup ($self) {
    my $cfg = load_sign_config();
    $self->config($cfg);

    my $srv = $cfg->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2516'],
        workers  => $srv->{workers} // 2,
        pid_file => $srv->{pid_file} // '/run/homelab-cert-sign/hypnotoad.pid',
    });

    # Unhealthy when NOTHING is signable: that is the state where every
    # client silently falls back to unsigned profiles, which is exactly
    # the state worth a red light rather than a quiet degradation.
    mount_health_route($self, service => 'cert-sign', check => sub {
        my $ready = grep { $$_{ready} } @{ signable_lineages($self->config) };
        return $ready ? 1 : 0;
    });

    # NO register_recurring() here, unlike every other HTTP service in
    # this family. Two reasons, and the second is the decisive one:
    # nothing routes to this through homelab-api's gateway (its only
    # callers address it directly), and registering needs this host's
    # homelab-agent credential, which is 0600 homelab:homelab -- the
    # whole point of running as an unprivileged user of its own is not
    # being able to read files like that. Fleet visibility comes from
    # /etc/homelab/services/cert-sign.yml, which the local agent reads
    # on this host's behalf.

    # Same shape as homelab-invite's authenticated_system_agent: this
    # service does not hold the JWT signing secret, so it asks homelab-api
    # to introspect the presented token and checks the role in the answer.
    $self->helper(require_system_agent => sub ($c) {
        my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
        unless ($jwt) {
            $c->render(json => { error => 'authentication required' }, status => 401);
            return undef;
        }
        my $result = introspect($jwt, api_base => $self->config->{api_base});
        unless ($result && grep { $_ eq 'system_agent' } @{ $result->{roles} // [] }) {
            $c->render(json => { error => 'system_agent role required' }, status => 403);
            return undef;
        }
        return $result->{email} // 'system_agent';
    });

    my $r = $self->routes;
    $r->post('/internal/v1/sign/apple-mail-profile' => sub ($c) { $self->_sign_apple($c) });
    $r->get('/internal/v1/sign/lineages'            => sub ($c) { $self->_lineages($c) });

    return;
}

# GET /internal/v1/sign/lineages -- what this host can sign with, and
# when each signing certificate expires. The expiry is the point: a
# lapsed one degrades silently to unsigned profiles, so it needs to be
# visible from outside.
sub _lineages ($self, $c) {
    $c->require_system_agent or return;
    return $c->render(json => { lineages => signable_lineages($self->config) });
}

# Every field that reaches the profile is checked here, not in
# AppleProfile. The module escapes XML correctly; this is about not
# letting a caller put arbitrary text in front of someone's eyes on an
# iOS install screen, and about failing loudly on a typo rather than
# signing a profile that points a mail client at the wrong host.
sub _clean ($self, $body) {
    my %out;

    my $email = $body->{email} // '';
    return (undef, 'email is required and must look like an address')
        unless $email =~ /\A[^\s\@,;<>"]+\@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}\z/
            && length($email) <= 254;
    $out{email} = $email;

    for my $k (qw(imap_host smtp_host)) {
        my $v = $body->{$k} // '';
        return (undef, "$k is required and must be a hostname")
            unless length($v) && length($v) <= 253
                && $v =~ /\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/;
        $out{$k} = $v;
    }

    for my $k (qw(imap_port smtp_port)) {
        my $v = $body->{$k};
        return (undef, "$k must be a port number")
            unless defined $v && $v =~ /\A[0-9]{1,5}\z/ && $v >= 1 && $v <= 65535;
        $out{$k} = 0 + $v;
    }

    # Free text, so bounded and stripped of control characters -- these
    # become the account name in Mail and the organization line on the
    # install screen.
    for my $k (qw(account_label organization display_name)) {
        my $v = $body->{$k};
        next unless defined $v && length $v;
        return (undef, "$k is too long") if length($v) > 120;
        return (undef, "$k contains control characters") if $v =~ /[\x00-\x08\x0a-\x1f\x7f]/;
        $out{$k} = $v;
    }

    return (\%out, undef);
}

# POST /internal/v1/sign/apple-mail-profile
#
# Takes profile PARAMETERS, not profile bytes. See
# Homelab::CertServer::Signer: signing submitted bytes would make this a
# general-purpose signing oracle for a key that also terminates TLS.
sub _sign_apple ($self, $c) {
    my $caller = $c->require_system_agent or return;

    my $body = $c->req->json;
    return $c->render(json => { error => 'JSON object body required' }, status => 400)
        unless ref $body eq 'HASH';

    my $lineage = $body->{lineage} // '';
    # Checked here as well as in sign_profile_bytes, to answer with 403
    # and a clear reason rather than a 500 out of the signing layer.
    return $c->render(json => { error => 'lineage is not available for signing here' }, status => 403)
        unless length $lineage && grep { $_ eq $lineage } @{ lineage_names($self->config) };

    my ($p, $why) = $self->_clean($body);
    return $c->render(json => { error => $why }, status => 400) unless $p;

    my $xml = eval {
        build_mail_profile(
            email         => $p->{email},
            imap_host     => $p->{imap_host}, imap_port => $p->{imap_port},
            smtp_host     => $p->{smtp_host}, smtp_port => $p->{smtp_port},
            account_label => $p->{account_label},
            organization  => $p->{organization},
            display_name  => $p->{display_name} // $p->{email},
        );
    };
    unless (defined $xml && length $xml) {
        $self->log->error("cert-sign: could not build a profile for $p->{email}: $@");
        return $c->render(json => { error => 'could not build the profile' }, status => 500);
    }

    my ($der, $meta) = eval { sign_profile_bytes($lineage, $xml, $self->config) };
    unless ($der) {
        my $err = $@ || 'unknown signing failure';
        $err =~ s/\s+$//;
        $self->log->error("cert-sign: $err");
        # 503, not 500: the caller's correct response is to serve the
        # profile unsigned and try again later, which is what a
        # temporary-failure code tells it.
        return $c->render(json => { error => $err }, status => 503);
    }

    # One line per signature, deliberately. This is a host signing
    # documents on another host's behalf; who asked for what, and with
    # which lineage, is exactly what an audit of that wants.
    $self->log->info("cert-sign: signed a mail profile for $p->{email} with $lineage"
        . " (requested by $caller)");

    return $c->render(json => {
        ok          => \1,
        lineage     => $lineage,
        signer      => $meta->{subject},
        not_after   => $meta->{not_after},
        profile_b64 => encode_base64($der, ''),
    });
}

1;

__END__

=head1 NAME

Homelab::CertServer::SignApp - the issuer-side Apple-profile signing endpoint

=cut
