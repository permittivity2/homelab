package Homelab::DomainAdmin::App::Controller::Dkim;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Homelab::Common::AuditClient qw(enqueue);
use Homelab::DomainAdmin::KeyVault qw(decode_kek encrypt_private_key decrypt_private_key KEY_ENC_VERSION);
use Fcntl qw(O_WRONLY O_CREAT O_TRUNC);

# DKIM key rotation -- see ../../../../README.md's "DKIM" section for
# the full state-machine design.
#
# HA model (see migration 007 + Homelab::DomainAdmin::KeyVault): DKIM
# signing is distributed across the ct05/06/07 postfix pool so no single
# host is a signing SPOF. This splits into two planes:
#   * CONTROL PLANE (rotate/activate/retire/cancel): mutates only the
#     shared resources -- the DB state machine + private_key_encrypted,
#     and the PowerDNS TXT records. Runs on whichever host currently
#     holds the admin API (one at a time, behind HAProxy active/passive),
#     so these never race across hosts.
#   * DATA PLANE (_materialize_dkim): every signer host independently
#     reconciles its LOCAL /etc/opendkim (key files + KeyTable/
#     SigningTable) to match the DB, and reloads its own opendkim. Runs
#     on a timer on every host, and is also called inline on the active
#     host right after a control-plane op for low-latency convergence.
# The private key is thus generated once, stored envelope-encrypted in
# the DB, and materialized to each host's local disk from there -- it is
# never copied host-to-host and never crosses the network in the clear.

my $KEYS_DIR      = '/etc/opendkim/keys';
my $KEYTABLE      = '/etc/opendkim/KeyTable';
my $SIGNINGTABLE  = '/etc/opendkim/SigningTable';

sub _slurp ($path) {
    open(my $fh, '<', $path) or return undef;
    local $/;
    return scalar <$fh>;
}

# Atomically write $content to $path with the given octal $mode (and,
# for a private key, group $group), only if the content differs from
# what's already there -- so a 60s reconcile loop doesn't rewrite files
# (or trigger an opendkim reload) when nothing changed. Returns 1 if the
# content changed, 0 otherwise.
#
# Two correctness guarantees the naive open('>') version lacked:
#  * NEVER a world-readable window on a private key: the temp file is
#    created directly with the restrictive $mode (sysopen honours it; for
#    0640 there are no world bits to leak even before the explicit chmod),
#    the group is set before any content lands, and only then is it
#    rename()d into place -- atomic, so a concurrent opendkim reload or
#    a sibling worker always sees a complete old-or-new file, never a
#    half-written or zero-length key.
#  * Perms/ownership are RE-ASSERTED even when the content is unchanged,
#    so a file left with the wrong mode by an older code path (or an
#    interrupted write) is corrected rather than silently persisting.
sub _atomic_write ($path, $content, $mode, $group = undef) {
    my $set_perms = sub ($p) {
        chmod $mode, $p;
        if (defined $group) {
            my $gid = getgrnam($group);
            chown -1, $gid, $p if defined $gid;
        }
    };
    my $existing = _slurp($path);
    if (defined $existing && $existing eq $content) {
        $set_perms->($path);    # re-assert (idempotent) even on no-op
        return 0;
    }
    my $tmp = "$path.tmp.$$";
    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_TRUNC, $mode) or die "cannot write $tmp: $!\n";
    $set_perms->($tmp);         # exact mode + group before content is readable
    print $fh $content;
    close($fh) or do { unlink $tmp; die "cannot finish writing $tmp: $!\n" };
    rename($tmp, $path) or do { unlink $tmp; die "cannot rename $tmp -> $path: $!\n" };
    return 1;
}

# Resolve the configured KEK, or undef (with a single warning) if this
# host has no dkim.key_encryption_key set -- a non-signer install, or a
# signer not yet configured. Callers degrade gracefully rather than die.
sub _kek ($app) {
    my $raw = $app->config->{dkim}{key_encryption_key};
    return undef unless defined $raw && length $raw && $raw ne 'YOUR_BASE64_KEK_HERE';
    return eval { decode_kek($raw) } // do {
        $app->log->error("dkim.key_encryption_key is set but invalid: $@");
        undef;
    };
}

