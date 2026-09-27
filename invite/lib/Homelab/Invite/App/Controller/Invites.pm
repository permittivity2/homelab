package Homelab::Invite::App::Controller::Invites;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::UserAgent;
use Mojo::Util qw(xml_escape);
use Homelab::Invite::Mailer qw(send_mail);
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::Common::Registry qw(system_agent_token lookup);

# 32 random bytes, hex-encoded -- same /dev/urandom-backed idiom as
# homelab-api's own Auth::generate_jti (that module lives inside the
# homelab-api distribution, not homelab-common, so it isn't importable
# here -- this is a deliberate, tiny duplication of a well-established
# pattern, not a new one).
sub _generate_token {
    open(my $fh, '<', '/dev/urandom') or die "cannot open /dev/urandom: $!";
    read($fh, my $bytes, 32) == 32 or die 'short read from /dev/urandom';
    close($fh);
    return unpack('H*', $bytes);
}

sub _quota_for ($c, $sender_email) {
    my $override = $c->app->pg->db->query(
        'SELECT max_pending, max_per_day FROM invite.invite_quotas WHERE sender_email = ?', $sender_email,
    )->hash;
    return $override
        if $override;
    my $cfg = $c->app->invite_config;
    return { max_pending => $cfg->{default_max_pending}, max_per_day => $cfg->{default_max_per_day} };
}

# POST /internal/v1/invites {recipient_email, message?, channel?}
# channel defaults to 'cli': this service sends the email itself in
# that case (see Homelab::Invite::Mailer). channel='roundcube_plugin'
# skips that -- the caller (the Roundcube add-on) sends it itself via
# $RCMAIL->deliver_message() as the real logged-in sender, which is
# both simpler (no new mail code there) and more deliverable (DKIM-
# aligned to the sender's own domain). Either way the token/quota/
# dedup logic below is identical and lives in exactly one place.
sub create ($c) {
    my $email = $c->authenticated_email_any or return;
    my $body = $c->req->json // {};
    my $recipient = $body->{recipient_email};
    my $channel   = $body->{channel} // 'cli';
    return $c->render(json => { error => 'recipient_email is required' }, status => 400)
        unless $recipient && $recipient =~ /^[^@\s]+\@[^@\s]+\.[^@\s]+$/;
    return $c->render(json => { error => "channel must be 'cli' or 'roundcube_plugin'" }, status => 400)
        unless $channel eq 'cli' || $channel eq 'roundcube_plugin';

    my $quota = _quota_for($c, $email);
    my $pending_count = $c->app->pg->db->query(
        q{SELECT COUNT(*) AS n FROM invite.invites WHERE sender_email = ? AND status = 'pending'}, $email,
    )->hash->{n};
    return $c->render(json => { error => "pending invite limit reached ($quota->{max_pending})" }, status => 429)
        if $pending_count >= $quota->{max_pending};

    my $today_count = $c->app->pg->db->query(
        q{SELECT COUNT(*) AS n FROM invite.invites WHERE sender_email = ? AND created_at > NOW() - INTERVAL '1 day'},
        $email,
    )->hash->{n};
    return $c->render(json => { error => "daily invite limit reached ($quota->{max_per_day})" }, status => 429)
        if $today_count >= $quota->{max_per_day};

    my $existing_pending = $c->app->pg->db->query(
        q{SELECT id FROM invite.invites WHERE sender_email = ? AND recipient_email = ? AND status = 'pending'},
        $email, $recipient,
    )->hash;
    return $c->render(json => { error => 'you already have a pending invite to this address' }, status => 409)
        if $existing_pending;

    my $ttl_days = $c->app->invite_config->{ttl_days};
    my $token = _generate_token();
    my $row = eval {
        $c->app->pg->db->query(
            q{INSERT INTO invite.invites (token, sender_email, recipient_email, channel, message, expires_at)
              VALUES (?, ?, ?, ?, ?, NOW() + (? || ' days')::INTERVAL) RETURNING *},
            $token, $email, $recipient, $channel, $body->{message}, $ttl_days,
        )->hash;
    };
    if (!$row) {
        # The partial unique index (sender_email, recipient_email WHERE
        # status='pending') is the real, race-safe enforcement -- the
        # pre-check above is just a fast path that avoids hitting it in
        # the common case. A concurrent double-send from two requests
        # lands here instead.
        return $c->render(json => { error => 'you already have a pending invite to this address' }, status => 409);
    }

    my $url = $c->app->invite_config->{public_base_url} . '/invite/' . $token;

    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'),
        action => 'invite.create', resource_type => 'invite', resource_id => $row->{id},
        source_service => 'homelab-invite', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { recipient_email => $recipient, channel => $channel },
    );

    if ($channel eq 'cli') {
        my $mcfg = $c->app->mailer_config;
        eval {
            send_mail(
                smtp_host => $mcfg->{smtp_host}, smtp_port => $mcfg->{smtp_port},
                from_email => $mcfg->{email}, from_password => $mcfg->{smtp_password},
                to => $recipient, subject => "You're invited",
                body => "You've been invited by $email.\n\n"
                      . ($body->{message} ? "$body->{message}\n\n" : '')
                      . "Click here to accept: $url\n\nThis link expires in $ttl_days days.",
            );
        };
        if ($@) {
            $c->app->log->warn("homelab-invite: failed to send invite email to $recipient: $@");
            # The row already exists and the link is real/usable even if
            # the email itself didn't go out (e.g. mailer credential
            # rotated) -- surface that rather than pretending the whole
            # call failed, since the caller can still hand the URL to
            # the recipient another way.
            return $c->render(json => { %$row, url => $url, warning => 'invite created but the email could not be sent' }, status => 201);
        }
    }

    return $c->render(json => { %$row, url => $url }, status => 201);
}

