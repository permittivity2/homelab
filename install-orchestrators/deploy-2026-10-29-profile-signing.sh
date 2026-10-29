#!/bin/bash
# Roll out post-cutover item 34 (Apple-profile signing) + the myaccount
# "resend the welcome email" action + the clickable setup link.
#
# Everything here is already built, published to the apt repo, committed
# and pushed. This script only installs it. Safe to re-run: every step is
# idempotent.
#
#   homelab-common          0.1.34   fleet-wide (purely additive modules)
#   homelab-cert-server     0.1.4    prod-homelab46 only (the new signer)
#   homelab-invite          0.1.15   prod-homelab30/31/32
#   homelab-accountmanage   0.1.40   prod-homelab27/28/29
#
# Nothing here touches the database, the certificate store, or any
# existing unit's configuration. The one config CHANGE it makes is
# copying homelab-invite's existing mailer identity into
# homelab-accountmanage's config, which is what lets the resend action
# send at all.
set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
ok()   { echo "  ${GREEN}ok${OFF}   $*"; }
bad()  { echo "  ${RED}FAIL${OFF} $*"; }
step() { echo; echo "=== $* ==="; }

ip_for() { echo "10.20.2.$((144 + $1))"; }

up() {   # up <node-number> <package>
    local ip; ip=$(ip_for "$1"); local pkg="$2"
    if ! timeout 6 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null; then
        echo "  ${DIM}skip${OFF} $(printf 'prod-homelab%02d' "$1") ($ip) not answering on :22"
        return 0
    fi
    if ! ssh -o ConnectTimeout=6 -o BatchMode=yes "$ip" "dpkg -l $pkg 2>/dev/null | grep -q '^ii'"; then
        echo "  ${DIM}skip${OFF} $(printf 'prod-homelab%02d' "$1") does not have $pkg"
        return 0
    fi
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$ip" \
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade $pkg" \
        >/dev/null 2>&1
    local v; v=$(ssh -o ConnectTimeout=6 "$ip" "dpkg-query -W -f='\${Version}' $pkg" 2>/dev/null)
    echo "  $(printf 'prod-homelab%02d' "$1") $pkg $v"
}

# ---------------------------------------------------------------- common
step "homelab-common 0.1.34 -- fleet-wide"
echo "Two new modules (ProfileSigner, WelcomeMail) and one moved into place."
echo "File replacement only; nothing is restarted, because nothing that is"
echo "already running needs them to keep working."
for n in $(seq 0 69); do up "$n" homelab-common; done

# ----------------------------------------------------------- cert-server
step "homelab-cert-server 0.1.4 -- prod-homelab46 (the issuer)"
up 46 homelab-cert-server
echo
echo "The postinst creates the homelab-certsign user, writes"
echo "/etc/homelab/cert-server/cert-sign.yml from the shipped example,"
echo "materializes the signable lineages and starts homelab-cert-sign."
ssh 10.20.2.190 'sudo systemctl is-active homelab-cert-sign.service' \
    && ok "homelab-cert-sign is active" || bad "homelab-cert-sign is not active"
ssh 10.20.2.190 'sudo /usr/bin/homelab-cert-sign-materialize'
echo
echo "Health (503 here means nothing is signable, which clients handle by"
echo "serving unsigned profiles):"
ssh 10.20.2.190 'curl -s -o /dev/null -w "  /health -> %{http_code}\n" http://127.0.0.1:2516/health'

# ---------------------------------------------------------------- invite
step "homelab-invite 0.1.15 -- prod-homelab30/31/32"
for n in 30 31 32; do up "$n" homelab-invite; done
for n in 30 31 32; do
    ssh "$(ip_for "$n")" 'systemctl is-active --quiet homelab-invite' \
        && ok "$(printf 'prod-homelab%02d' "$n") homelab-invite active" \
        || bad "$(printf 'prod-homelab%02d' "$n") homelab-invite NOT active"
done

# --------------------------------------------------------- accountmanage
step "homelab-accountmanage 0.1.40 -- prod-homelab27/28/29"
for n in 27 28 29; do up "$n" homelab-accountmanage; done

step "mailer identity for the resend action"
# Read from the live invite config rather than written down anywhere: the
# resent message IS the original message, so it should come from the same
# mailbox, and the password should not land in a scratchpad file.
MAILER=$(ssh 10.20.2.174 'sudo sed -n "/^mailer:/,/^[a-z#]/p" /etc/homelab/invite/config.yml | grep -E "^(mailer:| )"')
if [ -z "$MAILER" ]; then
    bad "could not read the mailer block from prod-homelab30 -- fill in"
    bad "accountmanage's mailer: block by hand (see its config comments)"
else
    for n in 27 28 29; do
        ip=$(ip_for "$n"); name=$(printf 'prod-homelab%02d' "$n")
        if ssh "$ip" 'sudo grep -q "^mailer:" /etc/homelab/accountmanage/config.yml'; then
            ok "$name already has a mailer: block"
            continue
        fi
        # Drop the commented stub the postinst appended, then append the
        # real thing. Perl, not sed: the stub is a multi-line block.
        # Leading blank line on purpose: a config whose last line has no
        # trailing newline would otherwise get the block glued onto it.
        printf '\n# Mailer identity, copied from homelab-invite on prod-homelab30.\n# The resent message IS the original message, so it comes from the\n# same mailbox.\n%s\n' "$MAILER" | ssh "$ip" '
            sudo perl -0777 -i -pe "s/^#mailer:\n(?:#.*\n)*//m" /etc/homelab/accountmanage/config.yml
            sudo tee -a /etc/homelab/accountmanage/config.yml >/dev/null
            sudo systemctl restart homelab-accountmanage
        '
        if ssh "$ip" 'sudo grep -q "^mailer:" /etc/homelab/accountmanage/config.yml'; then
            ok "$name mailer: block installed, service restarted"
        else
            bad "$name mailer: block did NOT install"
        fi
    done
fi

for n in 27 28 29; do
    ssh "$(ip_for "$n")" 'systemctl is-active --quiet homelab-accountmanage' \
        && ok "$(printf 'prod-homelab%02d' "$n") homelab-accountmanage active" \
        || bad "$(printf 'prod-homelab%02d' "$n") homelab-accountmanage NOT active"
done

# ------------------------------------------------------------------ done
step "versions, as deployed"
# \${Version} escaped: the command is inside a double-quoted bash string,
# so an unescaped ${Version} is expanded LOCALLY to nothing and dpkg-query
# prints an empty line. (It did, the first time this ran.)
ver() { ssh -o ConnectTimeout=6 "$1" "dpkg-query -W -f='\${Version}' $2" 2>/dev/null; }
for n in 30 31 32; do echo "  $(printf 'prod-homelab%02d' "$n") invite        $(ver "$(ip_for "$n")" homelab-invite)"; done
for n in 27 28 29; do echo "  $(printf 'prod-homelab%02d' "$n") accountmanage $(ver "$(ip_for "$n")" homelab-accountmanage)"; done
echo "  prod-homelab46 cert-server    $(ver 10.20.2.190 homelab-cert-server)"

echo
echo "Next: tap the setup link on an iPhone and look at the install screen."
echo "Green \"Verified\" means Let's Encrypt's serverAuth-only certificate is"
echo "enough. Still red means iOS wants an emailProtection EKU -- in which"
echo "case drop an S/MIME certificate on prod-homelab46 and name it in"
echo "cert-sign.yml's lineages: (the second, explicit-paths form). No code"
echo "change either way; see cert-server/README.md."