sub _domain_row ($c, $domain) {
    return $c->app->pg->db->query('SELECT * FROM domainadmin.domains WHERE domain_name = ?', $domain)->hash;
}

sub _retirement_days ($c) {
    return $c->app->config->{dkim}{retirement_days} // 7;
}

# selector._domainkey.<domain> -- the DNS name every DKIM verifier
# looks up, per RFC 6376.
sub _dkim_dns_name ($domain, $selector) {
    return "$selector._domainkey.$domain";
}

sub _key_dir ($domain) {
    return "$KEYS_DIR/$domain";
}

# Next unused date/version selector for this domain, e.g. "20260911a"
# then "20260911b" if a second rotation happens the same day -- see
# README.md on why this replaces production's single fixed "default"
# selector forever (that approach can't rotate safely at all).
sub _next_selector ($c, $domain_id) {
    my @today = (localtime)[5, 4, 3];
    my $date  = sprintf('%04d%02d%02d', $today[0] + 1900, $today[1] + 1, $today[2]);
    my %used  = map { $_->{selector} => 1 } @{ $c->app->pg->db->query(
        'SELECT selector FROM domainadmin.dkim_selectors WHERE domain_id = ? AND selector LIKE ?',
        $domain_id, "$date%",
    )->hashes->to_array };
    my $suffix = 'a';
    $suffix++ while $used{"$date$suffix"};
    return "$date$suffix";
}

# Rebuilds KeyTable/SigningTable from scratch from every currently-
# 'active' selector across every domain. Deliberately a full rebuild,
# not an incremental edit -- OpenDKIM only ever consults these two files
# when SIGNING outbound mail, never when verifying an inbound signature
# (that's a pure DNS TXT lookup), so a 'pending'/'retiring' selector
# correctly has no entry here at all even though its key file and TXT
# record both still exist. A full rebuild also means a partially-failed
# previous write can never leave a stale entry behind. Returns 1 if
# either table's content actually changed (so the caller can decide
# whether an opendkim reload is warranted), 0 otherwise. Does NOT reload
# opendkim itself -- _materialize_dkim owns the single reload.
sub _rebuild_opendkim_tables ($app) {
    my $active = $app->pg->db->query(
        q{SELECT d.domain_name, s.selector FROM domainadmin.dkim_selectors s
          JOIN domainadmin.domains d ON d.id = s.domain_id
          WHERE s.state = 'active' ORDER BY d.domain_name},
    )->hashes->to_array;

    my ($keytable, $signingtable) = ('', '');
    for my $row (@$active) {
        my ($domain, $selector) = @{$row}{qw(domain_name selector)};
        my $path = _key_dir($domain) . "/$selector.private";
        # CRITICAL for HA: only advertise a selector this host can
        # actually sign with. If the local key file isn't present yet
        # (KEK missing on this host, or not-yet-materialized during
        # rollout), listing it in KeyTable would make opendkim reject the
        # WHOLE table on reload -- the host would then sign NOTHING for
        # ANY domain. Omitting it instead just means this host doesn't
        # sign for that one selector until its key materializes.
        unless (-e $path) {
            $app->log->warn("active DKIM selector $domain/$selector has no local key file yet -- omitting from this host's signing tables until it materializes");
            next;
        }
        my $name = _dkim_dns_name($domain, $selector);
        $keytable     .= "$name $domain:$selector:$path\n";
        $signingtable .= "$domain $name\n";
    }

    my $changed = 0;
    $changed += _atomic_write($KEYTABLE, $keytable, 0644);
    $changed += _atomic_write($SIGNINGTABLE, $signingtable, 0644);
    return $changed ? 1 : 0;
}