# GET /internal/v1/invites[?all=true]
sub list ($c) {
    my $email = $c->authenticated_email_any or return;
    my $all = $c->param('all');
    if ($all && $all eq 'true') {
        return $c->render(json => { error => 'site_admin role required for ?all=true' }, status => 403)
            unless $c->is_site_admin;
        return $c->render(json => $c->app->pg->db->query(
            'SELECT * FROM invite.invites ORDER BY created_at DESC',
        )->hashes->to_array);
    }
    return $c->render(json => $c->app->pg->db->query(
        'SELECT * FROM invite.invites WHERE sender_email = ? ORDER BY created_at DESC', $email,
    )->hashes->to_array);
}

# DELETE /internal/v1/invites/:id[?user=EMAIL]
# Scoped to `sender_email = ?` in the query itself (never checked only
# after the fact) -- same discipline as domain-admin's delete_mine:
# this can only ever revoke a row the caller owns, unless ?user= is
# also given AND the caller is site_admin.
sub delete_entry ($c) {
    my $email = $c->authenticated_email_any or return;
    my $id = $c->stash('id');
    my $target_user = $c->param('user');
    if ($target_user) {
        return $c->render(json => { error => 'site_admin role required for ?user=' }, status => 403)
            unless $c->is_site_admin;
    }
    my $scope_email = $target_user // $email;

    my $row = $c->app->pg->db->query(
        q{UPDATE invite.invites SET status = 'revoked', revoked_at = NOW(), revoked_by_email = ?
          WHERE id = ? AND sender_email = ? AND status = 'pending' RETURNING *},
        $email, $id, $scope_email,
    )->hash;
    return $c->render(json => { error => 'not found (or not pending, or not yours)' }, status => 404) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $scope_email, jti => $c->stash('current_jti'),
        action => 'invite.revoke', resource_type => 'invite', resource_id => $id,
        source_service => 'homelab-invite', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { recipient_email => $row->{recipient_email} },
    );
    return $c->render(json => { ok => \1 });
}

sub quota_show_mine ($c) {
    my $email = $c->authenticated_email_any or return;
    return $c->render(json => _quota_for($c, $email));
}

sub quota_show ($c) {
    $c->authenticated_site_admin or return;
    return $c->render(json => _quota_for($c, $c->stash('sender_email')));
}

