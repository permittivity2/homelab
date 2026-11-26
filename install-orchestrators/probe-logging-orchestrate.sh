#!/bin/bash
# ============================================================================
# Post-cutover #105 -- the health checks out of the mail logs, and a ceiling on
# every log. RUN ON THE ADMIN WORKSTATION.
#
#   ./probe-logging-orchestrate.sh             # --dry-run: what each node has vs what it should; changes nothing
#   ./probe-logging-orchestrate.sh --apply     # fix it, one node at a time, checking each; stops at the first failure
#   ./probe-logging-orchestrate.sh --verify    # the invariants, nothing changed; exit 1 on a finding
#   ./probe-logging-orchestrate.sh --apply --mail        # one part only: --mail | --imap | --edges | --dns | --fleet
#
# WHY. On 2026-11-26 prod-homelab39's root disk hit 97% (40: 91%): 4.3 GB of
# mail.log + syslog, 1.45 million lines a day, 99% of them health checks logged
# as three-line SMTP sessions -- the three edges' haproxy `check` on 25/465/587
# every 2 s (seen as the edges' service addresses) and the three DNS nodes' Lua
# ifportup(25) probes of the public mail port, passed on by the edge with the
# PROXY header (seen as the DNS nodes' AT&T-side addresses). Every line was
# stored twice (mail.log and syslog), and the stock weekly delaycompress
# rotation kept two uncompressed weeks of both. vm62 (dovecot) logs the IMAP
# checks the same way.
#
# WHAT IT OWNS.
#   mail 39 40 41      homelab-postfix >= 0.1.33 with homelab-postfix/health_check_clients = 127.0.0.1 (the
#                      agent's own once-a-minute port checks) + the edges' service addresses + the DNS
#                      nodes' probe-side addresses -- read LIVE
#                      from the DNS nodes ($DNS_PROBE_DEV): they are DHCP leases from the AT&T
#                      gateway, so --verify fails the day one moves and --apply follows it.
#                      -> /etc/rsyslog.d/45-homelab-postfix-health-checks.conf (the prober lines
#                      dropped) and 49-homelab-mail.conf (mail.* to mail.log only, not syslog too)
#   imap 63 64 62      homelab-dovecot >= 0.1.22, the same with the edges' addresses (imap-login
#                      rip=); the backup nodes first, the active node last
#   edges 00 01 02     homelab-haproxy >= 0.1.15: every server line `check inter 10s fastinter 2s
#                      downinter 5s`; the SITE file /etc/homelab/haproxy/backends.yml gets
#                      check_inter: 5s on imap and imaps here (the package never edits a site file)
#   dns 03 04 05       every Lua record's ifportup carries interval=20 (dns-lua-orchestrate.sh --apply
#                      rewrites them; a content change needs no pdns restart)
#   fleet (every node) homelab-common >= 0.1.41 = /etc/logrotate.d/00-homelab-maxsize (maxsize 200M
#                      for every stanza, checked with logrotate -d); other machines'
#                      /var/log/journal/<id>/ left by the template removed (#104 did the VMs);
#                      pgbouncer logs on a node without pgbouncer removed (39's old layout)
#
# ORDER. Mail pool, IMAP pool, the edges one at a time (all three are live),
# DNS, then the fleet sweep (pkg-upgrade.sh per node: VIP holders last, units
# and addresses checked). Packages must already be built and published.
# The checks after an apply read the last 30 s of each log; --verify the last
# 10 minutes.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
warn(){ echo "  ${Y}warn${O} $*"; }
chg(){ echo "  ${Y}>>${O}   $*"; CHANGES=$((CHANGES+1)); }
step(){ echo; echo "=== $* ==="; }
FAILS=0; CHANGES=0