# DATA PLANE. Reconciles THIS host's local /etc/opendkim to match the
# DB, then reloads opendkim iff something changed. Idempotent and safe to
# run concurrently on every signer host (each only touches its own local
# disk). This is what makes a rebooted or brand-new signer self-heal to
# the current fleet-wide DKIM state with no host-to-host copying.
#
#   1. For every live (pending/active/retiring) selector: ensure its
#      decrypted private key exists locally. If the DB row has no
#      ciphertext yet but this host HAS the key on disk (the pre-HA
#      single-signer case, ct05), adopt it -- encrypt and store it in the
#      DB so the rest of the pool can materialize it (one-time backfill,
#      done automatically by the host that holds the key).
#   2. Delete any local *.private key file that no longer corresponds to
#      a live selector (retired/cancelled) -- cleanup that used to live
#      in _do_retire but must now happen on every host, not just the one
#      that processed the state change.
#   3. Rebuild KeyTable/SigningTable from active selectors.
#   4. Reload opendkim exactly once, only if anything changed.
sub _materialize_dkim ($app) {
    my $log = $app->log;
    my $kek = _kek($app);
    my $db  = $app->pg->db;

    my $rows = $db->query(
        q{SELECT s.id, s.selector, s.state, s.private_key_encrypted, d.domain_name
          FROM domainadmin.dkim_selectors s
          JOIN domainadmin.domains d ON d.id = s.domain_id
          WHERE s.state IN ('pending','active','retiring')},
    )->hashes->to_array;

    my $changed = 0;
    my %want;    # absolute .private paths that SHOULD exist on this host
    for my $r (@$rows) {
        my ($id, $selector, $enc, $domain) = @{$r}{qw(id selector private_key_encrypted domain_name)};
        my $dir  = _key_dir($domain);
        my $path = "$dir/$selector.private";
        $want{$path} = 1;

        if (!defined $enc) {
            # No ciphertext in the DB yet.
            my $on_disk = _slurp($path);
            if (defined $on_disk && $kek) {
                # Adopt this host's on-disk key into the DB (backfill).
                # Guarded on IS NULL so concurrent workers/hosts don't
                # each re-encrypt (fresh IV) and overwrite -- first wins,
                # the rest no-op.
                my $blob = eval { encrypt_private_key($kek, $domain, $selector, $on_disk) };
                if ($blob) {
                    my $done = $db->query('UPDATE domainadmin.dkim_selectors SET private_key_encrypted = ?, key_enc_version = ? WHERE id = ? AND private_key_encrypted IS NULL RETURNING id',
                        $blob, KEY_ENC_VERSION, $id)->hash;
                    $log->info("adopted on-disk DKIM key into DB for $domain/$selector") if $done;
                } else {
                    $log->error("failed to encrypt on-disk DKIM key for $domain/$selector: $@");
                }
            } elsif (!defined $on_disk) {
                $log->warn("DKIM selector $domain/$selector has no key in the DB and none on disk"
                    . ($kek ? '' : ' (dkim.key_encryption_key not configured on this host)'));
            }
            next;
        }

        # Ciphertext present -- materialize it locally if missing/stale.
        next unless $kek;    # can't decrypt without the KEK; _kek() logged why
        my $pt = eval { decrypt_private_key($kek, $domain, $selector, $enc) };
        if (!defined $pt) { $log->error("cannot decrypt DKIM key $domain/$selector: $@"); next; }

        system('mkdir', '-p', $dir);
        # Atomic, mode 0640, group opendkim from creation (the daemon
        # reads keys via group opendkim, not as the writing user).
        my $wrote = eval { _atomic_write($path, $pt, 0640, 'opendkim') };
        if ($@) { $log->error("$@"); next; }
        if ($wrote) {
            $changed++;
            $log->info("materialized DKIM key $domain/$selector from DB");
        }
    }

    # Cleanup: remove local key files (and their .txt companions) for
    # selectors no longer live (retired/cancelled/relocated). This has to
    # happen on EVERY host, not just the one that ran the control-plane
    # op, so it lives here rather than in _do_retire/cancel.
    #
    # Two guards:
    #  * EMPTY live-set => skip entirely. Zero live selectors is far more
    #    likely a transient/failed DB read than a real "everything
    #    retired"; blindly unlinking every key would break signing
    #    fleet-wide. Stale files are inert (not in the rebuilt tables), so
    #    leaving them is the safe failure mode.
    #  * GRACE WINDOW => never sweep a key file younger than 5 minutes. A
    #    rotate on another worker/host writes the key file slightly before
    #    its DB row is visible to THIS materialize's snapshot; without the
    #    grace window this pass could unlink that brand-new key before it
    #    was ever persisted (permanent loss when no KEK is configured).
    if (@$rows) {
        my $now = time;
        for my $kf (glob "$KEYS_DIR/*/*.private") {
            next if $want{$kf};
            my $mtime = (stat $kf)[9] // $now;
            next if $now - $mtime < 300;    # grace: don't race an in-flight rotate
            if (unlink $kf) { $changed++; $log->info("removed stale DKIM key file $kf"); }
            (my $txt = $kf) =~ s/\.private$/.txt/;    # genkey's companion
            unlink $txt if -e $txt;
        }
    }

    # Tables + single reload.
    $changed += eval { _rebuild_opendkim_tables($app) } // 0;
    $log->error("DKIM table rebuild failed: $@") if $@;
    if ($changed) {
        system('/usr/bin/sudo', '/usr/bin/systemctl', 'reload', 'opendkim');
        $log->warn('opendkim reload may have failed (exit code ' . ($? >> 8) . ')') if $? != 0;
    }
    return;
}