# PUT /internal/v1/invites/quota/:sender_email {max_pending, max_per_day}
sub quota_set ($c) {
    my $admin = $c->authenticated_site_admin or return;
    my $sender_email = $c->stash('sender_email');
    my $body = $c->req->json // {};
    my ($max_pending, $max_per_day) = @{$body}{qw(max_pending max_per_day)};
    return $c->render(json => { error => 'max_pending and max_per_day are required' }, status => 400)
        unless defined($max_pending) && defined($max_per_day);

    my $row = $c->app->pg->db->query(
        q{INSERT INTO invite.invite_quotas (sender_email, max_pending, max_per_day, updated_by_email)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (sender_email) DO UPDATE
              SET max_pending = EXCLUDED.max_pending, max_per_day = EXCLUDED.max_per_day,
                  updated_by_email = EXCLUDED.updated_by_email, updated_at = NOW()
          RETURNING *},
        $sender_email, $max_pending, $max_per_day, $admin,
    )->hash;
    enqueue(
        $c->app->pg->db, actor_email => $admin, affected_user => $sender_email, jti => $c->stash('current_jti'),
        action => 'invite.quota_set', resource_type => 'invite_quota', resource_id => $sender_email,
        source_service => 'homelab-invite', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { max_pending => $max_pending, max_per_day => $max_per_day },
    );
    return $c->render(json => $row);
}

# POST /internal/v1/invites/consume {token, email}
# Server-to-server only -- called by homelab-api's own _register,
# never by an end user directly (see App.pm's authenticated_system_
# agent helper). Atomically flips pending -> accepted in one UPDATE ...
# WHERE status='pending' AND expires_at > NOW(), closing the
# double-accept race (two concurrent accepts on the same token: exactly
# one UPDATE actually matches a row).
#
# `email` here is the account's CHOSEN login (<username>@<account_domain>),
# recorded as accepted_user_email -- as of 2026-09-27 that is NO LONGER
# required to equal the invite's own recipient_email. The old model made
# the account BE the invited address, so consume enforced
# recipient_email == email as an anti-tampering guard; the new model
# lets the invitee pick any available fleet-domain username (the invite
# recipient_email becomes merely the contact/recovery address), so that
# equality is gone by design. The token itself is still the single-use
# capability -- whoever holds a valid one may claim one available
# username, which is exactly the intended trust model.
sub consume ($c) {
    $c->authenticated_system_agent or return;
    my $body = $c->req->json // {};
    my ($token, $email) = @{$body}{qw(token email)};
    return $c->render(json => { error => 'token and email are required' }, status => 400)
        unless $token && $email;

    my $existing = $c->app->pg->db->query('SELECT * FROM invite.invites WHERE token = ?', $token)->hash;
    return $c->render(json => { error => 'invite not found' }, status => 404) unless $existing;

    my $row = $c->app->pg->db->query(
        q{UPDATE invite.invites SET status = 'accepted', accepted_at = NOW(), accepted_user_email = ?
          WHERE token = ? AND status = 'pending' AND expires_at > NOW() RETURNING *},
        $email, $token,
    )->hash;
    return $c->render(json => { error => 'invite already used, revoked, or expired' }, status => 409) unless $row;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email,
        action => 'invite.consume', resource_type => 'invite', resource_id => $row->{id},
        source_service => 'homelab-invite', ip_address => $c->tx->remote_address,
        user_agent => $c->req->headers->user_agent, detail => { sender_email => $row->{sender_email} },
    );
    return $c->render(json => { ok => \1 });
}