h(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
svc(){ printf '10.50.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
# run a script (on stdin) as root on a node, KEY=VALUE pairs in its environment
rscript(){ ssh -o ConnectTimeout=15 -o BatchMode=yes "$1" "sudo -n env ${*:2} bash -s" 2>/dev/null; }
up(){ timeout 4 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "${1:-0}" ge "$2"; }

MAIL_NODES="39 40 41"; IMAP_NODES="63 64 62"; EDGE_NODES="00 01 02"; DNS_NODES="03 04 05"
FLEET_NODES="$(seq -f '%02g' 0 53) 61 62 63 64 65 66 67 69 70 71 72"   # 54-60 are spares, 68 the VM spare
DNS_PROBE_DEV=${DNS_PROBE_DEV:-eth5}      # the DNS nodes' interface toward the public edge addresses
WANT_PF=0.1.33; WANT_DC=0.1.22; WANT_HA=0.1.15; WANT_CO=0.1.41
LUA_INTERVAL=${LUA_INTERVAL:-20}
CHECK_OPTS="check inter 10s fastinter 2s downinter 5s"
IMAP_CHECK_OPTS="check inter 5s fastinter 2s downinter 5s"
MAXSIZE=200M
PF_DROPIN=/etc/rsyslog.d/45-homelab-postfix-health-checks.conf
DC_DROPIN=/etc/rsyslog.d/45-homelab-dovecot-health-checks.conf
MAIL_DROPIN=/etc/rsyslog.d/49-homelab-mail.conf
LR_FILE=/etc/logrotate.d/00-homelab-maxsize

MODE=--dry-run; PARTS=""
for a in "$@"; do
    case "$a" in
        --dry-run|--apply|--verify) MODE=$a ;;
        --mail|--imap|--edges|--dns|--fleet) PARTS="$PARTS ${a#--}" ;;
        *) echo "usage: $0 [--dry-run|--apply|--verify] [--mail] [--imap] [--edges] [--dns] [--fleet]"; exit 1 ;;
    esac