# Extracts the base64 DER-encoded public key from a just-generated
# private key file via openssl directly, rather than parsing
# opendkim-genkey's own human-oriented (multi-line, BIND-zone-quoted)
# *.txt output -- fewer moving parts, and this is the same well-known
# technique used to hand-build a DKIM TXT record from any RSA key.
sub _public_key_b64 ($private_key_path) {
    my $b64 = `openssl rsa -in '$private_key_path' -pubout -outform DER 2>/dev/null | openssl base64 -A`;
    chomp $b64;
    die "could not extract public key from $private_key_path\n" unless length $b64;
    return $b64;
}

# GET /internal/v1/domains/:domain/dkim/selectors
sub list ($c) {
    $c->authenticated_email or return;
    my $domain_row = _domain_row($c, $c->stash('domain'));
    return $c->render(json => { error => 'domain not found' }, status => 404) unless $domain_row;

    my $rows = $c->app->pg->db->query(
        'SELECT id, selector, state, key_bits, created_at, activated_at, retiring_at, retire_after, retired_at
         FROM domainadmin.dkim_selectors WHERE domain_id = ? ORDER BY created_at DESC',
        $domain_row->{id},
    )->hashes->to_array;
    return $c->render(json => $rows);
}

# POST /internal/v1/domains/:domain/dkim/rotate
# Generates a brand-new key + selector, publishes its public half as a
# DNS TXT record, and stores it as 'pending' -- NOT yet signing
# anything (see README.md: pending -> active is a deliberate, separate,
# explicit call, not automatic).
sub rotate ($c) {
    my $email = $c->authenticated_email or return;
    my $domain_row = _domain_row($c, $c->stash('domain'));
    return $c->render(json => { error => 'domain not found' }, status => 404) unless $domain_row;
    my $domain = $domain_row->{domain_name};
    # Defense in depth: _public_key_b64 interpolates the key path (which
    # embeds $domain) into a shell command. Domains are validated on
    # insert, but assert a strict charset here too so a hostile domain
    # name can never reach /bin/sh.
    return $c->render(json => { error => 'invalid domain name' }, status => 400)
        unless $domain =~ /\A[A-Za-z0-9.\-]+\z/;
    my $db = $c->app->pg->db;

    # RESERVE the selector via the (domain_id, selector) unique index
    # BEFORE generating any key. Two concurrent rotates for the same
    # domain (double-submit, or a flapping gateway hitting >1 host) would
    # otherwise compute the SAME selector, run opendkim-genkey into the
    # SAME path (each clobbering the other's key), and publish conflicting
    # TXT records -- leaving the on-disk/DB key out of sync with DNS.
    # Reserving first means the loser's INSERT conflicts and it simply
    # takes the next suffix, so each rotate owns a distinct selector.
    my ($selector, $reserved_id);
    for (1 .. 8) {
        my $cand = _next_selector($c, $domain_row->{id});
        my $r = $db->query(
            q{INSERT INTO domainadmin.dkim_selectors (domain_id, selector, state, public_key, key_bits, created_by)
              VALUES (?, ?, 'pending', '', 2048, ?)
              ON CONFLICT (domain_id, selector) DO NOTHING RETURNING id},
            $domain_row->{id}, $cand, $email,
        )->hash;
        if ($r) { $selector = $cand; $reserved_id = $r->{id}; last; }
    }
    return $c->render(json => { error => 'could not allocate a free DKIM selector -- retry' }, status => 409)
        unless $reserved_id;

    my $key_dir      = _key_dir($domain);
    my $private_path = "$key_dir/$selector.private";
    # On any failure past this point, undo the reservation so a half-done
    # rotate never leaves a dangling placeholder pending row (public_key='').
    my $fail = sub ($msg, $status) {
        eval { $db->query('DELETE FROM domainadmin.dkim_selectors WHERE id = ?', $reserved_id) };
        unlink $private_path, "$key_dir/$selector.txt";
        return $c->render(json => { error => $msg }, status => $status);
    };

    system('mkdir', '-p', $key_dir);
    system('opendkim-genkey', '-D', $key_dir, '-d', $domain, '-s', $selector, '-b', 2048);
    return $fail->('opendkim-genkey failed (is opendkim-tools installed? is /etc/opendkim/keys writable by the homelab user?)', 502) if $? != 0;

    # opendkim-genkey writes 0600 owned by the invoking user (homelab);
    # the opendkim DAEMON reads via group opendkim, so make it group-
    # readable. (_materialize_dkim re-asserts this on every host too.)
    system('chgrp', 'opendkim', $private_path);
    system('chmod', '640', $private_path);

    my $public_key = eval { _public_key_b64($private_path) };
    return $fail->("key generated but public key extraction failed: $@", 502) if $@;
    my $txt_value = "v=DKIM1; h=sha256; k=rsa; p=$public_key";

    # Envelope-encrypt the private key for distribution to the whole
    # signer pool via the DB (see _materialize_dkim). Without a KEK the
    # key stays local to this host only (pre-HA behaviour) -- allowed, but
    # warn loudly since it defeats signer failover.
    my ($enc_blob, $enc_ver);
    if (my $kek = _kek($c->app)) {
        my $priv = _slurp($private_path);
        $enc_blob = eval { encrypt_private_key($kek, $domain, $selector, $priv) } if defined $priv;
        if ($enc_blob) { $enc_ver = KEY_ENC_VERSION }
        else { $c->app->log->error("could not encrypt new DKIM key for pool distribution ($domain/$selector): $@") }
    } else {
        $c->app->log->warn("new DKIM key $domain/$selector NOT distributed to the pool -- dkim.key_encryption_key is not configured on this host");
    }

    my $dns_name = _dkim_dns_name($domain, $selector);
    eval { $c->app->powerdns->upsert_rrset($domain, $dns_name, 'TXT', 3600, [$txt_value]) };
    return $fail->("key generated but publishing its DNS TXT record failed: $@", 502) if $@;
    # A brand-new DNS name -- needs the same restart-debounce as any
    # other new record (see README.md's PowerDNS gotcha).
    $c->mark_pending_restart("new DKIM selector: $dns_name");

    # Fill in the reserved row with the real key material.
    my $row = $db->query(
        q{UPDATE domainadmin.dkim_selectors
          SET public_key = ?, private_key_encrypted = ?, key_enc_version = ?
          WHERE id = ? RETURNING *},
        $public_key, $enc_blob, $enc_ver, $reserved_id,
    )->hash;
    # Distribute the (now pending) key to this host + the rest of the pool.
    eval { _materialize_dkim($c->app) };
    $c->app->log->warn("materialize after rotate failed: $@") if $@;
    enqueue(
        $c->app->pg->db, actor_email => $email, affected_user => $email, jti => $c->stash('current_jti'), action => 'dkim.rotate',
        resource_type => 'domain', resource_id => $domain, source_service => 'homelab-domain-admin',
        ip_address => $c->tx->remote_address, user_agent => $c->req->headers->user_agent,
        detail => { selector => $selector },
    );
    delete @{$row}{qw(private_key_encrypted key_enc_version)};    # never ship key material in the API response
    return $c->render(json => $row, status => 201);
}

