package Homelab::SSO::Controller::Reset;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::UserAgent;
use Homelab::Common::Registry qw(system_agent_token);
use Homelab::SSO::Mailer qw(send_mail);

# Self-service password reset, browser-facing, served from the same
# public login.<domain> vhost as the SSO login page itself (which is
# where the "Forgot password?" link lives). The account/token logic and
# the actual password write are homelab-api's job (it owns api.users +
# api.password_resets) -- this controller only renders the pages, sends
# the email, and relays to homelab-api's own system_agent-gated
# /auth/password-reset/{request,confirm} endpoints. The reset token
# NEVER grants API access; it only authorizes one password change.

# Server-to-server call to a system_agent-gated homelab-api endpoint,
# presenting this host's homelab-agent credential -- same fresh-token-
# retry-on-transport-error-or-403 pattern homelab-api's own
# _consume_invite documents (homelab-agent rotates the token each
# heartbeat; the callee verifies via introspect -- a real race). Returns
# the decoded JSON body on any real HTTP response, or undef on transport
# failure / missing credential.
sub _api_call ($self, $method, $path, $json = undef) {
    my $url = $self->app->api_base . $path;
    my $ua  = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
    my $tx;
    for my $attempt (1, 2) {
        my $agent_token = eval { system_agent_token() };
        return undef unless $agent_token;
        my $headers = { Authorization => "Bearer $agent_token" };
        $tx = $method eq 'GET' ? $ua->get($url, $headers) : $ua->post($url, $headers, json => $json);
        last unless $tx->error && (!$tx->error->{code} || $tx->error->{code} == 403);
    }
    return undef if $tx->error && !eval { $tx->res->json };
    return eval { $tx->res->json };
}

# GET /forgot -- the "enter your login" form.
sub forgot ($self) {
    $self->render('reset/forgot', error => undef);
}

# POST /forgot {email} -- always renders the SAME uniform confirmation,
# whatever the real outcome (account missing, no recovery address on
# file, or a link genuinely sent), so this can't be used to enumerate
# which logins exist or which have a recovery address. Only when
# homelab-api actually mints a token AND a recovery address exists AND
# this instance has a working mailer do we send the email.
sub forgot_submit ($self) {
    my $email = lc($self->param('email') // '');
    $email =~ s/^\s+|\s+$//g;

    if (length $email) {
        my $res = $self->_api_call('POST', '/api/v1/auth/password-reset/request', { email => $email });
        if ($res && $res->{token} && $res->{recovery_email}) {
            $self->_send_reset_email($res->{recovery_email}, $res->{token});
        }
    }
    return $self->render('reset/forgot_sent');
}

sub _send_reset_email ($self, $to, $token) {
    my $base = $self->app->public_base_url;
    my $mcfg = $self->app->mailer_config // {};
    unless ($base && $mcfg->{email} && $mcfg->{smtp_password}) {
        $self->app->log->warn('homelab-sso: password-reset email not sent -- public_base_url or mailer config missing');
        return;
    }
    my $link = "$base/reset/$token";
    eval {
        send_mail(
            smtp_host => $mcfg->{smtp_host} // '127.0.0.1', smtp_port => $mcfg->{smtp_port} // 587,
            from_email => $mcfg->{email}, from_password => $mcfg->{smtp_password},
            to => $to, subject => 'Reset your Homelab password',
            body => "Someone asked to reset the password for your Homelab account.\n\n"
                  . "If it was you, open this link to choose a new password:\n\n$link\n\n"
                  . "The link expires in 1 hour and can be used once. If you didn't ask "
                  . "for this, you can ignore this email -- your password stays unchanged.",
        );
    };
    $self->app->log->warn("homelab-sso: reset email to $to failed: $@") if $@;
}

# GET /reset/:token -- the "choose a new password" form. Deliberately
# renders the form WITHOUT pre-validating the token (rendering a "bad
# token" page for a GET would leak whether a token is live); the token
# is validated for real on POST.
sub reset ($self) {
    $self->render('reset/reset', token => $self->stash('token'), error => undef);
}

# POST /reset/:token {password, password_confirm}
sub reset_submit ($self) {
    my $token    = $self->stash('token');
    my $password = $self->param('password') // '';
    my $confirm  = $self->param('password_confirm') // '';

    my $render_err = sub ($msg) { $self->render('reset/reset', token => $token, error => $msg) };
    return $render_err->('Password must be at least 8 characters.') if length($password) < 8;
    return $render_err->('The two passwords do not match.')          if $password ne $confirm;

    my $res = $self->_api_call('POST', '/api/v1/auth/password-reset/confirm',
        { token => $token, password => $password });
    return $render_err->('Something went wrong. Please request a new reset link and try again.')
        unless $res;
    return $render_err->($res->{error} // 'This reset link is invalid or has expired. Please request a new one.')
        unless $res->{ok};

    return $self->render('reset/done');
}

1;