done
[ -n "$PARTS" ] || PARTS="mail imap edges dns fleet"
want(){ case " $PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
# a check that is not met: a finding under --verify, a planned change otherwise
finding(){ if [ "$MODE" = --verify ] || [ "${STRICT:-0}" = 1 ]; then bad "$@"; else chg "$@"; fi; }

LOG="/home/gardner/claude/temp/probe-logging-orchestrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"; echo "mode: $MODE  parts:$PARTS"

# ------------------------------------------------------------- probers --
EDGE_SVC=""; for n in $EDGE_NODES; do EDGE_SVC="$EDGE_SVC $(svc "$n")"; done; EDGE_SVC=${EDGE_SVC# }
DNS_PROBERS=""
for n in $DNS_NODES; do
    a=$(rssh "$(h "$n")" "ip -4 -o addr show dev $DNS_PROBE_DEV scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1")
    if [ -n "$a" ]; then DNS_PROBERS="$DNS_PROBERS $a"; else bad "prod-homelab$n: no IPv4 on $DNS_PROBE_DEV -- its probe address is unknown"; fi
done
DNS_PROBERS=$(printf '%s\n' $DNS_PROBERS | sort | paste -sd' ' -)
# 127.0.0.1: the host's own checks -- homelab-agent probes every manifest tcp_port once a minute
# (postfix: 25/465/587, dovecot: 143/993), three Postfix lines or one dovecot "Client not trusted"
# warning each. Nothing real submits mail or logs in over the loopback on these hosts: local cron
# mail goes through pickup, the orchestrators' round trips come from the workstation's address.
LOCAL_PROBER=127.0.0.1
MAIL_PROBERS="$LOCAL_PROBER $EDGE_SVC${DNS_PROBERS:+ $DNS_PROBERS}"; IMAP_PROBERS="$LOCAL_PROBER $EDGE_SVC"
echo "probers: the edges' service addresses = $EDGE_SVC; the DNS nodes' probe addresses ($DNS_PROBE_DEV) = ${DNS_PROBERS:-NONE}"

# the rule line each postinst writes (same escaping: a literal dot is \\. in an rsyslog string)
re_of(){ local r="" a; for a in "$@"; do r="${r:+$r|}$(printf '%s' "$a" | sed 's/\./\\\\./g')"; done; printf '%s' "$r"; }
# the same addresses as a grep -E alternation
grep_re_of(){ local r="" a; for a in "$@"; do r="${r:+$r|}$(printf '%s' "$a" | sed 's/\./\\./g')"; done; printf '%s' "$r"; }
PF_RULE="if (\$programname == \"postfix\" or \$programname startswith \"postfix/\") and re_match(\$msg, \"\\\\[($(re_of $MAIL_PROBERS))\\\\]\") then stop"
DC_RULE="if \$programname == \"dovecot\" and re_match(\$msg, \"rip=($(re_of $IMAP_PROBERS))[^0-9]\") then stop"
PF_GREP="\\[($(grep_re_of $MAIL_PROBERS))\\]"
DC_GREP="rip=($(grep_re_of $IMAP_PROBERS))[^0-9]"

# ----------------------------------------------------- mail / imap nodes --
# TAG is a grep -E pattern for the program in a log line: " postfix/" (postfix/smtpd[1]: in syslog and
# the journal alike), " dovecot[:[]" (syslog says "dovecot:", the journal "dovecot[pid]:").
read -r -d '' MAIL_STATE_SCRIPT <<'REMOTE'
since=$(date -d "-${WINDOW} sec" -Is)
echo "ver=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
echo "rsyslog=$(systemctl is-active rsyslog)"
echo "svc=$(systemctl is-active "$UNIT")"
rsyslogd -N1 >/dev/null 2>&1 && echo valid=yes || echo valid=no
[ -f "$MAIL_DROPIN" ] && echo mail_dropin=yes || echo mail_dropin=no
echo "disk=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
echo "probe_lines=$(awk -v s="$since" '$1 > s' /var/log/mail.log 2>/dev/null | grep -cE -- "$RE")"
echo "journal_probe=$(journalctl --since "-${WINDOW}s" --no-pager -q -o short-iso 2>/dev/null | grep -E -- " $TAG" | grep -cE -- "$RE")"
echo "syslog_mail=$(awk -v s="$since" '$1 > s' /var/log/syslog 2>/dev/null | grep -cE -- " $TAG")"
echo "mail_lines=$(awk -v s="$since" '$1 > s' /var/log/mail.log 2>/dev/null | wc -l)"
echo "rule=$(grep -v '^#' "$DROPIN" 2>/dev/null | head -1)"
REMOTE

mail_checks(){ # $1 = NN, $2 = postfix|dovecot, $3 = window in seconds
    local n=$1 kind=$2 win=$3 ip pkg unit dropin want_v rule_want re tag st v rule
    ip=$(h "$n")
    if [ "$kind" = postfix ]; then pkg=homelab-postfix; unit=postfix; dropin=$PF_DROPIN; want_v=$WANT_PF; rule_want=$PF_RULE; re=$PF_GREP; tag=postfix/
    else pkg=homelab-dovecot; unit=dovecot; dropin=$DC_DROPIN; want_v=$WANT_DC; rule_want=$DC_RULE; re=$DC_GREP; tag='dovecot[:[]'; fi
    st=$(rscript "$ip" "PKG=$pkg" "UNIT=$unit" "DROPIN=$dropin" "MAIL_DROPIN=$MAIL_DROPIN" "RE='$re'" "TAG='$tag'" "WINDOW=$win" <<<"$MAIL_STATE_SCRIPT") \
        || { bad "$n unreachable"; return; }
    v=$(sed -n 's/^ver=//p' <<<"$st"); rule=$(sed -n 's/^rule=//p' <<<"$st")
    ver_ge "$v" "$want_v" && ok "$n $pkg $v" || finding "$n $pkg ${v:-none} < $want_v"
    if [ "$rule" = "$rule_want" ]; then ok "$n $dropin drops the prober addresses ($(echo "$rule_want" | grep -oE '[0-9]+\\\\\.[0-9]+\\\\\.[0-9]+\\\\\.[0-9]+' | wc -l) of them)"
    elif [ -z "$rule" ]; then finding "$n $dropin is missing"
    else finding "$n $dropin has a different rule (the prober list moved?): $rule"; fi
    [ "$(sed -n 's/^mail_dropin=//p' <<<"$st")" = yes ] && ok "$n $MAIL_DROPIN present (mail.* to mail.log only)" || finding "$n $MAIL_DROPIN is missing"
    [ "$(sed -n 's/^valid=//p' <<<"$st")" = yes ] && ok "$n rsyslogd -N1 valid" || bad "$n rsyslogd -N1 rejects the config"
    [ "$(sed -n 's/^rsyslog=//p' <<<"$st")" = active ] && ok "$n rsyslog active" || bad "$n rsyslog is $(sed -n 's/^rsyslog=//p' <<<"$st")"
    [ "$(sed -n 's/^svc=//p' <<<"$st")" = active ] && ok "$n $unit active" || bad "$n $unit is $(sed -n 's/^svc=//p' <<<"$st")"
    local pl jp sm ml disk
    pl=$(sed -n 's/^probe_lines=//p' <<<"$st"); jp=$(sed -n 's/^journal_probe=//p' <<<"$st")
    sm=$(sed -n 's/^syslog_mail=//p' <<<"$st"); ml=$(sed -n 's/^mail_lines=//p' <<<"$st"); disk=$(sed -n 's/^disk=//p' <<<"$st")
    if [ "$rule" = "$rule_want" ]; then
        [ "${pl:-0}" = 0 ] && ok "$n no prober line reached mail.log in the last ${win}s" || bad "$n $pl prober line(s) reached mail.log in the last ${win}s"
        [ "${jp:-0}" -gt 0 ] && ok "$n the probes still arrive ($jp in the journal in ${win}s) and are dropped" || warn "$n no probe seen in the journal in the last ${win}s"
    else
        echo "       ${D}last ${win}s: $pl prober lines in mail.log, $jp in the journal${O}"
    fi
    if [ "$(sed -n 's/^mail_dropin=//p' <<<"$st")" = yes ]; then
        [ "${sm:-0}" = 0 ] && ok "$n no $tag line in syslog in the last ${win}s" || bad "$n $sm $tag line(s) still reached syslog in the last ${win}s"
    fi
    [ "${ml:-0}" -gt 0 ] && ok "$n mail.log still receives lines ($ml in ${win}s)" || warn "$n mail.log received nothing in ${win}s (quiet, or rsyslog not writing?)"
    [ "${disk:-100}" -lt 85 ] && ok "$n root disk ${disk}%" || bad "$n root disk ${disk}% (RootDiskFilling fires at 85)"
}

mail_apply(){ # $1 = NN, $2 = postfix|dovecot
    local n=$1 kind=$2 ip pkg want_v probers; ip=$(h "$n")
    if [ "$kind" = postfix ]; then pkg=homelab-postfix; want_v=$WANT_PF; probers=$MAIL_PROBERS; else pkg=homelab-dovecot; want_v=$WANT_DC; probers=$IMAP_PROBERS; fi
    step "[$kind] prod-homelab$n: $pkg -> $want_v, health_check_clients = $probers"
    rssh "$ip" "echo '$pkg $pkg/health_check_clients string $probers' | sudo -n debconf-set-selections" \
        || { bad "$n debconf-set-selections failed"; return 1; }
    if ver_ge "$(ver_of "$ip" "$pkg")" "$want_v"; then
        echo "  already $want_v or newer: dpkg-reconfigure applies the list"
        rssh "$ip" "sudo -n DEBIAN_FRONTEND=noninteractive dpkg-reconfigure $pkg 2>&1" | grep -E 'rsyslog|WARNING' | sed 's/^/    /'
    else
        ./pkg-upgrade.sh "$pkg" "$n" || { bad "$n pkg-upgrade.sh $pkg failed"; return 1; }
    fi
    echo "  waiting 30 s for the next probes..."; sleep 30
    STRICT=1 mail_checks "$n" "$kind" 30
}

# ---------------------------------------------------------------- edges --
read -r -d '' EDGE_STATE_SCRIPT <<'REMOTE'
echo "ver=$(dpkg-query -W -f='${Version}' homelab-haproxy 2>/dev/null)"
echo "active=$(systemctl is-active haproxy)"
haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 && echo valid=yes || echo valid=no
echo "site_inter=$(grep -c 'check_inter: 5s' /etc/homelab/haproxy/backends.yml 2>/dev/null)"
awk '/^backend /{b=$2} /^    server /{sub(/^    /,""); print "server=" b " " $0}' /etc/haproxy/haproxy.cfg
curl -s --max-time 5 http://127.0.0.1:8404/metrics 2>/dev/null | sed -nE 's/^haproxy_server_status\{proxy="([^"]+)",server="([^"]+)",state="UP"\} ([0-9]+)$/up=\1\/\2=\3/p'
echo "disk=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
REMOTE

edge_checks(){ # $1 = NN
    local n=$1 ip st v line b rest
    ip=$(h "$n")
    st=$(rscript "$ip" <<<"$EDGE_STATE_SCRIPT") || { bad "$n unreachable"; return; }
    v=$(sed -n 's/^ver=//p' <<<"$st")
    ver_ge "$v" "$WANT_HA" && ok "$n homelab-haproxy $v" || finding "$n homelab-haproxy ${v:-none} < $WANT_HA"
    [ "$(sed -n 's/^site_inter=//p' <<<"$st")" = 2 ] && ok "$n site file: check_inter: 5s on imap and imaps" || finding "$n site file: check_inter: 5s on $(sed -n 's/^site_inter=//p' <<<"$st") of 2 IMAP entries"
    local nsrv=0
    while read -r line; do
        [ -n "$line" ] || continue
        b=${line%% *}; rest=${line#* }; nsrv=$((nsrv+1))
        case "$b" in
            imap_out|imaps_out) grep -qF -- "$IMAP_CHECK_OPTS send-proxy" <<<"$rest" && ok "$n $b: ${rest#server } " || finding "$n $b lacks '$IMAP_CHECK_OPTS': $rest" ;;
            *)                  grep -qF -- "$CHECK_OPTS send-proxy" <<<"$rest" && ok "$n $b: ${rest#server }" || finding "$n $b lacks '$CHECK_OPTS': $rest" ;;
        esac
    done < <(sed -n 's/^server=//p' <<<"$st")
    [ "$nsrv" -gt 0 ] || bad "$n no server lines in haproxy.cfg?"
    [ "$(sed -n 's/^valid=//p' <<<"$st")" = yes ] && ok "$n haproxy -c valid" || bad "$n haproxy -c rejects the config"
    [ "$(sed -n 's/^active=//p' <<<"$st")" = active ] && ok "$n haproxy active" || bad "$n haproxy is $(sed -n 's/^active=//p' <<<"$st")"
    local ups downs
    ups=$(sed -n 's/^up=//p' <<<"$st" | grep -c '=1$'); downs=$(sed -n 's/^up=//p' <<<"$st" | grep -v '=1$' | sed 's/=0$//' | paste -sd' ' -)
    [ -z "$downs" ] && [ "$ups" -gt 0 ] && ok "$n every backend server UP ($ups)" || bad "$n backend server(s) not UP: ${downs:-none reported by the metrics endpoint}"
    local disk; disk=$(sed -n 's/^disk=//p' <<<"$st")
    [ "${disk:-100}" -lt 85 ] && ok "$n root disk ${disk}%" || bad "$n root disk ${disk}%"
}

edge_apply(){ # $1 = NN
    local n=$1 ip; ip=$(h "$n")
    step "[edges] prod-homelab$n: check_inter: 5s on imap/imaps in the site file, homelab-haproxy -> $WANT_HA"
    rssh "$ip" "grep -q check_inter /etc/homelab/haproxy/backends.yml || sudo -n sed -i 's/^\(    mode: active_passive\)\$/\1\n    check_inter: 5s/' /etc/homelab/haproxy/backends.yml; echo \"  site file: \$(grep -c 'check_inter: 5s' /etc/homelab/haproxy/backends.yml) entries with check_inter: 5s\""
    if ver_ge "$(ver_of "$ip" homelab-haproxy)" "$WANT_HA"; then
        echo "  already $WANT_HA or newer: re-applying the site file"
        rssh "$ip" "sudo -n homelab-haproxy-apply-backends 2>&1" | sed 's/^/    /'
    else
        ./pkg-upgrade.sh homelab-haproxy "$n" || { bad "$n pkg-upgrade.sh homelab-haproxy failed"; return 1; }
    fi
    echo "  waiting 15 s for the first checks at the new interval..."; sleep 15
    STRICT=1 edge_checks "$n"
}

# ------------------------------------------------------------------ dns --
dns_checks(){
    local recs total with n
    recs=$(rssh "$(h 03)" 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do sudo pdnsutil zone list "$z" 2>/dev/null | awk "\$4==\"LUA\""; done')
    total=$(grep -c . <<<"$recs"); with=$(grep -c "interval=$LUA_INTERVAL" <<<"$recs")
    if [ "$total" -gt 0 ] && [ "$with" = "$total" ]; then ok "all $total Lua records carry interval=$LUA_INTERVAL"
    else finding "$with of $total Lua records carry interval=$LUA_INTERVAL"; fi
    for n in $DNS_NODES; do
        [ "$(rssh "$(h "$n")" 'systemctl is-active pdns')" = active ] && ok "$n pdns active" || bad "$n pdns not active"
    done
}
dns_apply(){
    step "[dns] dns-lua-orchestrate.sh --apply: every Lua record rewritten with interval=$LUA_INTERVAL"
    LUA_INTERVAL=$LUA_INTERVAL ./dns-lua-orchestrate.sh --apply || bad "dns-lua-orchestrate.sh --apply reported a failure"
    STRICT=1 dns_checks
}

# ---------------------------------------------------------------- fleet --
read -r -d '' FLEET_STATE_SCRIPT <<'REMOTE'
echo "common=$(dpkg-query -W -f='${Version}' homelab-common 2>/dev/null)"
if [ -f "$LR_FILE" ] && grep -q "^maxsize $MAXSIZE" "$LR_FILE"; then echo lr=yes; else echo lr=no; fi
lr_out=$(logrotate -d /etc/logrotate.conf 2>&1)
echo "lr_errors=$(grep -ci 'error' <<<"$lr_out")"
echo "lr_error_first=$(grep -i 'error' <<<"$lr_out" | head -1)"
echo "lr_earlier=$(grep -c 'rotated earlier' <<<"$lr_out")"
echo "disk=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
MID=$(cat /etc/machine-id)
for d in /var/log/journal/*/; do [ -d "$d" ] || continue; id=$(basename "$d"); [ "$id" = "$MID" ] && continue; [ "$id" = remote ] && continue
    if [ "${APPLY:-0}" = 1 ]; then echo "removed=/var/log/journal/$id ($(du -sm "$d" | cut -f1) MB)"; rm -rf "$d"; else echo "stale=$id $(du -sm "$d" | cut -f1)"; fi
done
if ! dpkg-query -W -f='${Status}' pgbouncer 2>/dev/null | grep -q 'install ok installed'; then
    for f in /var/log/postgresql/pgbouncer.log*; do [ -f "$f" ] || continue
        if [ "${APPLY:-0}" = 1 ]; then echo "removed=$f ($(du -sm "$f" | cut -f1) MB)"; rm -f "$f"; else echo "orphan=$f $(du -sm "$f" | cut -f1)"; fi
    done
fi
REMOTE

fleet_node(){ # $1 = NN, $2 = apply (0|1)
    local n=$1 apply=$2 ip st v
    ip=$(h "$n")
    up "$ip" || { echo "  ${D}prod-homelab$n: not reachable, skipped${O}"; return; }
    v=$(ver_of "$ip" homelab-common)
    if [ -z "$v" ]; then warn "$n homelab-common is not installed (the test harness?) -- nothing to carry the logrotate ceiling; skipped"; return; fi
    if [ "$apply" = 1 ] && ! ver_ge "$v" "$WANT_CO"; then
        ./pkg-upgrade.sh homelab-common "$n" | grep -vE '^\s*$|^=== (order|scanning)' | sed 's/^/    /' || { bad "$n pkg-upgrade.sh homelab-common failed"; return 1; }
    fi
    st=$(rscript "$ip" "LR_FILE=$LR_FILE" "MAXSIZE=$MAXSIZE" "APPLY=$apply" <<<"$FLEET_STATE_SCRIPT") || { bad "$n unreachable"; return; }
    v=$(sed -n 's/^common=//p' <<<"$st")
    ver_ge "$v" "$WANT_CO" && ok "$n homelab-common $v" || finding "$n homelab-common $v < $WANT_CO"
    [ "$(sed -n 's/^lr=//p' <<<"$st")" = yes ] && ok "$n $LR_FILE: maxsize $MAXSIZE" || finding "$n $LR_FILE missing or not maxsize $MAXSIZE"
    local earlier errs; earlier=$(sed -n 's/^lr_earlier=//p' <<<"$st"); errs=$(sed -n 's/^lr_errors=//p' <<<"$st")
    if [ "$(sed -n 's/^lr=//p' <<<"$st")" = yes ]; then
        [ "${earlier:-0}" -gt 0 ] && ok "$n logrotate -d: $earlier stanza(s) 'rotated earlier' past the ceiling" || bad "$n logrotate -d shows no stanza with the ceiling"
    fi
    [ "${errs:-0}" = 0 ] || warn "$n logrotate -d reports $errs error line(s): $(sed -n 's/^lr_error_first=//p' <<<"$st")"
    sed -n 's/^stale=//p' <<<"$st" | while read -r id mb; do [ -n "$id" ] && finding "$n stale journal directory /var/log/journal/$id (${mb} MB, not this machine-id)"; done
    sed -n 's/^orphan=//p' <<<"$st" | while read -r f mb; do [ -n "$f" ] && finding "$n $f (${mb} MB) on a node without pgbouncer"; done
    sed -n 's/^removed=//p' <<<"$st" | while read -r what; do [ -n "$what" ] && ok "$n removed $what"; done
    local disk; disk=$(sed -n 's/^disk=//p' <<<"$st")
    [ "${disk:-100}" -lt 85 ] && ok "$n root disk ${disk}%" || bad "$n root disk ${disk}%"
}

# ----------------------------------------------------------------- run --
if want mail; then
    step "[mail] prod-homelab39/40/41 (homelab-postfix): probers = $MAIL_PROBERS"
    for n in $MAIL_NODES; do
        if [ "$MODE" = --apply ]; then mail_apply "$n" postfix || { echo; echo "${R}stopping: prod-homelab$n failed${O}"; exit 1; }
        else echo "-- prod-homelab$n"; mail_checks "$n" postfix 600; fi
        [ "$MODE" = --apply ] && [ "$FAILS" -gt 0 ] && { echo; echo "${R}stopping before the next node: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; }
    done
fi
if want imap; then
    step "[imap] vm63 vm64 (backups) then vm62 (active) (homelab-dovecot): probers = $IMAP_PROBERS"
    for n in $IMAP_NODES; do
        if [ "$MODE" = --apply ]; then mail_apply "$n" dovecot || { echo; echo "${R}stopping: prod-homelabvm$n failed${O}"; exit 1; }
        else echo "-- prod-homelabvm$n"; mail_checks "$n" dovecot 600; fi
        [ "$MODE" = --apply ] && [ "$FAILS" -gt 0 ] && { echo; echo "${R}stopping before the next node: $FAILS check(s) failed on vm$n${O}"; exit 1; }
    done
fi
if want edges; then
    step "[edges] prod-homelab00/01/02 (homelab-haproxy): '$CHECK_OPTS', IMAP '$IMAP_CHECK_OPTS'"
    for n in $EDGE_NODES; do
        if [ "$MODE" = --apply ]; then edge_apply "$n" || { echo; echo "${R}stopping: prod-homelab$n failed${O}"; exit 1; }
        else echo "-- prod-homelab$n"; edge_checks "$n"; fi
        [ "$MODE" = --apply ] && [ "$FAILS" -gt 0 ] && { echo; echo "${R}stopping before the next edge: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; }
    done
fi
if want dns; then
    step "[dns] the Lua records' health-check interval"
    if [ "$MODE" = --apply ]; then dns_apply; else dns_checks; fi
    [ "$MODE" = --apply ] && [ "$FAILS" -gt 0 ] && { echo; echo "${R}stopping: the DNS step failed${O}"; exit 1; }
fi
if want fleet; then
    step "[fleet] every node: homelab-common >= $WANT_CO ($LR_FILE), stale journal directories, orphan pgbouncer logs"
    for n in $FLEET_NODES; do
        echo "-- prod-homelab$n"
        if [ "$MODE" = --apply ]; then fleet_node "$n" 1 || { echo; echo "${R}stopping: prod-homelab$n failed${O}"; exit 1; }
        else fleet_node "$n" 0; fi
    done
fi

echo
case "$MODE" in
    --verify)  [ "$FAILS" -eq 0 ] && echo "${G}verify: clean${O}" || echo "${R}verify: $FAILS finding(s)${O}"; exit $((FAILS>0)) ;;
    --dry-run) echo "dry run: $CHANGES change(s) would be made, $FAILS problem(s) seen; nothing changed" ;;
    --apply)   [ "$FAILS" -eq 0 ] && echo "${G}applied${O}; now: $0 --verify" || { echo "${R}applied with $FAILS failed check(s)${O}"; exit 1; } ;;
esac
