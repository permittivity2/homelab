package Homelab::Common::SetupToken;
use Mojo::Base -strict, -signatures;
use Crypt::Mac::HMAC qw(hmac);
use Mojo::Util qw(b64_encode b64_decode);
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(issue_setup_token verify_setup_token);

# Short, self-contained, expiring capability tokens -- the thing that
# makes "scan this QR code with your phone" work.
#
# THE PROBLEM. Device setup is inherently cross-device: the page is open
# on a laptop, and the mailbox has to land on a phone. The phone is not
# signed in, has no session cookie, and is not going to be. So the URL in
# the QR code has to carry its own authority.
#
# WHY NOT A DATABASE ROW. The two services that issue these have very
# different footing: homelab-invite has a schema, homelab-accountmanage
# deliberately has no database at all (it is a thin BFF and we are not
# giving it one for this). A stateless token works identically in both,
# needs no migration, no cleanup job for expired rows, and no replication
# concern.
#
# WHAT A TOKEN IS WORTH. It names a mailbox. That is all. Presenting one
# gets you a .mobileconfig containing an email address and two public
# hostnames -- it is NOT a login, it carries no password (see
# Homelab::Common::AppleProfile on why the profile has none), and it
# cannot read mail. The expiry exists to limit how long a leaked QR
# photograph keeps disclosing an address, not to protect a credential.
#
# EACH ISSUER USES ITS OWN SECRET. There is no fleet-wide setup secret to
# distribute or rotate: a token minted by homelab-invite is meaningless to
# homelab-accountmanage and vice versa, which is fine because each only
# ever verifies what it issued. `purpose` adds a second axis of the same
# separation, so a token minted for one feature cannot be replayed into
# another that happens to share a secret.

my $V = 'v1';

sub _b64u ($bytes) {
    my $s = b64_encode($bytes, '');
    $s =~ tr{+/}{-_};
    $s =~ s/=+$//;
    return $s;
}

sub _unb64u ($s) {
    return undef unless defined $s;
    # Reject anything outside the alphabet rather than letting b64_decode
    # quietly skip stray characters -- a decoder that ignores junk turns
    # "malformed" into "valid but different", which is how signature
    # checks get bypassed.
    return undef if $s =~ m{[^A-Za-z0-9_-]};
    $s =~ tr{-_}{+/};
    $s .= '=' x ((4 - length($s) % 4) % 4);
    return b64_decode($s);
}

sub _sig ($secret, $purpose, $subject, $exp) {
    # Length-prefixed fields, not a plain join on '|'. With a bare
    # separator, ("a|b", "c") and ("a", "b|c") produce the same signing
    # string -- and `subject` here is an email address, which is
    # attacker-influenceable at signup. Prefixing each field with its own
    # length makes the encoding unambiguous.
    my $msg = join '', map { length($_) . ':' . $_ }
        ($V, $purpose, $subject, $exp);
    return hmac('SHA256', $secret, $msg);
}

# Constant-time compare. These are signatures over data an attacker may
# choose; a short-circuiting `eq` leaks how many leading bytes matched.
sub _eq_ct ($a, $b) {
    return 0 unless defined $a && defined $b;
    return 0 unless length($a) == length($b);
    my $diff = 0;
    $diff |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $diff == 0 ? 1 : 0;
}

# issue_setup_token(secret => ..., purpose => ..., subject => ..., ttl => seconds)
sub issue_setup_token (%opts) {
    my $secret  = $opts{secret}  // die "issue_setup_token: secret is required\n";
    my $purpose = $opts{purpose} // die "issue_setup_token: purpose is required\n";
    my $subject = $opts{subject} // die "issue_setup_token: subject is required\n";
    die "issue_setup_token: secret is empty\n"  unless length $secret;
    die "issue_setup_token: subject is empty\n" unless length $subject;
    my $ttl = $opts{ttl} // 3600;
    my $exp = ($opts{now} // time) + $ttl;

    return join '.', $V, _b64u($subject), $exp, _b64u(_sig($secret, $purpose, $subject, $exp));
}

# verify_setup_token(secret => ..., purpose => ..., token => ...)
#   -> subject on success, undef on anything else.
# Callers get no detail about WHY a token failed; there is nothing useful
# a legitimate user could do with "expired" vs "bad signature" that
# "ask for a fresh link" does not already cover.
sub verify_setup_token (%opts) {
    my $secret  = $opts{secret}  // return undef;
    my $purpose = $opts{purpose} // return undef;
    my $token   = $opts{token};
    return undef unless defined $token && length $token && length $secret;

    my @parts = split /\./, $token, -1;
    return undef unless @parts == 4;
    my ($ver, $sub_b64, $exp, $sig_b64) = @parts;
    return undef unless $ver eq $V;
    return undef unless $exp =~ /^[0-9]{1,12}$/;

    my $subject = _unb64u($sub_b64);
    my $sig     = _unb64u($sig_b64);
    return undef unless defined $subject && length $subject && defined $sig;

    # Signature BEFORE expiry: checking expiry first would answer "was
    # this ever a real token?" for a forged one, and costs nothing to
    # order correctly.
    return undef unless _eq_ct($sig, _sig($secret, $purpose, $subject, $exp));
    return undef if ($opts{now} // time) >= $exp;

    return $subject;
}

1;

__END__

=head1 NAME

Homelab::Common::SetupToken - stateless, expiring, single-purpose capability tokens

=head1 SYNOPSIS

    use Homelab::Common::SetupToken qw(issue_setup_token verify_setup_token);

    my $t = issue_setup_token(secret => $s, purpose => 'device-setup',
                              subject => 'user@example.org', ttl => 600);
    my $email = verify_setup_token(secret => $s, purpose => 'device-setup', token => $t);

=head1 DESCRIPTION

An HMAC-SHA256 token naming a subject and an expiry, used to let a URL
carry its own authority across a device boundary (a QR code scanned by a
phone that is not signed in). It is not a login and grants nothing beyond
the one feature its C<purpose> names.

=cut
