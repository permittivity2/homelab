package Homelab::DomainAdmin::App::Controller::Dkim;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# DKIM key rotation -- see ../../../../README.md's "DKIM" section for
# the full state-machine design. Private key material never touches
# this controller's database calls at all (only selector/state/
# public_key/timestamps do) -- opendkim-genkey writes the private key
# straight to disk, and this code only ever shells out to read/move/
# delete it, never reads its contents into a Perl variable.

my $KEYS_DIR      = '/etc/opendkim/keys';
my $KEYTABLE      = '/etc/opendkim/KeyTable';
my $SIGNINGTABLE  = '/etc/opendkim/SigningTable';

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
# 'active' selector across every domain, then reloads opendkim.
# Deliberately a full rebuild, not an incremental edit -- OpenDKIM only
# ever consults these two files when SIGNING outbound mail, never when
# verifying an inbound signature (that's a pure DNS TXT lookup), so a
# 'pending'/'retiring' selector correctly has no entry here at all even
# though its key file and TXT record both still exist. A full rebuild
# also means a partially-failed previous write can never leave a stale
# entry behind.
sub _rebuild_opendkim_tables ($c) {
    my $active = $c->app->pg->db->query(
        q{SELECT d.domain_name, s.selector FROM domainadmin.dkim_selectors s
          JOIN domainadmin.domains d ON d.id = s.domain_id
          WHERE s.state = 'active' ORDER BY d.domain_name},
    )->hashes->to_array;

    my ($keytable, $signingtable) = ('', '');
    for my $row (@$active) {
        my ($domain, $selector) = @{$row}{qw(domain_name selector)};
        my $name = _dkim_dns_name($domain, $selector);
        $keytable     .= "$name $domain:$selector:" . _key_dir($domain) . "/$selector.private\n";
        $signingtable .= "$domain $name\n";
    }

    for my $spec ([$KEYTABLE, $keytable], [$SIGNINGTABLE, $signingtable]) {
        my ($path, $content) = @$spec;
        open(my $fh, '>', $path) or die "cannot write $path: $!\n";
        print $fh $content;
        close($fh);
    }

    # Reload (not restart) -- OpenDKIM supports SIGHUP-based reload for
    # exactly this "the tables changed, nothing else did" case; cheaper
    # and less disruptive than a full restart for every rotation event.
    system('/usr/bin/sudo', '/usr/bin/systemctl', 'reload', 'opendkim');
    $c->app->log->warn('opendkim reload may have failed (exit code ' . ($? >> 8) . ')') if $? != 0;
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

    my $selector = _next_selector($c, $domain_row->{id});
    my $key_dir  = _key_dir($domain);
    system('mkdir', '-p', $key_dir);

    system('opendkim-genkey', '-D', $key_dir, '-d', $domain, '-s', $selector, '-b', 2048);
    if ($? != 0) {
        return $c->render(json => { error => 'opendkim-genkey failed (is opendkim-tools installed? is /etc/opendkim/keys writable by the homelab user?)' }, status => 502);
    }
    my $private_path = "$key_dir/$selector.private";

    # opendkim-genkey's own default mode (0600, owned by the invoking
    # process's user -- `homelab` here) is not group-readable by the
    # opendkim daemon user on its own; group membership on the CREATING
    # process doesn't retroactively help the DAEMON read a file whose
    # group is still `homelab`. Same uid/gid-mismatch class of bug that
    # already bit homelab-dovecot's vmail uid and the PgBouncer
    # userlist.txt ownership incident -- fixed explicitly here rather
    # than assumed to "just work" (see README.md).
    system('chgrp', 'opendkim', $private_path);
    system('chmod', '640', $private_path);

    my $public_key = eval { _public_key_b64($private_path) };
    if ($@) {
        return $c->render(json => { error => "key generated but public key extraction failed: $@" }, status => 502);
    }
    my $txt_value = "v=DKIM1; h=sha256; k=rsa; p=$public_key";

    my $dns_name = _dkim_dns_name($domain, $selector);
    eval { $c->app->powerdns->upsert_rrset($domain, $dns_name, 'TXT', 3600, [$txt_value]) };
    if ($@) {
        return $c->render(json => { error => "key generated but publishing its DNS TXT record failed: $@" }, status => 502);
    }
    # A brand-new DNS name -- needs the same restart-debounce as any
    # other new record (see README.md's PowerDNS gotcha).
    $c->mark_pending_restart("new DKIM selector: $dns_name");

    my $row = $c->app->pg->db->query(
        q{INSERT INTO domainadmin.dkim_selectors (domain_id, selector, state, public_key, key_bits, created_by)
          VALUES (?, ?, 'pending', ?, 2048, ?) RETURNING *},
        $domain_row->{id}, $selector, $public_key, $email,
    )->hash;
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

    eval { _rebuild_opendkim_tables($c) };
    $c->app->log->warn("opendkim table rebuild after activate failed: $@") if $@;

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
        unlink "$KEYS_DIR/$domain/$selector.private", "$KEYS_DIR/$domain/$selector.txt";
    };
    $c->app->log->warn("cleanup during dkim cancel failed (continuing): $@") if $@;

    $c->app->pg->db->query('DELETE FROM domainadmin.dkim_selectors WHERE id = ?', $row->{id});
    return $c->render(json => { ok => \1 });
}

# Shared by the explicit break-glass retire() above and the automatic
# timer in App.pm -- removes the DNS TXT record, deletes the on-disk
# key files, marks the row 'retired', and rebuilds the KeyTable/
# SigningTable (only matters if the selector being retired was still
# 'active', e.g. a break-glass call on a compromised active key). $by
# is undef for the automatic timer path (no human caller).
sub _do_retire ($c, $domain, $row, $by = undef) {
    $c->app->powerdns->delete_rrset($domain, _dkim_dns_name($domain, $row->{selector}), 'TXT');
    # Deletion is treated the same as any other DNS write for the
    # restart-debounce gotcha (see README.md) -- conservative until
    # proven the delete case doesn't also need it.
    $c->mark_pending_restart("retired DKIM selector: " . _dkim_dns_name($domain, $row->{selector}));
    unlink "$KEYS_DIR/$domain/$row->{selector}.private", "$KEYS_DIR/$domain/$row->{selector}.txt";

    $c->app->pg->db->query(
        q{UPDATE domainadmin.dkim_selectors SET state = 'retired', retired_at = NOW(), retired_by = ?, next_action_at = NULL WHERE id = ?},
        $by, $row->{id},
    );
    _rebuild_opendkim_tables($c) if $row->{state} eq 'active';
    return 1;
}

1;