# GET /invite/:token -- public, unauthenticated. Renders a minimal,
# self-contained HTML page (no templates/ directory -- see README.md's
# "Why inline HTML" note: this is the only page any homelab-* backend
# service has ever needed to render, and a whole templating layer for
# one page is more machinery than the task warrants). Every dynamic
# value is xml_escape()'d before interpolation -- the recipient email
# and the sender's optional free-text message are both real,
# attacker-influenceable strings (message is set by whoever sent the
# invite, not necessarily trustworthy).
sub show ($c) {
    my $token = $c->stash('token');
    my $ip = $c->tx->remote_address // 'unknown';

    if (_rate_limited($c, $ip)) {
        _log_attempt($c, $ip, $token, 'rate_limited');
        return $c->render(text => _page('Too many attempts', 'Too many attempts from this address. Try again later.'),
            format => 'html', status => 429);
    }

    my $row = $c->app->pg->db->query(
        q{SELECT *, (status = 'pending' AND expires_at <= NOW()) AS is_expired
          FROM invite.invites WHERE token = ?}, $token,
    )->hash;
    unless ($row) {
        _log_attempt($c, $ip, $token, 'invalid_token');
        return $c->render(text => _page('Invalid invite', 'This invite link is not valid.'), format => 'html', status => 404);
    }
    if ($row->{is_expired}) {
        $c->app->pg->db->query(q{UPDATE invite.invites SET status = 'expired' WHERE id = ?}, $row->{id});
        $row->{status} = 'expired';
    }
    if ($row->{status} ne 'pending') {
        _log_attempt($c, $ip, $token, $row->{status} eq 'expired' ? 'expired' : 'already_used');
        return $c->render(text => _page('Invite no longer valid', 'This invite has already been used, been revoked, or expired.'),
            format => 'html', status => 410);
    }

    # Reject early, with a clear page, if the invite's own CONTACT
    # address is itself on a fleet-managed mail domain -- see accept()'s
    # own comment + _recipient_domain_error. Better UX than letting the
    # user fill the whole form and only then be refused; accept()
    # re-checks regardless so this is UX, not the enforcement boundary.
    my $domain_error = _recipient_domain_error($c, $row->{recipient_email});
    if ($domain_error) {
        _log_attempt($c, $ip, $token, 'domain_rejected');
        return $c->render(text => _page('Invite cannot be used', $domain_error), format => 'html', status => 403);
    }

    _log_attempt($c, $ip, $token, 'success');
    my $recipient  = xml_escape($row->{recipient_email});
    my $recip_attr = xml_escape($row->{recipient_email});
    my $message    = $row->{message} ? '<p class="msg">"' . xml_escape($row->{message}) . '"</p>' : '';
    my $token_html = xml_escape($token);
    my $domain     = xml_escape(_account_domain($c));
    return $c->render(format => 'html', text => qq{<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>You're invited</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;max-width:30em;margin:3em auto;padding:0 1em;color:#1a1a1a}
label{display:block;font-weight:600;font-size:.9em;margin:1em 0 .25em}
input{width:100%;padding:.55em .7em;border:1px solid #d5d8dd;border-radius:6px;box-sizing:border-box;font-size:1em}
.uname-row{display:flex;align-items:stretch}
.uname-row input{border-top-right-radius:0;border-bottom-right-radius:0}
.uname-suffix{display:flex;align-items:center;padding:0 .7em;border:1px solid #d5d8dd;border-left:0;border-top-right-radius:6px;border-bottom-right-radius:6px;background:#f5f6f8;color:#6b7280;white-space:nowrap}
button{margin-top:1.4em;padding:.65em 1.2em;border:0;border-radius:6px;background:#3562d4;color:#fff;font-size:1em;font-weight:600;cursor:pointer}
button:hover{background:#2a4fb0}
.chip{display:inline-block;margin:.25em .35em .25em 0;padding:.3em .7em;border:1px solid #3562d4;border-radius:14px;background:#eef2fd;color:#2a4fb0;cursor:pointer;font-size:.85em}
.hint{font-size:.8em;color:#6b7280;margin:.25em 0 0}
.msg{font-style:italic;color:#555}.err{color:#b00;margin-top:1em}.ok{color:#1a7f37}</style></head>
<body>
<h1>You're invited</h1>
$message
<p>Create your account. Pick a username &mdash; your login will be that name at <strong>$domain</strong>.</p>
<label for="username">Username</label>
<div class="uname-row">
  <input type="text" id="username" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="yourname" autofocus>
  <span class="uname-suffix">\@$domain</span>
</div>
<div id="ustatus" class="hint"></div>
<label for="pw">Password</label>
<input type="password" id="pw" placeholder="At least 8 characters">
<label for="pw2">Confirm password</label>
<input type="password" id="pw2" placeholder="Re-enter your password">
<label for="recovery">Recovery email (optional)</label>
<input type="email" id="recovery" value="$recip_attr">
<p class="hint">If you ever forget your password, we'll email a reset link here. Pre-filled with the address your invite was sent to &mdash; edit or clear it as you like.</p>
<button id="go">Create account</button>
<p id="err" class="err"></p>
<script>
var TOKEN = '$token_html';
var DOMAIN = '$domain';
var ustatus = document.getElementById('ustatus');
var errEl = document.getElementById('err');
var unameEl = document.getElementById('username');

async function postJSON(path, data) {
    var r = await fetch(path, {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(data)
    });
    var j = {};
    try { j = await r.json(); } catch (e) {}
    return { ok: r.ok, status: r.status, body: j };
}

function renderSuggestions(list) {
    ustatus.innerHTML = '';
    if (!list || !list.length) return;
    var span = document.createElement('span');
    span.textContent = 'Try: ';
    ustatus.appendChild(span);
    list.forEach(function (name) {
        var chip = document.createElement('span');
        chip.className = 'chip';
        chip.textContent = name;
        chip.onclick = function () {
            unameEl.value = name;
            ustatus.innerHTML = '';
            checkUsername();
        };
        ustatus.appendChild(chip);
    });
}

async function checkUsername() {
    var u = unameEl.value.trim();
    ustatus.className = 'hint';
    ustatus.textContent = '';
    if (!u) return;
    var res = await postJSON('/invite/' + TOKEN + '/username', { username: u });
    if (!res.ok) { return; }
    var b = res.body;
    if (b.invalid) { ustatus.className = 'hint err'; ustatus.textContent = b.error || 'Invalid username.'; return; }
    if (b.available) { ustatus.className = 'hint ok'; ustatus.textContent = u.toLowerCase() + '\@' + DOMAIN + ' is available.'; return; }
    ustatus.className = 'hint';
    renderSuggestions(b.suggestions);
}

unameEl.addEventListener('blur', checkUsername);

document.getElementById('go').onclick = async function () {
    errEl.textContent = '';
    var username = unameEl.value.trim();
    var pw = document.getElementById('pw').value;
    var pw2 = document.getElementById('pw2').value;
    var recovery = document.getElementById('recovery').value.trim();
    if (!username) { errEl.textContent = 'Please choose a username.'; return; }
    if (pw.length < 8) { errEl.textContent = 'Password must be at least 8 characters.'; return; }
    if (pw !== pw2) { errEl.textContent = 'The two passwords do not match.'; return; }

    var res = await postJSON('/invite/' + TOKEN + '/accept', {
        username: username, password: pw, password_confirm: pw2, recovery_email: recovery
    });
    if (res.ok && res.body.ok) {
        document.body.innerHTML = '<h1>Account created</h1><p>Your login is <strong>' +
            (res.body.email || (username.toLowerCase() + '\@' + DOMAIN)) +
            '</strong>. You can now log in.</p>';
        return;
    }
    if (res.body.suggestions) {
        errEl.textContent = 'That username is no longer available &mdash; try one of these:';
        renderSuggestions(res.body.suggestions);
        return;
    }
    errEl.textContent = res.body.error || 'Something went wrong.';
};
</script>
</body></html>});
}

# POST /invite/:token/username {username} -- public. Live availability
# check for the acceptance page's own username field (called on blur).
# Same rate limiter + pending-token gate as accept(); proxies to
# homelab-api's system_agent-gated /auth/username-availability (this
# service holds the agent credential; the browser never does). Passes
# {available} / {available, suggestions} / {available:false, invalid,
# error} straight back to the page's JS.
sub check_username ($c) {
    my $token = $c->stash('token');
    my $ip = $c->tx->remote_address // 'unknown';
    return $c->render(json => { error => 'too many attempts, try again later' }, status => 429)
        if _rate_limited($c, $ip);

    my $pending = $c->app->pg->db->query(
        q{SELECT 1 FROM invite.invites WHERE token = ? AND status = 'pending' AND expires_at > NOW()}, $token,
    )->hash;
    return $c->render(json => { error => 'this invite is no longer valid' }, status => 410) unless $pending;

    my $username = lc(($c->req->json // {})->{username} // '');
    $username =~ s/^\s+|\s+$//g;
    return $c->render(json => { available => \0, invalid => \1, error => 'Please enter a username.' })
        unless length $username;

    return $c->render(json => _username_availability_via_api($c, $username, _account_domain($c)));
}

# POST /invite/:token/accept {username, password, password_confirm, recovery_email?}
# public, unauthenticated. As of 2026-09-27 this no longer creates the
# account AS the invite's recipient_email -- the invitee CHOOSES a
# username, and the account login becomes <username>@<account_domain>
# (the fleet's own mail domain). recipient_email becomes the contact
# address + default recovery address. Calls homelab-api's own
# /api/v1/auth/register (which does the real api.users INSERT/Argon2id
# hash AND, as consume's caller, the atomic pending->accepted flip).
sub accept ($c) {
    my $token = $c->stash('token');
    my $ip = $c->tx->remote_address // 'unknown';
    if (_rate_limited($c, $ip)) {
        return $c->render(json => { error => 'too many attempts, try again later' }, status => 429);
    }

    my $row = $c->app->pg->db->query(
        q{SELECT * FROM invite.invites WHERE token = ? AND status = 'pending' AND expires_at > NOW()}, $token,
    )->hash;
    return $c->render(json => { error => 'this invite is no longer valid' }, status => 410) unless $row;

    # Recipient-DOMAIN restriction (moved here from homelab-api's
    # _register, 2026-09-27): an invite whose CONTACT address is on a
    # fleet-managed mail domain may not be accepted. Checked FIRST (right
    # after the invite is confirmed pending, before any field
    # validation), because it's a property of the invite itself,
    # independent of what the browser submitted -- a managed-recipient
    # invite is refused whatever the payload. Checked on the invite's
    # recipient_email, NOT the username being created (that IS a fleet
    # address by design). show() already rejects such an invite up front;
    # this is the actual enforcement boundary, since a direct POST here
    # skips show().
    my $domain_error = _recipient_domain_error($c, $row->{recipient_email});
    return $c->render(json => { error => $domain_error }, status => 403) if $domain_error;

    my $body = $c->req->json // {};
    my $username = lc($body->{username} // '');
    $username =~ s/^\s+|\s+$//g;
    my $password         = $body->{password};
    my $password_confirm = $body->{password_confirm};
    my $recovery         = $body->{recovery_email} // '';
    $recovery =~ s/^\s+|\s+$//g;

    return $c->render(json => { error => 'a username is required' }, status => 400) unless length $username;
    return $c->render(json => { error => 'password is required' }, status => 400) unless $password;
    return $c->render(json => { error => 'password must be at least 8 characters' }, status => 400)
        if length($password) < 8;
    return $c->render(json => { error => 'the two passwords do not match' }, status => 400)
        if defined $password_confirm && $password ne $password_confirm;

    my $domain = _account_domain($c);
    my $account_email = "$username\@$domain";

    # client_ip + a system_agent credential lets _register attribute its
    # rate-limit counter to the REAL browser, not this host (see App.pm's
    # _register comment). Degrades to this host's own IP if absent.
    my $headers = {};
    my $agent_token = eval { system_agent_token() };
    $headers = { Authorization => "Bearer $agent_token" } if $agent_token;

    my $reg = { email => $account_email, password => $password, invite_token => $token, client_ip => $ip };
    $reg->{recovery_email} = $recovery if length $recovery;

    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 15);
    my $tx = $ua->post($c->app->api_base . '/api/v1/auth/register', $headers, json => $reg);
    if (my $err = $tx->error) {
        my $api_error = eval { $tx->res->json->{error} } // $err->{message} // 'registration failed';
        # A taken username comes back as 409 'email already registered'.
        # Surface it NOT as a dead end but as fresh suggestions, so the
        # user just picks another and retries -- the invite token is NOT
        # burned (register's existing-email check runs BEFORE consume).
        if (($err->{code} // 0) == 409) {
            return $c->render(json => {
                error       => 'That username is already taken.',
                suggestions => _username_suggestions_via_api($c, $username, $domain),
            }, status => 409);
        }
        return $c->render(json => { error => $api_error }, status => $err->{code} // 502);
    }

    # Welcome email to the invite's own contact address, naming the new
    # login. Best-effort (the account already exists); failure is logged.
    my $mcfg = $c->app->mailer_config;
    eval {
        send_mail(
            smtp_host => $mcfg->{smtp_host}, smtp_port => $mcfg->{smtp_port},
            from_email => $mcfg->{email}, from_password => $mcfg->{smtp_password},
            to => $row->{recipient_email}, subject => 'Your account is ready',
            body => "Your account has been created.\n\nYour login is: $account_email\n\n"
                  . "You can now log in.",
        );
    };
    $c->app->log->warn("homelab-invite: welcome email to $row->{recipient_email} failed: $@") if $@;

    return $c->render(json => { ok => \1, email => $account_email });
}

# --- helpers for the account-creation redesign (2026-09-27) ----------

# The fleet mail domain new logins are created under. Explicit config
# wins; otherwise derived from the mailer identity's own domain (e.g.
# invites@test.mailmasker.org -> test.mailmasker.org), which is always
# a real fleet domain since that mailbox has to exist on it.
sub _account_domain ($c) {
    my $d = $c->app->invite_config->{account_domain};
    return $d if defined $d && length $d;
    my ($from_mailer) = ($c->app->mailer_config->{email} // '') =~ /\@(.+)$/;
    return $from_mailer // 'localhost';
}

# Server-to-server call to a system_agent-gated homelab-* endpoint,
# presenting this host's homelab-agent credential. Same fresh-token-
# retry-on-transport-error-or-403 pattern homelab-api's own
# _consume_invite documents (homelab-agent rotates the token each
# heartbeat; the callee verifies via introspect -- a real race). Returns
# the decoded JSON body on any real HTTP response (so a 4xx body's own
# fields stay usable), or undef on transport failure / missing credential.
sub _api_system_agent_call ($c, $method, $url, $json = undef) {
    my $ua = Mojo::UserAgent->new(connect_timeout => 5, request_timeout => 10);
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

sub _username_availability_via_api ($c, $username, $domain) {
    my $res = _api_system_agent_call($c, 'POST',
        $c->app->api_base . '/api/v1/auth/username-availability',
        { local_part => $username, domain => $domain });
    return $res // { available => \0, error => 'Unable to check that username right now. Please try again.' };
}

sub _username_suggestions_via_api ($c, $username, $domain) {
    return _username_availability_via_api($c, $username, $domain)->{suggestions} // [];
}

# undef = allowed; a user-facing string = rejected/unavailable. Checks
# the invite's own recipient (contact) domain against
# homelab-domain-admin's system_agent-gated mail-managed lookup. Fails
# CLOSED: an unreachable domain-admin returns a distinct "can't verify"
# message rather than silently allowing (blocking fleet-managed
# recipients is the whole point). This is what homelab-api's _register
# used to do on the registration email; it moved here 2026-09-27 to
# operate on recipient_email instead (the registration email is now a
# deliberately-fleet-domain chosen login).
sub _recipient_domain_error ($c, $email) {
    my ($domain) = ($email // '') =~ /\@(.+)$/;
    return undef unless $domain;
    $domain = lc($domain);

    my $da = lookup('homelab-domain-admin', api_base => $c->app->api_base);
    return 'Unable to verify this invite right now. Please try again shortly.'
        unless $da && $da->{host} && $da->{port};

    my $res = _api_system_agent_call($c, 'GET',
        "http://$da->{host}:$da->{port}/internal/v1/domains/mail-managed/$domain");
    return 'Unable to verify this invite right now. Please try again shortly.' unless $res;

    if ($res->{managed}) {
        return "Invites cannot be accepted for \@$domain addresses -- that domain is managed by "
             . "this mail system. If you already have an account, log in directly instead.";
    }
    return undef;
}

# 20 failed/garbage lookups per IP per hour -- deliberately looser than
# api.login_attempts' 10/15min (see README.md's "Anti-abuse" section
# for why: the real defense here is token entropy, not the rate limit,
# which only needs to blunt automated scanning noise).
sub _rate_limited ($c, $ip) {
    my $count = $c->app->pg->db->query(
        q{SELECT COUNT(*) AS n FROM invite.verification_attempts
          WHERE ip = ? AND outcome != 'success' AND attempted_at > NOW() - INTERVAL '1 hour'}, $ip,
    )->hash->{n};
    return $count >= 20;
}

sub _log_attempt ($c, $ip, $token, $outcome) {
    $c->app->pg->db->query(
        'INSERT INTO invite.verification_attempts (ip, token, outcome) VALUES (?, ?, ?)', $ip, $token, $outcome,
    );
}

sub _page ($title, $body) {
    my $t = xml_escape($title);
    my $b = xml_escape($body);
    return qq{<!DOCTYPE html><html><head><meta charset="utf-8"><title>$t</title></head>
<body style="font-family:sans-serif;max-width:32em;margin:4em auto;padding:0 1em">
<h1>$t</h1><p>$b</p></body></html>};
}

1;
