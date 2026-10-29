package Homelab::Accountmanage::App;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::URL;
use Mojo::UserAgent;

use Homelab::Common::Config qw(load_config);
use Homelab::Common::Health qw(mount_health_route);
use Homelab::Common::Registry qw(register_recurring);
use Homelab::Common::AuthClient qw(introspect);

# Account self-service + administration UI. Deliberately a THIN BFF: it
# owns no data and no database of its own -- it authenticates the browser
# via homelab-sso (same OAuth flow as homelab-drive) and then aggregates
# read/write calls to the existing services (homelab-api for account
# info/sessions/password, homelab-drive for storage usage, etc.) with the
# logged-in user's own token, rendering one themed dashboard. Everything
# it shows is gated by what that token is actually allowed to do.

has 'api_base';
has 'prometheus_base';
has 'grafana_base';
has 'sso_base';
has 'sso_internal_base';
has 'sso_client_id';
has 'sso_client_secret';
has 'sso_redirect_uri';
has 'public_base_url';
has 'device_config';
has 'profile_signing';
has 'mailer_config';

sub startup ($self) {
    # Templates land at /usr/share/homelab-accountmanage/templates, not
    # next to the /usr/bin entrypoint -- same HOMELAB_*_HOME convention as
    # every other homelab-* Mojolicious app.
    my $home = $ENV{HOMELAB_ACCOUNTMANAGE_HOME} // '/usr/share/homelab-accountmanage';
    $self->renderer->paths([("$home/templates"), @{ $self->renderer->paths }]);
    # Vendored front-end assets (e.g. Cytoscape.js for the admin Topology
    # tab) are served locally from $home/public -- never a CDN, so the app
    # stays self-contained on bare CT hosts. Static dispatch runs before
    # the router; these are non-secret libraries so unauthenticated access
    # to /vendor/* is fine.
    $self->static->paths([("$home/public"), @{ $self->static->paths }]);

    my $config = load_config('HOMELAB_ACCOUNTMANAGE_CONFIG', '/etc/homelab/accountmanage/config.yml');
    $self->config($config);

    # Shared web chrome (homelab-webtheme): the Silver Linings top bar, the
    # account dropdown, the footer, and theme.css/shell.js loaded from
    # static.mailmasker.org. Registering the plugin is all that is needed --
    # it appends its own template path and installs the helpers the shared
    # partials read, so `%= include 'homelab/header'` just works.
    #
    # user_email is a CODEREF, not a stash value: the dashboard renders with
    # `email => ...` while the login page has no signed-in address at all.
    # The resolver lets the shared header render the account menu on the one
    # and silently omit it on the other, with no per-template bookkeeping.
    $self->plugin('Homelab::WebTheme' => {
        app_name    => 'My Account',
        signout_url => '/logout',
        ($config->{web_theme}{base_url} ? (theme_base => $config->{web_theme}{base_url}) : ()),
        user_email  => sub ($c) { $c->stash('email') // '' },
        # No "Manage your account" entry -- this IS that page, and a menu
        # item linking to the page you are already on is just noise.
        menu_links  => [
            { href => 'https://mail.mailmasker.org/',  label => 'Email' },
            { href => 'https://drive.mailmasker.org/', label => 'Drive' },
        ],
    });

    my $srv = $config->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen} // 'http://127.0.0.1:2503'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/accountmanage-hypnotoad.pid',
        workers  => $srv->{workers} // 2,
    });

    $self->secrets([$config->{session}{secret} // die "config: session.secret is required\n"]);
    # Distinct cookie name (not Mojolicious's shared default) -- holds
    # real OAuth login state, same convention as homelab-drive/sso. If
    # this app is ever pooled, add sticky_cookie: homelab-accountmanage in
    # webproxy's sites.yml (no app change needed).
    $self->sessions->cookie_name('homelab-accountmanage');

    $self->api_base($config->{homelab_api}{base_url} // die "config: homelab_api.base_url is required\n");
    $self->public_base_url($config->{public_base_url} // die "config: public_base_url is required\n");
    # Optional, like prometheus/grafana below: a config file written
    # before this feature existed simply has no block, and the Mail
    # setup panel falls back to showing the derived settings with no
    # cross-device QR code. Never a reason to refuse to start.
    $self->device_config($config->{device_setup} // {});
    # Optional: where to have an Apple configuration profile signed (the
    # certificate issuer's narrow signing endpoint -- see
    # Homelab::Common::ProfileSigner). Absent or blank means profiles are
    # served unsigned, which installs fine and just shows red
    # "Unverified" on the iOS install screen.
    $self->profile_signing($config->{profile_signing} // {});
    # Optional: the system mailbox this app sends AS, for the site_admin
    # "resend the welcome email" action. Absent means that one action is
    # unavailable and says so; nothing else here sends mail.
    $self->mailer_config($config->{mailer} // {});
    # Optional: the fleet Prometheus (monitoring host) the metrics.view-gated
    # Metrics tab queries. If unset, that tab is simply never offered.
    $self->prometheus_base($config->{prometheus}{base_url} // '');
    # Optional: the fleet Grafana, reverse-proxied under /grafana so its full
    # dashboards are viewable INSIDE myaccount (same origin). metrics.view
    # gated like the summary; empty disables the embed.
    $self->grafana_base($config->{grafana}{base_url} // '');

    my $sso = $config->{sso} // die "config: sso.* is required (see config/accountmanage.example.yml)\n";
    $self->sso_base($sso->{base_url} // die "config: sso.base_url is required\n");
    # base_url is the BROWSER redirect target (must be the public SSO
    # vhost); internal_base_url is this app's own server-to-server
    # exchange_code() call (defaults to base_url for the single-host case).
    # Same split + gotcha as homelab-drive -- see its App.pm.
    $self->sso_internal_base($sso->{internal_base_url} // $sso->{base_url});
    $self->sso_client_id($sso->{client_id} // die "config: sso.client_id is required\n");
    $self->sso_client_secret($sso->{client_secret} // die "config: sso.client_secret is required\n");
    $self->sso_redirect_uri($sso->{redirect_uri} // die "config: sso.redirect_uri is required\n");

    # No DB of its own -- health is just "the process is up".
    mount_health_route($self, check => sub { 1 });

    my $me = $config->{registry} // {};
    if ($me->{host} && $me->{port}) {
        register_recurring(
            api_base => $self->api_base, feature_name => 'homelab-accountmanage',
            host => $me->{host}, port => $me->{port}, health_check_url => '/health',
            description => 'Account self-service + administration web UI',
            log => $self->log,
        );
    }

    my $r = $self->routes;
    $r->get('/')                 ->to('account#dashboard');
    $r->get('/login')            ->to('account#login_form');
    $r->get('/oauth/callback')   ->to('account#oauth_callback');
    $r->post('/logout')          ->to('account#logout');
    # Session management actions (browser posts here; we proxy to
    # homelab-api with the user's own token).
    $r->post('/sessions/:jti/revoke')->to('account#revoke_session');
    $r->post('/sessions/revoke-others')->to('account#revoke_others');
    # Security actions (proxy to homelab-api with the user's token).
    $r->post('/security/password')->to('account#change_password');
    $r->post('/security/recovery-email')->to('account#set_recovery_email');
    # Self-service Mail settings (any logged-in user; own account only).
    $r->get('/mail/self')       ->to('account#mail_self');
    $r->post('/mail/block-link')->to('account#mail_set_block_link');
    $r->post('/mail/block')     ->to('account#mail_block');
    $r->post('/mail/unblock')   ->to('account#mail_unblock');
    # Invites (self-service) + account activity (self-scoped audit).
    # Device setup. The .mobileconfig and the standalone page accept
    # EITHER a session OR a signed token, because the device that ends
    # up holding the mailbox is a phone that has never signed in here --
    # see _device_token_email below.
    $r->get('/devices/apple.mobileconfig')->to('account#device_apple_profile');
    $r->get('/devices/setup')             ->to('account#device_setup_page');
    $r->get('/devices/qr.svg')            ->to('account#device_qr');
    $r->get('/devices/setup-link')        ->to('account#device_setup_link');

    $r->get('/invites')        ->to('account#invites_list');
    $r->post('/invites/send')  ->to('account#invites_send');
    $r->post('/invites/revoke')->to('account#invites_revoke');
    $r->get('/activity')       ->to('account#activity_list');
    # Administration actions (site_admin; each re-checks + proxies to the
    # owning service with the admin's token).
    $r->post('/admin/users/:id/active')->to('account#admin_set_active');
    $r->post('/admin/drive-quota')     ->to('account#admin_drive_quota');
    $r->post('/admin/mail-quota')      ->to('account#admin_mail_quota');
    $r->post('/admin/block-link')      ->to('account#admin_block_link');
    $r->post('/admin/dkim')            ->to('account#admin_dkim');
    # Fleet metrics summary (JSON; metrics.view gated -- site_admin always,
    # plus any role granted metrics.view). Queries Prometheus server-side
    # and returns a curated fleet-health summary (no arbitrary PromQL from
    # the browser).
    $r->get('/admin/metrics/summary')->to('account#admin_metrics_summary');
    # Reverse-proxy the fleet Grafana under /grafana so its full dashboards
    # render INSIDE myaccount (same origin, works off-network), gated by
    # metrics.view. `any` catches every method + sub-path (assets, API).
    $r->any('/grafana')->to('account#grafana_proxy');
    $r->any('/grafana/*gpath')->to('account#grafana_proxy');
    # DKIM selector lifecycle detail (list + rotate/activate/retire/cancel), site_admin.
    $r->get('/admin/dkim/selectors')   ->to('account#admin_dkim_selectors');
    $r->post('/admin/dkim/rotate')     ->to('account#admin_dkim_rotate');
    $r->post('/admin/dkim/activate')   ->to('account#admin_dkim_activate');
    $r->post('/admin/dkim/retire')     ->to('account#admin_dkim_retire');
    $r->post('/admin/dkim/cancel')     ->to('account#admin_dkim_cancel');
    # Raw DNS record CRUD (list / upsert / delete), site_admin.
    $r->get('/admin/dns/records')      ->to('account#admin_dns_records');
    $r->post('/admin/dns/records')     ->to('account#admin_dns_record_set');
    $r->post('/admin/dns/records/delete')->to('account#admin_dns_record_delete');
    # Fleet status dashboard (read-only), site_admin.
    $r->get('/admin/dmarc/status')     ->to('account#admin_dmarc_status');
    $r->get('/admin/dmarc/summary')    ->to('account#admin_dmarc_summary');
    $r->get('/admin/dmarc/sources')    ->to('account#admin_dmarc_sources');
    $r->get('/admin/dmarc/reports')    ->to('account#admin_dmarc_reports');
    $r->get('/admin/fleet/hosts')      ->to('account#admin_fleet_hosts');
    $r->get('/admin/fleet/mismatches') ->to('account#admin_fleet_mismatches');
    $r->get('/admin/topology')         ->to('account#admin_topology');
    $r->get('/admin/ha/status')        ->to('account#admin_ha_status');
    $r->post('/admin/spf')             ->to('account#admin_spf');
    $r->post('/admin/dmarc')           ->to('account#admin_dmarc');
    $r->post('/admin/domains/add')     ->to('account#admin_domain_add');
    $r->post('/admin/domains/toggle')  ->to('account#admin_domain_toggle');
    # Send-as grants (mail aliases) + site-wide recipient access (JSON).
    $r->get('/admin/mail-aliases')          ->to('account#admin_aliases_list');
    $r->post('/admin/mail-aliases/add')     ->to('account#admin_alias_add');
    $r->post('/admin/mail-aliases/set-send')->to('account#admin_alias_set_send');
    $r->post('/admin/mail-aliases/remove')  ->to('account#admin_alias_remove');
    $r->get('/admin/recipient-access')       ->to('account#admin_racc_list');
    $r->post('/admin/recipient-access/set')  ->to('account#admin_racc_set');
    $r->post('/admin/recipient-access/remove')->to('account#admin_racc_remove');
    # Live user search for the admin typeahead (JSON; site_admin gated).
    $r->get('/admin/users/search')     ->to('account#admin_users_search');
    # Live usage-by-user for the quota forms (JSON; site_admin gated).
    $r->get('/admin/usage')            ->to('account#admin_user_usage');
    # Service accounts, per-user invite quota, a user's sessions (site_admin).
    $r->post('/admin/users/create-service-account')->to('account#admin_create_service_account');
    $r->post('/admin/welcome-email/resend')->to('account#admin_resend_welcome');
    $r->get('/admin/invite-quota')     ->to('account#admin_invite_quota_get');
    $r->post('/admin/invite-quota')    ->to('account#admin_invite_quota_set');
    $r->get('/admin/user-sessions')    ->to('account#admin_user_sessions');
    $r->post('/admin/user-sessions/revoke')->to('account#admin_user_session_revoke');
    # Dovecot pool status (JSON; site_admin gated).
    $r->get('/admin/dovecot/status')         ->to('account#admin_dovecot_status');
    # Roles & permissions (RBAC; JSON; site_admin gated).
    $r->get('/admin/roles')             ->to('account#admin_roles_list');
    $r->post('/admin/roles/add')        ->to('account#admin_role_add');
    $r->post('/admin/roles/remove')     ->to('account#admin_role_remove');
    $r->post('/admin/roles/grant-perm') ->to('account#admin_role_grant_perm');
    $r->post('/admin/roles/revoke-perm')->to('account#admin_role_revoke_perm');
    $r->post('/admin/users/grant-role') ->to('account#admin_user_grant_role');
    $r->post('/admin/users/revoke-role')->to('account#admin_user_revoke_role');
    # Domain catch-all routing (JSON; site_admin gated).
    $r->get('/admin/domains/catch-alls')     ->to('account#admin_catchalls');
    $r->post('/admin/domains/catch-all/set')  ->to('account#admin_set_catchall');
    $r->post('/admin/domains/catch-all/clear')->to('account#admin_clear_catchall');
    $r->post('/admin/domains/catch-all/bulk') ->to('account#admin_bulk_catchall');

    return;
}

package Homelab::Accountmanage::App::Controller::Account;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::URL;
use Mojo::UserAgent;
use Homelab::Common::AuthClient qw(introspect revoke_all);
use Homelab::Common::SSOClient qw(exchange_code);
use Homelab::Common::AppleProfile qw(build_mail_profile profile_filename);
use Homelab::Common::MailSetup qw(mail_settings manual_setup_rows);
use Homelab::Common::QRCode qw(qr_svg);
use Homelab::Common::ProfileSigner qw(sign_apple_profile);
use Homelab::Common::Mailer qw(send_mail);
use Homelab::Common::WelcomeMail qw(ready_email welcome_email);
use Homelab::Common::SetupToken qw(issue_setup_token verify_setup_token);

# Server-to-server client for calling homelab-api with the logged-in
# user's bearer token. Short timeout: these are quick JSON calls behind
# the dashboard render; a slow/down backend should degrade to "unavailable"
# in one panel, not hang the whole page.
my $UA = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 15);

sub _random_state { return join '', map { sprintf '%02x', int rand 256 } 1 .. 16 }

# Bearer header first (unused today, but keeps parity with every other
# homelab app's dual browser/API auth), then the session cookie's token.
sub _current_auth ($c) {
    my ($jwt) = ($c->req->headers->authorization // '') =~ /^Bearer\s+(.+)$/;
    $jwt //= $c->session('token');
    return (undef, undef, undef) unless $jwt;
    my $result = introspect($jwt, api_base => $c->app->api_base);
    return $result ? ($result->{email}, $jwt, ($result->{roles} // [])) : (undef, undef, undef);
}

# Admin gate for the Administration pane's actions: ($email, $jwt) if the
# caller holds site_admin, else (undef, undef). Backends re-check too;
# this is defense-in-depth + lets the UI fail fast.
sub _admin_auth ($c) {
    my ($email, $jwt, $roles) = _current_auth($c);
    return (undef, undef) unless $email && grep { $_ eq 'site_admin' } @$roles;
    return ($email, $jwt);
}

# Catch-all routing gate: ($email, $jwt) if the caller is site_admin OR
# holds the domains.catchall capability -- so a group can be granted the
# "Domain catch-all routing" area (incl. domain send-as) without full
# site_admin. site_admin short-circuits (it implicitly holds every
# capability), else one introspect ?capability round-trip decides.
sub _catchall_auth ($c) {
    my ($email, $jwt, $roles) = _current_auth($c);
    return (undef, undef) unless $email && $jwt;
    return ($email, $jwt) if grep { $_ eq 'site_admin' } @$roles;
    my $r = introspect($jwt, api_base => $c->app->api_base, capability => 'domains.catchall');
    return (undef, undef) unless $r && $r->{has_capability};
    return ($email, $jwt);
}

# Metrics gate: ($email, $jwt) if the caller holds the metrics.view
# capability (site_admin always does; any other role if granted via the
# RBAC UI), else (undef, undef). Uses introspect's ?capability -- the same
# mechanism homelab-domain-admin's site_admin gating uses. Prometheus
# itself is not capability-aware, so THIS is the access control.
sub _metrics_auth ($c) {
    my ($email, $jwt, $roles) = _current_auth($c);
    return (undef, undef) unless $email && $jwt;
    # site_admin always has every capability (api _has_capability_p
    # short-circuits on it) -- skip the extra round-trip for the common case.
    return ($email, $jwt) if grep { $_ eq 'site_admin' } @$roles;
    my $r = introspect($jwt, api_base => $c->app->api_base, capability => 'metrics.view');
    return (undef, undef) unless $r && $r->{has_capability};
    return ($email, $jwt);
}

# --- Device setup ("Mail setup" panel + the page a phone lands on) ------
#
# Adding a mailbox to a phone is inherently cross-device: the panel is
# open on a laptop and the account has to end up on a handset that has
# never signed in here and never will. So the QR code on that panel
# carries a signed, short-lived token (Homelab::Common::SetupToken) and
# the page it opens accepts that token in place of a session.
#
# What the token is worth: it names a mailbox. The page and the profile
# behind it hold an email address and two public hostnames and no
# password at all (see Homelab::Common::AppleProfile) -- so it is not a
# login, cannot read mail, and lapses in minutes.

sub _device_cfg ($c) { return $c->app->device_config // {} }

# The HMAC key behind the QR links.
#
# Defaults to THE SESSION SECRET, which is not laziness -- it is the only
# key this app already guarantees is identical on every node. myaccount
# runs as a three-node pool behind one webproxy vhost, round-robined per
# request; a key generated per host would verify on about one request in
# three. session.secret must already be the same across the pool or a
# signed cookie issued by one node would be rejected by the next, so
# reusing it is pool-safe by construction rather than by convention.
#
# Safe to reuse because the token is domain-separated: every signature
# commits to a `purpose` string (Homelab::Common::SetupToken), and the
# cookie signing it shares a key with is a different algorithm over a
# different message entirely.
#
# device_setup.token_secret overrides it, for an operator who would
# rather these did not share -- set the SAME value on every pool node.
sub _device_secret ($c) {
    my $s = _device_cfg($c)->{token_secret};
    return $s if defined $s && length $s && $s !~ /^YOUR_/;

    my $sess = eval { $c->app->secrets->[0] };
    return undef unless defined $sess && length $sess;
    # The shipped example's placeholder. An install still carrying it has
    # bigger problems, but signing with a publicly known string is not
    # one we should add to them.
    return undef if $sess =~ /^CHANGE_ME/;
    return $sess;
}

# A signed URL for the phone, or undef when this install has no secret
# (in which case the panel just omits the QR code).
#
# Two lifetimes, deliberately, because there are two situations and they
# are nothing alike. A QR code is generated while someone is looking at
# the screen and is meant to be used within the minute, so minutes is
# right and anything longer is a forwarded screenshot that still works.
# A link in a resent welcome email has to survive the recipient getting
# round to reading their mail, so it is measured in days. Same signature,
# same purpose string, same disclosure (an address and two public
# hostnames, never a password) -- only the bound differs.
sub _device_setup_url ($c, $email, %opt) {
    my $secret = _device_secret($c) or return undef;
    my $ttl    = $opt{ttl_seconds} || (_device_cfg($c)->{qr_ttl_minutes} || 15) * 60;
    my $token  = eval {
        issue_setup_token(secret => $secret, purpose => 'mail-device-setup',
            subject => $email, ttl => $ttl);
    };
    unless ($token) {
        $c->app->log->warn("accountmanage: could not issue a device setup token: $@");
        return undef;
    }
    my $base = $c->app->public_base_url // '';
    $base =~ s{/+$}{};
    return "$base/devices/setup?t=$token";
}

# Who is this request for? A signed-in session, or failing that a valid
# token. In that ORDER: the session is the stronger claim, and checking
# it first means a signed-in user never depends on a token at all.
sub _device_subject ($c) {
    my ($email) = _current_auth($c);
    return $email if $email;
    my $secret = _device_secret($c) or return undef;
    return verify_setup_token(secret => $secret, purpose => 'mail-device-setup',
        token => scalar $c->param('t'));
}

sub _device_settings ($c, $email) {
    return mail_settings(email => $email, config => _device_cfg($c));
}

# GET /devices/apple.mobileconfig -- session or token.
sub device_apple_profile ($c) {
    my $email = _device_subject($c);
    unless ($email) {
        $c->res->headers->content_type('text/plain; charset=UTF-8');
        return $c->render(data => "Sign in to download your mail setup profile.\n", status => 401);
    }
    my $s = _device_settings($c, $email);
    # One parameter set for both paths, so the signed profile and the
    # unsigned fallback cannot describe different mail settings.
    my %params = (
        email        => $email,
        imap_host    => $s->{imap_host}, imap_port => $s->{imap_port},
        smtp_host    => $s->{smtp_host}, smtp_port => $s->{smtp_port},
        account_label => $s->{service_label}, organization => $s->{organization},
        display_name => $email,
    );
    # Signed when the issuer can be reached, unsigned when it cannot.
    # The difference is one word on the install screen, never whether
    # the download works -- see Homelab::Common::ProfileSigner.
    my $body = sign_apple_profile(
        signing => $c->app->profile_signing,
        profile => \%params,
        log     => $c->app->log,
    ) // build_mail_profile(%params);
    # application/x-apple-aspen-config is what makes iOS hand the file to
    # the profile installer rather than render it as text. It is equally
    # correct for the signed form, which is binary PKCS#7 rather than
    # XML: the type says what the file is for, not how it is encoded.
    $c->res->headers->content_type('application/x-apple-aspen-config');
    $c->res->headers->content_disposition(
        'attachment; filename="' . profile_filename($email, $s->{service_label}) . '"');
    $c->res->headers->cache_control('no-store, private');
    return $c->render(data => $body);
}

# GET /devices/setup?t=... -- the standalone page a scanned QR lands on.
# Renders without the dashboard chrome: whoever opens it is not signed in
# and a top bar offering account actions would be a dead end.
sub device_setup_page ($c) {
    my $email = _device_subject($c);
    unless ($email) {
        return $c->render(template => 'devicesetup', status => 410,
            expired => 1, email => undef, settings => undef, manual_rows => [],
            profile_url => '', qr_url => undef, self_url => undef,
            hints => {}, format => 'html');
    }
    my $s = _device_settings($c, $email);
    my $t  = $c->param('t');
    my $qs = $t ? '?t=' . $t : '';
    my $hints = _device_hints($c);

    # The cross-device hand-off, offered only when this page was reached
    # by a token: that is the case where it might be open on a laptop
    # (someone following the link in a resent welcome email) with the
    # phone still to be set up. A signed-in visitor already has the
    # dashboard's own Mail setup panel, which does this better.
    my ($qr_url, $self_url);
    if ($t && !$hints->{is_ios}) {
        my $base = $c->app->public_base_url // '';
        $base =~ s{/+$}{};
        $qr_url   = "/devices/qr.svg$qs";
        $self_url = "$base/devices/setup$qs";
    }

    return $c->render(
        template    => 'devicesetup',
        expired     => 0,
        email       => $email,
        settings    => $s,
        manual_rows => manual_setup_rows($s),
        profile_url => "/devices/apple.mobileconfig$qs",
        qr_url      => $qr_url,
        self_url    => $self_url,
        hints       => $hints,
    );
}

# GET /devices/qr.svg -- a session MINTS a code, a token only ECHOES one.
#
# The distinction is the whole security property here, and it is worth
# stating plainly because the two cases look identical from outside:
#
#   * with a session, this issues a FRESH short-lived token and draws
#     that. A signed-in user can always get a new code; that is the
#     point of the panel.
#
#   * with only ?t=, it draws a code for THE SAME TOKEN that was
#     presented -- re-encoding a capability the caller already holds,
#     never granting a new one. So a lapsed link cannot buy itself a
#     fresh lease, which it could if this minted unconditionally.
#
# The echo case exists because of the resent welcome email: that link is
# opened on a laptop as often as on a phone, and a setup page with no way
# to cross to the handset is a dead end.
sub device_qr ($c) {
    my ($email) = _current_auth($c);
    my $url;

    if ($email) {
        $url = _device_setup_url($c, $email);
    }
    elsif (my $t = $c->param('t')) {
        my $secret = _device_secret($c);
        $email = $secret && verify_setup_token(secret => $secret,
            purpose => 'mail-device-setup', token => $t);
        return $c->render(data => '', status => 401) unless $email;
        my $base = $c->app->public_base_url // '';
        $base =~ s{/+$}{};
        $url = "$base/devices/setup?t=$t";
    }
    else {
        return $c->render(data => '', status => 401);
    }

    # No URL means no signing secret on this install. 404 lets the
    # panel's <img> fail quietly beside the settings that always work.
    return $c->render(data => '', status => 404) unless $url;
    my $svg = qr_svg($url, module => 6, title => "Mail setup for $email");
    return $c->render(data => '', status => 404) unless $svg;
    $c->res->headers->content_type('image/svg+xml');
    $c->res->headers->cache_control('no-store, private');
    return $c->render(data => $svg);
}

# GET /devices/setup-link -- session only. A fresh short-lived setup URL
# as JSON, for the panel's "Copy link" button.
#
# A separate endpoint rather than a value in the dashboard's HTML, for
# two reasons. It mints a capability, so minting one on every dashboard
# render -- for every user, whether or not they ever look at the Mail
# setup section -- is waste. And a token embedded in the page would then
# live in the browser's history and back-forward cache of the dashboard
# itself, which is a much longer life than the link's own few minutes.
sub device_setup_link ($c) {
    my ($email) = _current_auth($c);
    return $c->render(json => { error => 'authentication required' }, status => 401)
        unless $email;
    my $url = _device_setup_url($c, $email);
    return $c->render(json => { error => 'no signing secret on this install' }, status => 404)
        unless $url;
    $c->res->headers->cache_control('no-store, private');
    return $c->render(json => { url => $url });
}

# Decides only what to show FIRST. Every option stays on the page, so a
# wrong guess costs a scroll. See homelab-invite's Controller::Setup for
# why the Safari case is called out: iOS installs a configuration profile
# only when it was downloaded in Safari itself, and in any other iOS
# browser the file downloads and then cannot be opened.
sub _device_hints ($c) {
    my $ua = $c->req->headers->user_agent // '';
    my $ios = $ua =~ /\b(?:iPhone|iPad|iPod)\b/ ? 1 : 0;
    my $mac = (!$ios && $ua =~ /\bMacintosh\b/) ? 1 : 0;
    my $other_ios_browser = $ua =~ /\b(?:CriOS|FxiOS|EdgiOS|OPiOS|Chrome)\b/ ? 1 : 0;
    return {
        is_ios       => $ios,
        is_mac       => $mac,
        is_apple     => ($ios || $mac) ? 1 : 0,
        needs_safari => ($ios && $other_ios_browser) ? 1 : 0,
    };
}

# --- Prometheus query helpers (used by the Metrics tab's BFF) -----------
# One instant query -> arrayref of result series (or undef on failure).
sub _prom_query ($prom, $query) {
    my $url = Mojo::URL->new("$prom/api/v1/query")->query(query => $query);
    my $tx  = $UA->get($url);
    return undef if $tx->error;
    my $j = eval { $tx->result->json };
    return ($j && ($j->{status} // '') eq 'success') ? $j->{data}{result} : undef;
}
# Scalar value of an aggregate instant query (undef if no data).
sub _prom_scalar ($prom, $query) {
    my $res = _prom_query($prom, $query);
    return undef unless $res && @$res;
    return $res->[0]{value}[1] + 0;
}
# Per-host CPU/mem/disk %, assembled by the `host` label.
sub _prom_hosts ($prom) {
    my %h;
    my %metric = (
        cpu  => '100-(avg by(host)(rate(node_cpu_seconds_total{job="node",mode="idle"}[5m]))*100)',
        mem  => '100*(1-node_memory_MemAvailable_bytes{job="node"}/node_memory_MemTotal_bytes{job="node"})',
        disk => '100*(1-node_filesystem_avail_bytes{job="node",mountpoint="/"}/node_filesystem_size_bytes{job="node",mountpoint="/"})',
    );
    for my $m (sort keys %metric) {
        my $res = _prom_query($prom, $metric{$m}) // [];
        for my $r (@$res) {
            my $host = $r->{metric}{host} // next;
            $h{$host}{$m} = sprintf '%.0f', ($r->{value}[1] // 0);
        }
    }
    return [ map { { host => $_, %{ $h{$_} } } } sort keys %h ];
}
# Services whose last heartbeat check failed (homelab_service_up == 0).
sub _prom_down_services ($prom) {
    my $res = _prom_query($prom, 'homelab_service_up==0') // [];
    return [ map { { host => ($_->{metric}{hostname} // '?'), service => ($_->{metric}{service_name} // '?') } } @$res ];
}

# GET /admin/metrics/summary -- curated fleet-health summary from
# Prometheus, metrics.view gated. A FIXED set of instant queries (no
# arbitrary PromQL reaches the browser); returns a flat JSON the Metrics
# tab renders as stat cards + a per-host table + a services-down list.
sub admin_metrics_summary ($c) {
    my ($email, $jwt) = _metrics_auth($c);
    return $c->render(json => { error => 'metrics.view required' }, status => 403) unless $email;
    my $prom = $c->app->prometheus_base;
    return $c->render(json => { error => 'metrics not configured' }, status => 503) unless $prom;

    my %q = (
        hosts_up       => 'count(up{job="node"}==1)',
        hosts_total    => 'count(up{job="node"})',
        services_total => 'count(homelab_service_up)',
        services_down  => 'count(homelab_service_up==0) or vector(0)',
        probes_up      => 'sum(probe_success) or vector(0)',
        probes_total   => 'count(probe_success) or vector(0)',
        cert_days_min  => '(min(probe_ssl_earliest_cert_expiry-time())/86400) or vector(0)',
        cpu_max        => 'max(100-(avg by(host)(rate(node_cpu_seconds_total{job="node",mode="idle"}[5m]))*100))',
        mem_max        => 'max(100*(1-node_memory_MemAvailable_bytes{job="node"}/node_memory_MemTotal_bytes{job="node"}))',
        disk_max       => 'max(100*(1-node_filesystem_avail_bytes{job="node",mountpoint="/"}/node_filesystem_size_bytes{job="node",mountpoint="/"}))',
    );
    my %out;
    $out{$_} = _prom_scalar($prom, $q{$_}) for keys %q;
    $out{hosts}              = _prom_hosts($prom);
    $out{services_down_list} = _prom_down_services($prom);

    # Signal an unreachable Prometheus distinctly from a healthy-but-empty
    # fleet so the UI can say "metrics unavailable" rather than "0 hosts".
    $out{ok} = defined $out{hosts_total} ? \1 : \0;
    return $c->render(json => \%out);
}

# Session-cached metrics.view gate for the Grafana reverse proxy. Grafana
# loads dozens of assets per page; an introspect per asset would hammer the
# api, so after the first full capability check (or the priming at dashboard
# load) the verdict + the user's email live in the session. Returns the
# email to assert as Grafana's auth-proxy user, or undef if not allowed.
sub _grafana_gate ($c) {
    return $c->session('metrics_user')
        if $c->session('metrics_ok') && $c->session('metrics_user');
    my ($email, $jwt) = _metrics_auth($c);
    return undef unless $email;
    $c->session(metrics_ok => 1, metrics_user => $email);
    return $email;
}

# ANY /grafana[/...] -- reverse-proxy the fleet Grafana (served from the
# /grafana sub-path, auth_proxy) so its FULL dashboards render inside
# myaccount, off-network, gated by metrics.view. This host is the only one
# Grafana trusts to assert the user (GF_AUTH_PROXY_WHITELIST + the fleet
# firewall), so the injected X-WEBAUTH-USER is the actual access decision.
sub grafana_proxy ($c) {
    my $user = _grafana_gate($c);
    return $c->render(text => "You don't have access to the metrics dashboards.", status => 403)
        unless $user;
    my $gbase = $c->app->grafana_base;
    return $c->render(text => 'Grafana embedding is not configured.', status => 503)
        unless $gbase;

    # Keep the /grafana prefix -- Grafana serve_from_sub_path serves there.
    my $up = Mojo::URL->new($gbase);
    $up->path($c->req->url->path->to_string);
    $up->query($c->req->url->query);

    my $headers = $c->req->headers->clone;
    $headers->remove('Host');            # the UA sets it from the upstream URL
    $headers->remove('Content-Length');  # let the UA recompute
    $headers->header('X-WEBAUTH-USER' => $user);

    my $tx = $UA->build_tx($c->req->method, $up, $headers->to_hash, $c->req->body);
    $c->proxy->start_p($tx)->catch(sub ($err) {
        $c->render(text => "Dashboard proxy error: $err", status => 502) unless $c->res->code;
    });
}

# GET a homelab-api path with the user's token; returns decoded JSON, or
# undef on any non-2xx / transport error (callers render "unavailable").
sub _api_get ($c, $jwt, $path) {
    my $tx = $UA->get($c->app->api_base . $path => { Authorization => "Bearer $jwt" });
    return undef unless $tx->res->code && $tx->res->code >= 200 && $tx->res->code < 300;
    return $tx->res->json;
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
        return $c->render(template => 'login', error => 'Sign-in expired or was invalid. Please try again.', status => 400);
    }
    my $result = exchange_code($code,
        sso_base      => $c->app->sso_internal_base,
        client_id     => $c->app->sso_client_id,
        client_secret => $c->app->sso_client_secret,
        redirect_uri  => $c->app->sso_redirect_uri,
    );
    unless ($result->{success}) {
        return $c->render(template => 'login', error => 'Could not complete sign-in. Please try again.', status => 502);
    }
    $c->session(token => $result->{access_token}, refresh_token => $result->{refresh_token});
    return $c->redirect_to('/');
}

sub logout ($c) {
    # Revoke every session this user holds BEFORE clearing our cookie and
    # handing off to the IdP. homelab-sso's /logout fans out too, so this
    # is belt-and-braces -- but it is the half that still works when the
    # IdP session cookie is already gone (expired, or cleared by browser
    # privacy settings), in which case SSO has no token to fan out with
    # and would silently revoke nothing.
    #
    # Deliberately NOT via _current_auth: that would introspect first,
    # costing a second round trip to learn something revoke_all's own
    # 401 already tells us. A dead token here simply means there was
    # nothing left to revoke.
    #
    # Best-effort: logout must clear the local session and redirect
    # whether or not homelab-api answered.
    if (my $jwt = $c->session('token')) {
        my $res = eval { revoke_all($jwt, api_base => $c->app->api_base) };
        $c->app->log->info(sprintf('logout: revoked %d session(s)', $res->{revoked})) if $res;
    }
    $c->session(expires => 1);
    my $post_logout_uri = Mojo::URL->new($c->app->sso_redirect_uri)->path('/login');
    my $url = Mojo::URL->new($c->app->sso_base . '/logout')->query(redirect_uri => $post_logout_uri);
    return $c->redirect_to($url);
}

sub dashboard ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;

    # Account summary is the source of truth for identity/roles here; a
    # 401 means the cookie's token has expired/been revoked -> re-login.
    my $summary = _api_get($c, $jwt, '/api/v1/account/summary');
    return $c->redirect_to('/login') unless $summary;

    my $sessions = _api_get($c, $jwt, '/api/v1/auth/sessions') // [];
    # Drive + mail usage via the api gateway (/api/v1/drive/* -> homelab-drive,
    # /api/v1/mail/* -> homelab-mailbridge); undef if that backend is
    # unavailable -> the panel shows "unavailable". Both return the same
    # {used_bytes, limit_bytes} shape so the template renders them identically.
    my $drive_usage = _api_get($c, $jwt, '/api/v1/drive/usage');
    my $mail_usage  = _api_get($c, $jwt, '/api/v1/mail/usage');

    my $roles    = $summary->{roles} // [];
    my $is_admin = grep { $_ eq 'site_admin' } @$roles;

    # Admin pane data (only for site_admins): the managed domains (for the
    # block-link toggle + DKIM/SPF/DMARC selects). The USER list is NOT
    # pre-loaded any more -- with potentially thousands of accounts the
    # Users card and the quota forms use the live /admin/users/search
    # typeahead instead. Best-effort -- degrades to empty if unavailable.
    my $admin_domains = [];
    if ($is_admin) {
        $admin_domains = _api_get($c, $jwt, '/api/v1/domains') // [];
    }

    # Metrics tab visibility: only when a Prometheus is configured AND the
    # caller holds metrics.view (site_admin always does -- skip the extra
    # round-trip for them; other roles are checked via introspect).
    my $has_metrics = 0;
    if ($c->app->prometheus_base || $c->app->grafana_base) {
        if ($is_admin) { $has_metrics = 1; }
        else {
            my $mr = introspect($jwt, api_base => $c->app->api_base, capability => 'metrics.view');
            $has_metrics = ($mr && $mr->{has_capability}) ? 1 : 0;
        }
    }
    # Prime the Grafana-proxy gate so it needn't introspect per embedded
    # asset (and clear it when access is absent).
    if ($has_metrics) { $c->session(metrics_ok => 1, metrics_user => $email); }
    else              { delete $c->session->{metrics_ok}; delete $c->session->{metrics_user}; }

    # Catch-all routing area: site_admin OR the domains.catchall capability
    # (so a granted group sees the "Domain catch-all routing" area even
    # without full site_admin). site_admin shortcut avoids the round-trip.
    my $has_catchall = $is_admin ? 1 : 0;
    unless ($is_admin) {
        my $cr = introspect($jwt, api_base => $c->app->api_base, capability => 'domains.catchall');
        $has_catchall = ($cr && $cr->{has_capability}) ? 1 : 0;
    }

    my $device_settings = _device_settings($c, $email);

    return $c->render(
        template     => 'dashboard',
        email        => $email,
        summary      => $summary,
        sessions     => $sessions,
        drive_usage  => $drive_usage,
        mail_usage   => $mail_usage,
        roles        => $roles,
        is_admin     => ($is_admin ? 1 : 0),
        has_metrics  => $has_metrics,
        has_catchall => $has_catchall,
        admin_domains => $admin_domains,
        sso_forgot_url => $c->app->sso_base . '/forgot',
        # Mail setup panel. Derived from the signed-in address, so it is
        # correct for every user with no per-user storage anywhere.
        device_settings => $device_settings,
        device_rows     => manual_setup_rows($device_settings),
        device_qr_ok    => (_device_secret($c) ? 1 : 0),
        device_hints    => _device_hints($c),
    );
}

sub revoke_session ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $jti = $c->stash('jti');
    if (defined $jti && $jti =~ /\S/) {
        $UA->delete($c->app->api_base . "/api/v1/auth/sessions/$jti" => { Authorization => "Bearer $jwt" });
    }
    return $c->redirect_to('/');
}

sub revoke_others ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    $UA->delete($c->app->api_base . '/api/v1/auth/sessions?except_current=true' => { Authorization => "Bearer $jwt" });
    return $c->redirect_to('/');
}

# In-place password change: proxy to homelab-api's authenticated
# POST /api/v1/auth/password with the user's token. Feedback via flash.
sub change_password ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $cur     = $c->param('current_password') // '';
    my $new     = $c->param('new_password') // '';
    my $confirm = $c->param('confirm_password') // '';
    if ($cur eq '' || $new eq '') { $c->flash(pw_error => 'Both current and new password are required.'); return $c->redirect_to('/#security'); }
    if ($new ne $confirm)         { $c->flash(pw_error => 'The new passwords do not match.'); return $c->redirect_to('/#security'); }
    if (length($new) < 8)         { $c->flash(pw_error => 'New password must be at least 8 characters.'); return $c->redirect_to('/#security'); }

    my $tx = $UA->post($c->app->api_base . '/api/v1/auth/password'
        => { Authorization => "Bearer $jwt" }
        => json => { current_password => $cur, new_password => $new });
    if (($tx->res->code // 0) == 200) {
        $c->flash(pw_ok => 'Password changed. Your other sessions have been signed out.');
    } else {
        $c->flash(pw_error => (eval { $tx->res->json->{error} } // 'Could not change password.'));
    }
    return $c->redirect_to('/#security');
}

# Set / change / clear the recovery email: proxy to homelab-api's
# POST /api/v1/account/recovery-email.
sub set_recovery_email ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $re = $c->param('recovery_email') // '';
    my $tx = $UA->post($c->app->api_base . '/api/v1/account/recovery-email'
        => { Authorization => "Bearer $jwt" }
        => json => { recovery_email => $re });
    if (($tx->res->code // 0) == 200) {
        $c->flash(re_ok => ($re eq '' ? 'Recovery email cleared.' : 'Recovery email saved.'));
    } else {
        $c->flash(re_error => (eval { $tx->res->json->{error} } // 'Could not save recovery email.'));
    }
    return $c->redirect_to('/#security');
}

# --- Administration (site_admin) -----------------------------------------

# Flash the outcome of an admin proxy call, then the caller redirects to
# the Administration pane.
sub _admin_flash ($c, $tx, $ok_msg) {
    if (($tx->res->code // 0) >= 200 && ($tx->res->code // 0) < 300) {
        $c->flash(admin_ok => $ok_msg);
    } else {
        $c->flash(admin_err => (eval { $tx->res->json->{error} } // ('Action failed (HTTP ' . ($tx->res->code // 0) . ').')));
    }
}

# Suspend / re-enable a user's login (api.users.active gates every login
# path). Form posts action=suspend|enable.
sub admin_set_active ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $id     = $c->stash('id');
    my $enable = (($c->param('action') // '') eq 'enable') ? \1 : \0;
    my $tx = $UA->post($c->app->api_base . "/api/v1/admin/users/$id/active"
        => { Authorization => "Bearer $jwt" } => json => { active => $enable });
    _admin_flash($c, $tx, ($$enable ? 'User re-enabled.' : 'User suspended (and signed out).'));
    return $c->redirect_to('/#admin:users');
}

# Set a user's drive quota (GB). Empty limit clears the override (back to
# the 1 TB default).
sub admin_drive_quota ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $user = $c->param('user_email') // '';
    my $gb   = $c->param('limit_gb') // '';
    my %body = (user_email => $user);
    $body{limit_bytes} = int($gb) * 1024 * 1024 * 1024 if $gb ne '' && $gb =~ /^\d+$/;
    my $tx = $UA->put($c->app->api_base . '/api/v1/drive/admin/quota'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    _admin_flash($c, $tx, ($gb eq '' ? "Drive quota for $user reset to default." : "Drive quota for $user set to ${gb} GB."));
    return $c->redirect_to('/#admin:quotas');
}

# Set a user's mail (dovecot) quota (GB). Empty limit clears the override
# (back to the 1 TB default). Unlike drive-quota, the mail-quota API is keyed
# by user id (POST /api/v1/admin/users/:id/mail-quota), so resolve the email
# to an id from the admin user list first.
sub admin_mail_quota ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $user = $c->param('user_email') // '';
    my $gb   = $c->param('limit_gb') // '';
    my $users = _api_get($c, $jwt, '/api/v1/admin/users') // [];
    my ($u) = grep { ($_->{email} // '') eq $user } @$users;
    unless ($u) {
        $c->flash(admin_err => "No such user: $user");
        return $c->redirect_to('/#admin:quotas');
    }
    my %body;
    $body{limit_bytes} = int($gb) * 1024 * 1024 * 1024 if $gb ne '' && $gb =~ /^\d+$/;
    my $tx = $UA->post($c->app->api_base . "/api/v1/admin/users/$u->{id}/mail-quota"
        => { Authorization => "Bearer $jwt" } => json => \%body);
    _admin_flash($c, $tx, ($gb eq '' ? "Mail quota for $user reset to default." : "Mail quota for $user set to ${gb} GB."));
    return $c->redirect_to('/#admin:quotas');
}

# Live user search for the admin typeahead. Proxies to the api gateway's
# GET /api/v1/admin/users?q=... (site_admin gated there too; this handler
# re-checks site_admin locally as defense-in-depth). Returns the JSON
# array straight through for the front-end. >=3-char minimum is enforced
# on both sides.
sub admin_users_search ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $q = $c->param('q') // '';
    return $c->render(json => []) if length($q) < 3;
    # Mojo::URL->query url-encodes q so a '+'/space/'%' in the typed value
    # can't corrupt the forwarded request.
    my $path = Mojo::URL->new('/api/v1/admin/users')->query(q => $q, limit => 20)->to_string;
    return $c->render(json => (_api_get($c, $jwt, $path) // []));
}

# POST /admin/welcome-email/resend  { user_email, also_to? }  (site_admin)
#
# Re-sends the messages a new account triggers. The reason this exists is
# mundane and constant: the originals are sent once, at signup, to
# addresses that bounce, to spam folders, and to people who delete them --
# and the device-setup link inside them is how someone adds their NEXT
# phone, months later. Without this, the only remedy was to read the
# settings down the phone.
#
# WHAT GOES WHERE. Two messages, and they are not interchangeable:
#
#   * the WELCOME mail goes into the mailbox itself, always. Nothing
#     needs to be known or typed for that -- the address is the account.
#
#   * the "your account is ready" mail goes to a CONTACT address, which
#     is optional and TYPED BY THE ADMIN rather than looked up. That is
#     deliberate: homelab-api exposes a user's recovery address only to
#     that user, and the situation this action is for is almost always
#     "they say nothing arrived, here is the address they are giving me
#     now" -- which is a better input than whatever is on file anyway.
#
# The setup link is minted for DAYS, not the QR code's minutes: it has to
# survive the recipient getting round to reading their mail.
sub admin_resend_welcome ($c) {
    my ($admin, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'site_admin role required' }, status => 403)
        unless $admin;

    my $target = lc($c->param('user_email') // '');
    $target =~ s/^\s+|\s+$//g;
    return $c->render(json => { error => 'A user email is required.' }, status => 400)
        unless $target =~ /^[^\@\s]+\@[^\@\s]+\.[^\@\s]+$/;

    my $also = $c->param('also_to') // '';
    $also =~ s/^\s+|\s+$//g;
    return $c->render(json => { error => "'$also' does not look like an email address." },
        status => 400)
        if length($also) && $also !~ /^[^\@\s]+\@[^\@\s]+\.[^\@\s]+$/;

    my $mcfg = $c->app->mailer_config // {};
    unless (($mcfg->{smtp_host} // '') && ($mcfg->{email} // '')) {
        return $c->render(json => { error => 'This install has no mailer configured, so '
            . 'myaccount cannot send mail. Add a mailer: block to '
            . '/etc/homelab/accountmanage/config.yml on every node.' }, status => 501);
    }

    # The account has to exist. Checked through homelab-api with the
    # admin's OWN token, so the authorization for the lookup is the same
    # authorization as for the action -- and so a typo does not quietly
    # send a welcome message into a catch-all.
    my $path = Mojo::URL->new('/api/v1/admin/users')->query(q => $target, limit => 20)->to_string;
    my $found = _api_get($c, $jwt, $path) // [];
    my ($user) = grep { lc($_->{email} // '') eq $target } @$found;
    return $c->render(json => { error => "No account found for $target." }, status => 404)
        unless $user;

    my $s    = _device_settings($c, $target);
    my $dc   = _device_cfg($c);
    my $days = $dc->{link_ttl_days} || 30;
    my $setup_url = _device_setup_url($c, $target, ttl_seconds => $days * 86_400);

    my $login_url = $c->app->public_base_url // '';
    $login_url .= '/' unless $login_url =~ m{/$};
    my %urls = (
        login_url   => $login_url,
        webmail_url => ($s->{webmail_url} || ''),
        drive_url   => ($dc->{drive_url}  || ''),
    );

    # Independently evalled, like the originals in homelab-invite: one
    # failing must not hide whether the other worked, and the admin needs
    # to know which.
    my @results;
    my $send = sub ($to, $what, $subject, $text, $html) {
        my $ok = eval {
            send_mail(
                smtp_host  => $mcfg->{smtp_host}, smtp_port => $mcfg->{smtp_port},
                from_email => $mcfg->{email}, from_password => $mcfg->{smtp_password},
                to => $to, subject => $subject, body => $text, html => $html,
            );
            1;
        };
        my $err = $ok ? undef : ($@ // 'unknown failure');
        $err =~ s/\s+$// if defined $err;
        push @results, { to => $to, what => $what, ok => $ok ? \1 : \0,
                         ($err ? (error => $err) : ()) };
        $c->app->log->info($ok
            ? "accountmanage: $admin resent the $what message for $target to $to"
            : "accountmanage: $admin could not resend the $what message to $to: $err");
    };

    $send->($target, 'welcome', welcome_email(
        account_email => $target, settings => $s, setup_url => $setup_url, %urls));

    $send->($also, 'account-ready', ready_email(
        account_email => $target, settings => $s, setup_url => $setup_url, %urls))
        if length $also;

    my $sent = grep { ${ $_->{ok} } } @results;
    return $c->render(json => {
        ok        => ($sent == scalar @results) ? \1 : \0,
        setup_url => ($setup_url ? \1 : \0),
        results   => \@results,
    });
}

# GET /admin/usage?type=drive|mail&user_email=<addr> -- proxies to the
# owning service's admin usage-by-user endpoint so the quota forms can show
# "currently using X of Y" and warn before setting a limit below it. Returns
# {used_bytes, limit_bytes} (or an error the front-end renders as
# "unavailable"). site_admin gated here + re-checked by the backend.
sub admin_user_usage ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    my $type = $c->param('type') // 'drive';
    my $user = $c->param('user_email') // '';
    return $c->render(json => { error => 'bad email' }, status => 400) unless $user =~ /\@/;
    # NB: mail usage is on the API itself (/api/v1/admin/*), NOT under
    # /api/v1/mail/* -- the gateway forwards that whole prefix to mailbridge,
    # which has no DB. The clone-mirrored usage lives in the API's own DB.
    my %backend = (
        drive => '/api/v1/drive/admin/usage',
        mail  => '/api/v1/admin/mail-usage',
    );
    my $base = $backend{$type}
        or return $c->render(json => { error => 'bad type' }, status => 400);
    my $path = Mojo::URL->new($base)->query(user_email => $user)->to_string;
    my $r = _api_get($c, $jwt, $path);
    return $c->render(json => ($r // { error => 'unavailable' }), status => ($r ? 200 : 502));
}

# True iff $addr is a real, active api.users mailbox. Reuses the admin user
# search (ILIKE-prefix on a full address returns it) and checks for an exact
# case-insensitive match -- the black-hole guard for catch-all destinations
# (domain-admin's DB role can't see api.users, so this validation lives here).
sub _user_exists ($c, $jwt, $addr) {
    return 0 unless $addr && $addr =~ /\@/ && length($addr) >= 3;
    # Narrow exact-match check (site_admin OR domains.catchall) -- works for a
    # non-admin catch-all holder, unlike the site_admin-only /admin/users
    # search this used to call. Both callers are the catch-all handlers,
    # already gated to the same capability.
    my $path = Mojo::URL->new('/api/v1/mail/recipient-exists')->query(email => $addr)->to_string;
    my $res = _api_get($c, $jwt, $path);
    return ($res && $res->{exists}) ? 1 : 0;
}

# ===== Invites + account activity (self-service) =====

# GET /invites -- your invites + your effective invite quota.
sub invites_list ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => {
        invites => (_api_get($c, $jwt, '/api/v1/invites') // []),
        quota   => (_api_get($c, $jwt, '/api/v1/invites/quota') // {}),
    });
}

# POST /invites/send {recipient_email, message?}
sub invites_send ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient_email') // '');
    return $c->render(json => { error => 'a recipient email is required' }, status => 400) unless $recipient =~ /\@/;
    my %body = (recipient_email => $recipient, channel => 'web');
    my $msg = _trim($c->param('message') // '');
    $body{message} = $msg if length $msg;
    my $tx = $UA->post($c->app->api_base . '/api/v1/invites'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'send failed' }), status => ($tx->res->code // 502));
}

# POST /invites/revoke {invite_id}
sub invites_revoke ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $id = _trim($c->param('invite_id') // '');
    return $c->render(json => { error => 'invite_id required' }, status => 400) unless $id =~ /^\d+$/;
    my $tx = $UA->delete($c->app->api_base . "/api/v1/invites/$id"
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# GET /activity -- your own recent account activity (self-scoped audit trail).
sub activity_list ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/audit/log') // []));
}

# ===== Self-service Mail settings (any logged-in user, own account only) =====

# GET /mail/self -- aggregates the three self-service mail reads in one call:
# send-as grants, click-to-block setting, and self-blocked recipients. All use
# the caller's OWN token against the /mine endpoints (never site_admin).
sub mail_self ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    return $c->render(json => {
        send_as    => (_api_get($c, $jwt, '/api/v1/domains/mail-aliases/mine') // {}),
        block_link => (_api_get($c, $jwt, '/api/v1/block-link/account') // {}),
        blocked    => (_api_get($c, $jwt, '/api/v1/domains/recipient-access/mine') // []),
    });
}

# POST /mail/block-link {enabled} -- toggle the caller's own click-to-block link.
sub mail_set_block_link ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $enabled = $c->param('enabled') ? \1 : \0;
    my $tx = $UA->put($c->app->api_base . '/api/v1/block-link/account'
        => { Authorization => "Bearer $jwt" } => json => { enabled => $enabled });
    return $c->render(json => (eval { $tx->res->json } // {}), status => ($tx->res->code // 502));
}

# POST /mail/block {recipient} -- reject all future mail to one of the caller's
# own addresses (the api enforces that it must be theirs).
sub mail_block ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'a valid address is required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/recipient-access/mine'
        => { Authorization => "Bearer $jwt" } => json => { recipient => $recipient, action => 'REJECT' });
    return $c->render(json => (eval { $tx->res->json } // { error => 'block failed' }), status => ($tx->res->code // 502));
}

# POST /mail/unblock {recipient} -- undo a self-block.
sub mail_unblock ($c) {
    my ($email, $jwt) = _current_auth($c);
    return $c->render(json => {}, status => 401) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'a valid address is required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/recipient-access/mine/' . Mojo::Util::url_escape($recipient)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Service accounts / invite quota / a user's sessions, site_admin -----
sub admin_create_service_account ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $addr = _trim($c->param('email') // '');
    return $c->render(json => { error => 'a valid email is required' }, status => 400) unless $addr =~ /\@/;
    my %body = (email => $addr);
    my $pw = _trim($c->param('password') // '');
    $body{password} = $pw if length $pw;
    my $tx = $UA->post($c->app->api_base . '/api/v1/admin/users/service-account'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'create failed' }), status => ($tx->res->code // 502));
}
sub admin_invite_quota_get ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    return $c->render(json => { error => 'user_email required' }, status => 400) unless $user =~ /\@/;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/invites/quota/' . Mojo::Util::url_escape($user)) // {}));
}
sub admin_invite_quota_set ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my ($mp, $md) = (_trim($c->param('max_pending') // ''), _trim($c->param('max_per_day') // ''));
    return $c->render(json => { error => 'user_email + two non-negative integers required' }, status => 400)
        unless $user =~ /\@/ && $mp =~ /^\d+$/ && $md =~ /^\d+$/;
    my $tx = $UA->put($c->app->api_base . '/api/v1/invites/quota/' . Mojo::Util::url_escape($user)
        => { Authorization => "Bearer $jwt" } => json => { max_pending => $mp + 0, max_per_day => $md + 0 });
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}
sub admin_user_sessions ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    return $c->render(json => { error => 'user_email required' }, status => 400) unless $user =~ /\@/;
    return $c->render(json => (_api_get($c, $jwt, Mojo::URL->new('/api/v1/auth/sessions')->query(user => $user)->to_string) // []));
}
sub admin_user_session_revoke ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my $jti  = _trim($c->param('jti') // '');
    return $c->render(json => { error => 'user_email and jti required' }, status => 400) unless $user =~ /\@/ && length $jti;
    my $url = Mojo::URL->new($c->app->api_base . '/api/v1/auth/sessions/' . Mojo::Util::url_escape($jti))->query(user => $user);
    my $tx = $UA->delete($url => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Roles & permissions (RBAC), site_admin -----
sub admin_roles_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    return $c->render(json => {
        roles       => (_api_get($c, $jwt, '/api/v1/admin/roles') // []),
        permissions => (_api_get($c, $jwt, '/api/v1/admin/permissions') // []),
    });
}
sub admin_role_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $name = _trim($c->param('name') // '');
    return $c->render(json => { error => 'a role name is required' }, status => 400) unless length $name;
    my %body = (name => $name);
    my $desc = _trim($c->param('description') // '');
    $body{description} = $desc if length $desc;
    my $tx = $UA->post($c->app->api_base . '/api/v1/admin/roles'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'add failed' }), status => ($tx->res->code // 502));
}
sub admin_role_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $name = _trim($c->param('name') // '');
    return $c->render(json => { error => 'role name required' }, status => 400) unless length $name;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/admin/roles/' . Mojo::Util::url_escape($name)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub _role_perm_tx ($c, $method) {
    my ($email, $jwt) = _admin_auth($c);
    return (undef) unless $email;
    my $role = _trim($c->param('role') // '');
    my $perm = _trim($c->param('permission') // '');
    return ('bad') unless length $role && length $perm;
    my $url = $c->app->api_base . '/api/v1/admin/roles/' . Mojo::Util::url_escape($role)
            . '/permissions/' . Mojo::Util::url_escape($perm);
    return ($UA->$method($url => { Authorization => "Bearer $jwt" }));
}
sub admin_role_grant_perm ($c) {
    my $tx = _role_perm_tx($c, 'post');
    return $c->render(json => { error => 'forbidden' }, status => 403) unless defined $tx;
    return $c->render(json => { error => 'role and permission required' }, status => 400) if $tx eq 'bad';
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub admin_role_revoke_perm ($c) {
    my $tx = _role_perm_tx($c, 'delete');
    return $c->render(json => { error => 'forbidden' }, status => 403) unless defined $tx;
    return $c->render(json => { error => 'role and permission required' }, status => 400) if $tx eq 'bad';
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
# Grant/revoke a role to a user (the api is keyed by user id, so resolve email).
sub _user_role_change ($c, $grant) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $user = _trim($c->param('user_email') // '');
    my $role = _trim($c->param('role') // '');
    return $c->render(json => { error => 'user_email and role are required' }, status => 400)
        unless $user =~ /\@/ && length $role;
    my $users = _api_get($c, $jwt, Mojo::URL->new('/api/v1/admin/users')->query(q => $user, limit => 20)->to_string) // [];
    my ($u) = grep { lc($_->{email} // '') eq lc($user) } @$users;
    return $c->render(json => { error => "no such user: $user" }, status => 404) unless $u;
    my $tx = $grant
        ? $UA->post($c->app->api_base . "/api/v1/admin/users/$u->{id}/roles"
            => { Authorization => "Bearer $jwt" } => json => { role => $role })
        : $UA->delete($c->app->api_base . "/api/v1/admin/users/$u->{id}/roles/" . Mojo::Util::url_escape($role)
            => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub admin_user_grant_role  ($c) { _user_role_change($c, 1) }
sub admin_user_revoke_role ($c) { _user_role_change($c, 0) }

# GET /admin/dovecot/status -- the dovecot mailbox-serving pool (active/passive
# roles + live health). First item of the Dovecot admin sub-tab.
sub admin_dovecot_status ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => {}, status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/dovecot/status') // { error => 'unavailable' }));
}

# GET /admin/domains/catch-alls -- every managed domain + its current catch-all
# destination. Feeds the domain search + the "view all domains" bulk picker.
sub admin_catchalls ($c) {
    my ($email, $jwt) = _catchall_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/catch-alls') // []));
}

# POST /admin/domains/catch-all/set {domain, destination, send_enabled?} --
# validate the destination is a real mailbox, then upsert the domain's
# catch-all. send_enabled controls whether the catch-all may SEND AS
# <anyone>@<domain> (domain send-as); the form always sends it, so it is
# WYSIWYG against the checkbox (the UI pre-fills it from the current state).
sub admin_set_catchall ($c) {
    my ($email, $jwt) = _catchall_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _trim($c->param('domain') // '');
    my $dest   = _trim($c->param('destination') // '');
    return $c->render(json => { error => 'domain and destination are required' }, status => 400)
        unless $domain =~ /\./ && $dest =~ /\@/;
    return $c->render(json => { error => "$dest is not a real, active mailbox" }, status => 400)
        unless _user_exists($c, $jwt, $dest);
    my $tx = $UA->put($c->app->api_base . "/api/v1/domains/$domain/catch-all"
        => { Authorization => "Bearer $jwt" }
        => json => { destination => $dest, send_enabled => ($c->param('send_enabled') ? \1 : \0) });
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}

# POST /admin/domains/catch-all/clear {domain}
sub admin_clear_catchall ($c) {
    my ($email, $jwt) = _catchall_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _trim($c->param('domain') // '');
    return $c->render(json => { error => 'domain is required' }, status => 400) unless $domain =~ /\./;
    my $tx = $UA->delete($c->app->api_base . "/api/v1/domains/$domain/catch-all"
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { error => 'clear failed' }), status => ($tx->res->code // 502));
}

# POST /admin/domains/catch-all/bulk {domains (comma-separated), destination}
# -- set the SAME destination on several domains at once. Validates the
# destination once, then applies per-domain, reporting per-domain results.
sub admin_bulk_catchall ($c) {
    my ($email, $jwt) = _catchall_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $dest = _trim($c->param('destination') // '');
    my @domains = grep { /\./ } map { _trim($_) } split /,/, ($c->param('domains') // '');
    return $c->render(json => { error => 'select at least one domain' }, status => 400) unless @domains;
    return $c->render(json => { error => "$dest is not a real, active mailbox" }, status => 400)
        unless _user_exists($c, $jwt, $dest);
    my (@set, @failed);
    for my $d (@domains) {
        my $tx = $UA->put($c->app->api_base . "/api/v1/domains/$d/catch-all"
            => { Authorization => "Bearer $jwt" } => json => { destination => $dest });
        if (($tx->res->code // 0) == 200) { push @set, $d }
        else { push @failed, { domain => $d, error => (eval { $tx->res->json->{error} } // ('HTTP ' . ($tx->res->code // 0))) } }
    }
    return $c->render(json => { destination => $dest, set => \@set, failed => \@failed });
}

sub _trim ($s) { $s //= ''; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s; }

# ----- Send-as grants (mail aliases), site_admin -----
sub admin_aliases_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/mail-aliases') // []));
}
sub admin_alias_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src  = _trim($c->param('source_pattern') // '');
    my $dest = _trim($c->param('destination') // '');
    return $c->render(json => { error => 'source_pattern (user@domain or @domain) and destination are required' }, status => 400)
        unless $src =~ /\@/ && $dest =~ /\@/;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/mail-aliases'
        => { Authorization => "Bearer $jwt" }
        => json => { source_pattern => $src, destination => $dest, send_enabled => ($c->param('send_enabled') ? \1 : \0) });
    return $c->render(json => (eval { $tx->res->json } // { error => 'add failed' }), status => ($tx->res->code // 502));
}
sub admin_alias_set_send ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src = _trim($c->param('source_pattern') // '');
    return $c->render(json => { error => 'source_pattern required' }, status => 400) unless $src =~ /\@/;
    my $tx = $UA->patch($c->app->api_base . '/api/v1/domains/mail-aliases/' . Mojo::Util::url_escape($src)
        => { Authorization => "Bearer $jwt" } => json => { send_enabled => ($c->param('send_enabled') ? \1 : \0) });
    return $c->render(json => (eval { $tx->res->json } // {}), status => ($tx->res->code // 502));
}
sub admin_alias_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $src = _trim($c->param('source_pattern') // '');
    return $c->render(json => { error => 'source_pattern required' }, status => 400) unless $src =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/mail-aliases/' . Mojo::Util::url_escape($src)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# ----- Site-wide recipient access (allow/block), site_admin -----
sub admin_racc_list ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/domains/recipient-access') // []));
}
sub admin_racc_set ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    my $action    = (($c->param('action') // '') eq 'allow') ? 'OK' : 'REJECT';
    return $c->render(json => { error => 'a valid recipient is required' }, status => 400) unless $recipient =~ /\@/;
    my %body = (recipient => $recipient, action => $action);
    my $reason = _trim($c->param('reason') // '');
    $body{reason} = $reason if length $reason;
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains/recipient-access'
        => { Authorization => "Bearer $jwt" } => json => \%body);
    return $c->render(json => (eval { $tx->res->json } // { error => 'set failed' }), status => ($tx->res->code // 502));
}
sub admin_racc_remove ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $recipient = _trim($c->param('recipient') // '');
    return $c->render(json => { error => 'recipient required' }, status => 400) unless $recipient =~ /\@/;
    my $tx = $UA->delete($c->app->api_base . '/api/v1/domains/recipient-access/' . Mojo::Util::url_escape($recipient)
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# Add a managed domain (POST /api/v1/domains). dns_managed=true also creates a
# PowerDNS zone; leave it off for a domain whose DNS lives elsewhere.
sub admin_domain_add ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = _trim($c->param('domain_name') // '');
    unless ($domain =~ /\./) { $c->flash(admin_err => 'Enter a valid domain name.'); return $c->redirect_to('/#admin:mail'); }
    my $tx = $UA->post($c->app->api_base . '/api/v1/domains'
        => { Authorization => "Bearer $jwt" }
        => json => {
            domain_name  => $domain,
            mail_enabled => ($c->param('mail_enabled') ? \1 : \0),
            dns_managed  => ($c->param('dns_managed')  ? \1 : \0),
        });
    _admin_flash($c, $tx, "Domain $domain added.");
    return $c->redirect_to('/#admin:mail');
}

# Enable/disable a domain's mail acceptance (PATCH /api/v1/domains/:domain).
sub admin_domain_toggle ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = _trim($c->param('domain') // '');
    return $c->redirect_to('/#admin:mail') unless $domain =~ /\./;
    my $enable = (($c->param('action') // '') eq 'enable') ? \1 : \0;
    my $tx = $UA->patch($c->app->api_base . "/api/v1/domains/$domain"
        => { Authorization => "Bearer $jwt" } => json => { mail_enabled => $enable });
    _admin_flash($c, $tx, ($$enable ? "Mail enabled for $domain." : "Mail disabled for $domain."));
    return $c->redirect_to('/#admin:mail');
}

# Toggle the block-link footer per domain. mode: header (link only, no
# body append) | body | both. enabled on/off is the master switch.
sub admin_block_link ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain  = $c->param('domain') // '';
    my $enabled = $c->param('enabled') ? \1 : \0;
    my $mode    = $c->param('mode') // 'both';
    my $tx = $UA->put($c->app->api_base . "/api/v1/block-link/domains/$domain"
        => { Authorization => "Bearer $jwt" } => json => { enabled => $enabled, mode => $mode });
    _admin_flash($c, $tx, "Block-link settings for $domain saved.");
    return $c->redirect_to('/#admin:mail');
}

# Force-update DKIM for a domain = rotate a new selector, then activate it.
sub admin_dkim ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $auth = { Authorization => "Bearer $jwt" };
    my $rot = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dkim/rotate" => $auth => json => {});
    if (($rot->res->code // 0) != 201) {
        _admin_flash($c, $rot, '');
        return $c->redirect_to('/#admin:mail');
    }
    my $selector = eval { $rot->res->json->{selector} };
    my $act = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dkim/$selector/activate" => $auth => json => {});
    _admin_flash($c, $act, "DKIM rotated + activated for $domain (selector $selector).");
    return $c->redirect_to('/#admin:mail');
}

# --- DKIM selector lifecycle detail (JSON, site_admin) -------------------
sub _dkim_dom ($c) {
    my $d = _trim($c->param('domain') // '');
    return $d =~ /^[A-Za-z0-9.\-]+$/ ? $d : undef;
}
sub admin_dkim_selectors ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $domain = _dkim_dom($c) or return $c->render(json => { error => 'a valid domain is required' }, status => 400);
    return $c->render(json => (_api_get($c, $jwt, "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dkim/selectors") // []));
}
sub _dkim_action ($c, $build) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _dkim_dom($c) or return $c->render(json => { error => 'a valid domain is required' }, status => 400);
    my ($method, $path) = $build->($domain, _trim($c->param('selector') // ''));
    return $c->render(json => { error => 'a selector is required' }, status => 400) unless defined $path;
    my $tx = $UA->build_tx(uc($method) => $c->app->api_base . $path => { Authorization => "Bearer $jwt" } => json => {});
    $tx = $UA->start($tx);
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}
sub admin_dkim_rotate ($c) {
    _dkim_action($c, sub ($domain, $sel) { ('POST', "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dkim/rotate") });
}
sub admin_dkim_activate ($c) {
    _dkim_action($c, sub ($domain, $sel) { length $sel ? ('POST', "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dkim/" . Mojo::Util::url_escape($sel) . "/activate") : () });
}
sub admin_dkim_retire ($c) {
    _dkim_action($c, sub ($domain, $sel) { length $sel ? ('POST', "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dkim/" . Mojo::Util::url_escape($sel) . "/retire") : () });
}
sub admin_dkim_cancel ($c) {
    _dkim_action($c, sub ($domain, $sel) { length $sel ? ('DELETE', "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dkim/" . Mojo::Util::url_escape($sel)) : () });
}

# --- Raw DNS record CRUD (JSON, site_admin) ------------------------------
sub admin_dns_records ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    my $domain = _dkim_dom($c) or return $c->render(json => { error => 'a valid domain is required' }, status => 400);
    my $tx = $UA->get($c->app->api_base . "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dns/records"
        => { Authorization => "Bearer $jwt" });
    return $c->render(json => (eval { $tx->res->json } // []), status => ($tx->res->code // 502));
}
sub admin_dns_record_set ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _dkim_dom($c) or return $c->render(json => { error => 'a valid domain is required' }, status => 400);
    my $name = _trim($c->param('name') // '');
    my $type = uc(_trim($c->param('type') // ''));
    # content: one value per line (REPLACE semantics -- the full set for name+type).
    my @content = grep { length } map { _trim($_) } split /\r?\n/, ($c->param('content') // '');
    my $ttl = _trim($c->param('ttl') // '');
    $ttl = ($ttl =~ /^\d+$/) ? $ttl + 0 : 3600;
    return $c->render(json => { error => 'name, type, and at least one value are required' }, status => 400)
        unless length $name && length $type && @content;
    my $tx = $UA->post($c->app->api_base . "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dns/records"
        => { Authorization => "Bearer $jwt" } => json => { name => $name, type => $type, content => \@content, ttl => $ttl });
    return $c->render(json => (eval { $tx->res->json } // { error => 'write failed' }), status => ($tx->res->code // 502));
}
# --- Fleet status dashboard (JSON, site_admin) ---------------------------
sub admin_fleet_hosts ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/agent/hosts') // []));
}
# --- DMARC aggregate report review (site_admin) -----------------------
# Thin forwards to homelab-api's /api/v1/dmarc/* (backed by
# homelab-domain-admin). Read-only: there is no endpoint here that triggers
# a mailbox fetch -- that is a timer on the domain-admin hosts.
#
# Query parameters are rebuilt from scratch rather than passed through, so
# nothing a browser sends can reshape the upstream URL.
sub _dmarc_days ($c) {
    my $d = $c->param('days') // 30;
    return ($d =~ /^\d+$/ && $d > 0 && $d <= 3650) ? $d + 0 : 30;
}
sub admin_dmarc_status ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/dmarc/status') // {}));
}
sub admin_dmarc_summary ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $path = '/api/v1/dmarc/summary?days=' . _dmarc_days($c);
    return $c->render(json => (_api_get($c, $jwt, $path) // { domains => [] }));
}
sub admin_dmarc_sources ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $path = '/api/v1/dmarc/sources?days=' . _dmarc_days($c);
    $path .= '&failing=1' if $c->param('failing');
    my $domain = $c->param('domain');
    $path .= '&domain=' . Mojo::Util::url_escape($domain)
        if defined $domain && $domain =~ /^[A-Za-z0-9.-]{1,253}$/;
    return $c->render(json => (_api_get($c, $jwt, $path) // { sources => [] }));
}
sub admin_dmarc_reports ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $path = '/api/v1/dmarc/reports?days=' . _dmarc_days($c);
    return $c->render(json => (_api_get($c, $jwt, $path) // { reports => [] }));
}

sub admin_fleet_mismatches ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => [], status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/agent/status/mismatches') // []));
}
sub admin_topology ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/agent/topology') // { nodes => [], edges => [], hosts => [] }));
}

sub admin_ha_status ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    return $c->render(json => (_api_get($c, $jwt, '/api/v1/admin/ha/status') // { components => [] }));
}

sub admin_dns_record_delete ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->render(json => { error => 'forbidden' }, status => 403) unless $email;
    my $domain = _dkim_dom($c) or return $c->render(json => { error => 'a valid domain is required' }, status => 400);
    my $name = _trim($c->param('name') // '');
    my $type = uc(_trim($c->param('type') // ''));
    return $c->render(json => { error => 'name and type are required' }, status => 400) unless length $name && length $type;
    my $tx = $UA->delete($c->app->api_base . "/api/v1/domains/" . Mojo::Util::url_escape($domain) . "/dns/records"
        => { Authorization => "Bearer $jwt" } => json => { name => $name, type => $type });
    return $c->render(json => (eval { $tx->res->json } // { ok => \1 }), status => ($tx->res->code // 502));
}

# Set SPF (apex TXT). NOTE: this REPLACES the domain's entire apex TXT
# record set (PowerDNS REPLACE semantics) -- documented in the UI.
sub admin_spf ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $value  = $c->param('value') // 'v=spf1 mx ~all';
    my $tx = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dns/records"
        => { Authorization => "Bearer $jwt" }
        => json => { name => $domain, type => 'TXT', content => [$value], ttl => 3600 });
    _admin_flash($c, $tx, "SPF set for $domain.");
    return $c->redirect_to('/#admin:mail');
}

# Set DMARC (_dmarc TXT). Builds the value from a policy + optional rua.
sub admin_dmarc ($c) {
    my ($email, $jwt) = _admin_auth($c);
    return $c->redirect_to('/login') unless $email;
    my $domain = $c->param('domain') // '';
    my $policy = $c->param('policy') // 'none';
    $policy = 'none' unless $policy =~ /^(none|quarantine|reject)$/;
    my $rua    = $c->param('rua') // '';
    my $value  = "v=DMARC1; p=$policy";
    $value .= "; rua=mailto:$rua" if $rua =~ /\S/;
    my $tx = $UA->post($c->app->api_base . "/api/v1/domains/$domain/dns/records"
        => { Authorization => "Bearer $jwt" }
        => json => { name => "_dmarc.$domain", type => 'TXT', content => [$value], ttl => 3600 });
    _admin_flash($c, $tx, "DMARC set for $domain (p=$policy).");
    return $c->redirect_to('/#admin:mail');
}

1;