# POST /internal/v1/domains/:domain/dkim/:selector/activate
# Starts signing outbound mail with this selector; demotes whichever
# selector was previously active (if any) to 'retiring', with a
# configurable overlap window (default 7 days) during which its TXT
# record and key file both stay fully published so mail already
# in-flight, signed with the old key, still verifies (see README.md --
# this overlap is a hard requirement, not a nicety).
sub activate ($c) {
    my $email = $c->authenticated_email or return;
    my $domain_row = _domain_row($c, $c->stash('domain'));
    return $c->render(json => { error => 'domain not found' }, status => 404) unless $domain_row;
    my $selector = $c->stash('selector');

    my $db = $c->app->pg->db;
    my $tx = $db->begin;

    my $target = $db->query(
        q{SELECT * FROM domainadmin.dkim_selectors WHERE domain_id = ? AND selector = ? FOR UPDATE},
        $domain_row->{id}, $selector,
    )->hash;
    return $c->render(json => { error => 'selector not found' }, status => 404) unless $target;
    return $c->render(json => { error => "selector is '$target->{state}', not 'pending' -- only a pending selector can be activated" }, status => 409)
        unless $target->{state} eq 'pending';

    my $retirement_days = _retirement_days($c);
    $db->query(
        q{UPDATE domainadmin.dkim_selectors
          SET state = 'retiring', retiring_at = NOW(),
              retire_after = NOW() + (? * INTERVAL '1 day'), next_action_at = NOW() + (? * INTERVAL '1 day')
          WHERE domain_id = ? AND state = 'active'},
        $retirement_days, $retirement_days, $domain_row->{id},
    );
    my $row = $db->query(
        q{UPDATE domainadmin.dkim_selectors SET state = 'active', activated_at = NOW(), activated_by = ?
          WHERE id = ? RETURNING *},
        $email, $target->{id},
    )->hash;
    $tx->commit;

    # Converge this host immediately; the timer converges the rest.
    eval { _materialize_dkim($c->app) };
    $c->app->log->warn("materialize after activate failed: $@") if $@;

    delete @{$row}{qw(private_key_encrypted key_enc_version)};    # never ship key material in the API response
    return $c->render(json => $row);
}

