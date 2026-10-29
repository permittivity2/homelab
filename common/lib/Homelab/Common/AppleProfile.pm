package Homelab::Common::AppleProfile;
use Mojo::Base -strict, -signatures;
use Digest::SHA qw(sha1_hex);
use Exporter 'import';

our $VERSION = '0.1.0';
our @EXPORT_OK = qw(build_mail_profile profile_filename);

# Apple .mobileconfig generation -- an iOS/macOS "configuration profile"
# that adds this fleet's IMAP/SMTP account to Mail in one tap, instead of
# asking a phone user to hand-type four hostnames, two port numbers and
# two TLS settings into Settings > Mail > Add Account > Other.
#
# WHY THIS LIVES IN common: two separate services hand the same profile
# to the same person at different moments -- homelab-invite, right after
# an account is created (and again from the "your account is ready"
# mail), and homelab-accountmanage, any time afterwards. A profile that
# differed between the two would silently create a SECOND mail account on
# the phone rather than updating the first (see the PayloadIdentifier note
# below), so the bytes have to come from one place.
#
# ------------------------------------------------------------------
# THE PROFILE DELIBERATELY CONTAINS NO PASSWORD.
# ------------------------------------------------------------------
# Apple's EmailAccount payload has both `IncomingPassword` and
# `OutgoingPassword` keys, and filling them in would make installation a
# single tap with nothing to type. We do not, for two independent
# reasons, either of which alone is decisive:
#
#   1. We cannot. Mail passwords are stored as Argon2id hashes in
#      api.users -- there is no plaintext to put in the file. The only
#      moment one exists is the instant the account is created, and
#      keeping it past that instant to serve later is precisely the thing
#      the hash exists to prevent.
#   2. We would not want to. A .mobileconfig is an unencrypted XML file
#      fetched over a URL. Anything that leaks the URL -- a mail client
#      prefetching links, a browser's history sync, a shoulder-surfed QR
#      code -- would leak a working mailbox credential. Without the
#      password the same leak discloses only an email address and two
#      public hostnames, which is what an MX lookup already tells you.
#
# The cost is that iOS prompts for the password during install.
# `OutgoingPasswordSameAsIncomingPassword` below cuts that from two
# prompts to one, which is as close to frictionless as is honest.

# Fixed namespace for the deterministic UUIDs below. Any constant string
# works; it is pinned here so the UUIDs a given account gets never change.
my $UUID_NS = 'homelab-apple-profile:v1';

# Apple identifies a profile by PayloadIdentifier and each payload inside
# it by PayloadUUID. Installing a profile whose identifier matches one
# already on the device REPLACES it; a different identifier ADDS a second
# one. So both have to be a pure function of the account -- a random UUID
# per request (the obvious implementation) would give a user who taps
# "Add to iPhone" twice two copies of the same mailbox, with duplicate
# push connections and duplicate notifications for every message.
sub _uuid_for ($seed) {
    my $h = sha1_hex("$UUID_NS|$seed");
    # Shape the digest into a syntactically valid v5 UUID: version nibble
    # 5, RFC 4122 variant bits. iOS only requires well-formed-ness, but a
    # UUID that lies about its version is the kind of thing that trips a
    # future validator for no benefit.
    my @p = (substr($h,0,8), substr($h,8,4), substr($h,12,4), substr($h,16,4), substr($h,20,12));
    $p[2] = '5' . substr($p[2], 1);
    my $v = hex(substr($p[3], 0, 1));
    $p[3] = sprintf('%x', ($v & 0x3) | 0x8) . substr($p[3], 1);
    return uc(join '-', @p);
}