# POST /internal/v1/domains/:domain/dkim/:selector/retire
# Break-glass: retires a selector (active or retiring) immediately,
# skipping the overlap window -- for a suspected-compromised key, not
# the normal path (the recurring timer below handles that
# automatically once retire_after passes).
sub retire ($c) {
    my $email = $c->authenticated_email or return;
    my $domain_row = _domain_row($c, $c->stash('domain'));
    return $c->render(json => { error => 'domain not found' }, status => 404) unless $domain_row;
    my $selector = $c->stash('selector');

    my $row = $c->app->pg->db->query(
        'SELECT * FROM domainadmin.dkim_selectors WHERE domain_id = ? AND selector = ?',
        $domain_row->{id}, $selector,
    )->hash;
    return $c->render(json => { error => 'selector not found' }, status => 404) unless $row;
    return $c->render(json => { error => "selector is already '$row->{state}'" }, status => 409)
        if $row->{state} eq 'retired' || $row->{state} eq 'pending';

    my $ok = eval { _do_retire($c, $domain_row->{domain_name}, $row, $email) };
    return $c->render(json => { error => "retire failed: $@" }, status => 502) unless $ok;
    return $c->render(json => { ok => \1 });
}

# DELETE /internal/v1/domains/:domain/dkim/:selector
# Cancels an in-progress, never-activated ('pending') rotation --
# removes the TXT record and key files and deletes the row entirely
# (unlike retire, which keeps a historical 'retired' row).
sub cancel ($c) {
    $c->authenticated_email or return;
    my $domain_row = _domain_row($c, $c->stash('domain'));
    return $c->render(json => { error => 'domain not found' }, status => 404) unless $domain_row;
    my $domain = $domain_row->{domain_name};
    my $selector = $c->stash('selector');

    my $row = $c->app->pg->db->query(
        'SELECT * FROM domainadmin.dkim_selectors WHERE domain_id = ? AND selector = ?',
        $domain_row->{id}, $selector,
    )->hash;
    return $c->render(json => { error => 'selector not found' }, status => 404) unless $row;
    return $c->render(json => { error => "selector is '$row->{state}', not 'pending' -- use retire instead" }, status => 409)
        unless $row->{state} eq 'pending';

    eval {
        $c->app->powerdns->delete_rrset($domain, _dkim_dns_name($domain, $selector), 'TXT');
        unlink "$KEYS_DIR/$domain/$selector.txt";    # genkey companion; materialize handles the *.private
    };
    $c->app->log->warn("cleanup during dkim cancel failed (continuing): $@") if $@;
    # Same DNS-write debounce as _do_retire's delete (a slave, if ever
    # configured, must be NOTIFY'd of the removed TXT).
    $c->mark_pending_restart("cancelled DKIM selector: " . _dkim_dns_name($domain, $selector));

    $c->app->pg->db->query('DELETE FROM domainadmin.dkim_selectors WHERE id = ?', $row->{id});
    # Reconcile this host now (removes the cancelled *.private); the rest
    # of the pool drops their copy on their next materialize tick.
    eval { _materialize_dkim($c->app) };
    $c->app->log->warn("materialize after cancel failed: $@") if $@;
    return $c->render(json => { ok => \1 });
}