# Reverse-DNS-ish identifier segment from an email address. Apple does not
# enforce any syntax here, but a bare address would put '@' and '+' into
# something every Apple document calls a reverse-DNS string -- so fold to
# the characters that convention actually uses.
sub _ident_segment ($email) {
    my $s = lc($email // '');
    $s =~ s/[^a-z0-9._-]+/-/g;
    $s =~ s/^-+|-+$//g;
    return length($s) ? $s : 'account';
}

sub _esc ($s) {
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    # Control characters are not representable in XML 1.0 at all -- not
    # even as numeric references. Drop them rather than emit a file that
    # the device rejects wholesale with no useful message.
    $s =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g;
    return $s;
}

sub _str ($k, $v)  { '    <key>' . _esc($k) . "</key>\n    <string>" . _esc($v) . "</string>\n" }
sub _int ($k, $v)  { '    <key>' . _esc($k) . "</key>\n    <integer>" . int($v) . "</integer>\n" }
sub _bool ($k, $v) { '    <key>' . _esc($k) . '</key>' . "\n    " . ($v ? '<true/>' : '<false/>') . "\n" }

# build_mail_profile(%opts) -> XML string
#
# Required: email. Everything else has a working default so a caller that
# only knows who the user is still produces an installable profile.
#   email             the mailbox, used as both address and login
#   display_name      what Mail shows as the account name
#   account_label     short service name shown on the install screen
#   organization      shown as the profile's publisher
#   imap_host/_port   default mail.<domain>:993, implicit TLS
#   smtp_host/_port   default smtp.<domain>:587, STARTTLS
#   identifier_prefix reverse-DNS prefix for PayloadIdentifier
sub build_mail_profile (%opts) {
    my $email = $opts{email} // die "build_mail_profile: email is required\n";
    die "build_mail_profile: email does not look like an address\n" unless $email =~ /\@/;

    my ($domain) = $email =~ /\@(.+)$/;
    my $imap_host = $opts{imap_host} || "mail.$domain";
    my $smtp_host = $opts{smtp_host} || "smtp.$domain";
    my $imap_port = $opts{imap_port} || 993;
    my $smtp_port = $opts{smtp_port} || 587;
    my $label     = $opts{account_label} // 'MailMasker';
    my $org       = $opts{organization}  // 'Silver Linings, LLC';
    my $display   = $opts{display_name};
    $display = $email unless defined $display && length $display;
    my $prefix    = $opts{identifier_prefix} // 'org.mailmasker.profile';

    my $seg        = _ident_segment($email);
    my $root_ident = "$prefix.$seg";
    my $acct_ident = "$root_ident.mail";

    # Port 993 is implicit TLS and 587 is STARTTLS, but Apple spells both
    # as the same `UseSSL` boolean -- iOS picks the mechanism from the
    # port. Setting it false on 587 does NOT mean "STARTTLS", it means
    # "plaintext submission", so both are true here on purpose.
    my $acct = "  <dict>\n"
        . _str('PayloadType',        'com.apple.mail.managed')
        . _int('PayloadVersion',     1)
        . _str('PayloadIdentifier',  $acct_ident)
        . _str('PayloadUUID',        _uuid_for("$email|account"))
        . _str('PayloadDisplayName', "$label mail")
        . _str('PayloadOrganization', $org)
        . _str('EmailAccountDescription', $label)
        . _str('EmailAccountName',   $display)
        . _str('EmailAccountType',   'EmailTypeIMAP')
        . _str('EmailAddress',       $email)
        . _str('IncomingMailServerHostName',       $imap_host)
        . _int('IncomingMailServerPortNumber',     $imap_port)
        . _bool('IncomingMailServerUseSSL',        1)
        . _str('IncomingMailServerAuthentication', 'EmailAuthPassword')
        . _str('IncomingMailServerUsername',       $email)
        . _str('OutgoingMailServerHostName',       $smtp_host)
        . _int('OutgoingMailServerPortNumber',     $smtp_port)
        . _bool('OutgoingMailServerUseSSL',        1)
        . _str('OutgoingMailServerAuthentication', 'EmailAuthPassword')
        . _str('OutgoingMailServerUsername',       $email)
        # One password prompt instead of two. See the header note on why
        # there is a prompt at all.
        . _bool('OutgoingPasswordSameAsIncomingPassword', 1)
        # Leave the account as unrestricted as a hand-made one: these
        # default to false anyway, but they are the keys an MDM uses to
        # make a mailbox feel broken (no moving messages, no sharing from
        # other apps), so they are pinned rather than left to a future
        # OS default.
        . _bool('PreventMove',     0)
        . _bool('PreventAppSheet', 0)
        . _bool('SMIMEEnabled',    0)
        . "  </dict>\n";

    my $desc = $opts{description}
        // "Adds the $label account $email to Mail. You will be asked for your password during setup.";

    return qq{<?xml version="1.0" encoding="UTF-8"?>\n}
        . qq{<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n}
        . qq{<plist version="1.0">\n}
        . "<dict>\n"
        . "  <key>PayloadContent</key>\n  <array>\n"
        . $acct
        . "  </array>\n"
        . _str('PayloadDisplayName',  "$label ($email)")
        . _str('PayloadDescription',  $desc)
        . _str('PayloadIdentifier',   $root_ident)
        . _str('PayloadOrganization', $org)
        . _str('PayloadType',         'Configuration')
        . _str('PayloadUUID',         _uuid_for("$email|root"))
        . _int('PayloadVersion',      1)
        # false: the user can delete the profile (and with it the mail
        # account) from Settings whenever they like. This is a consumer
        # mail service, not a managed corporate device -- a profile the
        # recipient cannot remove would be a trap, and iOS warns about it
        # at install time, which is exactly the wrong note to strike.
        . _bool('PayloadRemovalDisallowed', 0)
        . "</dict>\n</plist>\n";
}

# Content-Disposition filename. Kept here next to the generator so the
# two services cannot drift on it.
sub profile_filename ($email, $label = 'mailmasker') {
    my $seg = _ident_segment($email);
    $label = _ident_segment($label);
    return "$label-$seg.mobileconfig";
}

1;

__END__

=head1 NAME

Homelab::Common::AppleProfile - build an Apple .mobileconfig for a fleet mailbox

=head1 SYNOPSIS

    use Homelab::Common::AppleProfile qw(build_mail_profile profile_filename);

    my $xml  = build_mail_profile(email => 'someone@mailmasker.org');
    my $name = profile_filename('someone@mailmasker.org');

=head1 DESCRIPTION

Produces an iOS/macOS configuration profile that adds this fleet's IMAP
and SMTP settings to Apple Mail. The profile never contains a password --
see the comments in the source for why that is a deliberate and
non-negotiable property rather than an omission.

=cut