# Shared by the explicit break-glass retire() above and the automatic
# timer in App.pm -- removes the DNS TXT record, deletes the on-disk
# key files, marks the row 'retired', and rebuilds the KeyTable/
# SigningTable (only matters if the selector being retired was still
# 'active', e.g. a break-glass call on a compromised active key). $by
# is undef for the automatic timer path (no human caller).
sub _do_retire ($c, $domain, $row, $by = undef) {
    # Control-plane: drop the shared TXT record and flip DB state. The
    # local key file + table cleanup is data-plane and now happens on
    # EVERY signer host via _materialize_dkim (a .txt companion, if any,
    # is cleaned below since materialize only tracks *.private).
    $c->app->powerdns->delete_rrset($domain, _dkim_dns_name($domain, $row->{selector}), 'TXT');
    # Deletion is treated the same as any other DNS write for the
    # restart-debounce gotcha (see README.md) -- conservative until
    # proven the delete case doesn't also need it.
    $c->mark_pending_restart("retired DKIM selector: " . _dkim_dns_name($domain, $row->{selector}));

    $c->app->pg->db->query(
        q{UPDATE domainadmin.dkim_selectors SET state = 'retired', retired_at = NOW(), retired_by = ?, next_action_at = NULL
          WHERE id = ? AND state IN ('active','retiring')},
        $by, $row->{id},
    );
    unlink "$KEYS_DIR/$domain/$row->{selector}.txt";    # genkey's companion (materialize only manages *.private)
    # Reconcile THIS host now (removes the retired *.private + rebuilds
    # tables); every other signer's timer does the same on its own disk.
    eval { _materialize_dkim($c->app) };
    $c->app->log->warn("materialize after retire failed: $@") if $@;
    return 1;
}

1;
