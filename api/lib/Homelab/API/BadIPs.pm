package Homelab::API::BadIPs;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
use Socket qw(inet_pton inet_ntop AF_INET AF_INET6);

our @EXPORT_OK = qw(parse_address list_bans why_address unban_address);

# Site admins' window onto bad-ips' shared ban list (the `badips` schema that
# the edge and the mail servers write to). It does what `bad_ips list`,
# `bad_ips why ADDR` and `bad_ips unban ADDR` do on a node, and nothing more:
# the Spamhaus ranges and the other feeds are not in this table and are out
# of scope. Unban means exactly what the command means -- every active ban on
# the address ends now, and an exemption keeps it from being banned straight
# back for N hours; the edge lifts it from its firewall within a minute.
#
# The api's database login needs rights on the schema first (see
# install-orchestrators/badips-orchestrate.sh --api-grants); until then every
# function here dies with a Postgres permission error, which the routes turn
# into a plain 503.

use constant ISO => q{to_char(to_timestamp(%s) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')};
sub _iso ($col) { sprintf ISO, $col }

# A single address, v4 or v6, in its canonical text form -- or undef. Networks
# ("1.2.3.0/24") are refused: only single addresses are banned or unbanned here.
sub parse_address ($text) {
    return undef unless defined $text && !ref $text && length $text <= 45;
    return undef unless $text =~ /\A[0-9A-Fa-f:.]+\z/;
    for my $af (AF_INET, AF_INET6) {
        my $bin = inet_pton($af, $text) or next;
        return inet_ntop($af, $bin);
    }
    return undef;
}

# Active bans, newest activity first -- one row per address.
sub list_bans ($db, %a) {
    my $limit = $a{limit} // 200;
    $limit = 200 unless $limit =~ /\A\d+\z/ && $limit >= 1;
    $limit = 1000 if $limit > 1000;
    my $last = _iso('max(j.last_seen_at)');
    my $till = _iso('max(j.expires_at)');
    my $first = _iso('min(j.first_blocked_at)');
    return $db->query(<<"SQL", $limit)->hashes->to_array;
SELECT host(j.ip)                                    AS address,
       string_agg(DISTINCT j.detector_name, ', ')    AS rules,
       string_agg(DISTINCT j.originating_server, ', ') AS reported_by,
       sum(j.block_count)::int                       AS times_banned,
       $first                                        AS first_banned,
       $last                                         AS last_seen,
       $till                                         AS banned_until,
       max(g.country)                                AS country,
       max(g.org)                                    AS network_owner
  FROM badips.jailed_ips j
  LEFT JOIN badips.ip_geo g ON g.ip = j.ip
 WHERE j.expires_at > extract(epoch FROM now())
 GROUP BY j.ip
 ORDER BY max(j.last_seen_at) DESC
 LIMIT ?
SQL
}

# Everything the list holds about one address: its bans (with the rule that
# matched and the log line behind it) and any exemptions on it.
sub why_address ($db, $ip) {
    my $bans = $db->query(<<"SQL", $ip)->hashes->to_array;
SELECT originating_server  AS reported_by,
       originating_service AS service,
       detector_name       AS rule,
       pattern_matched     AS summary,
       matched_log_line    AS evidence,
       @{[ _iso('first_blocked_at') ]} AS first_banned,
       @{[ _iso('last_seen_at') ]}     AS last_seen,
       @{[ _iso('expires_at') ]}       AS banned_until,
       (expires_at > extract(epoch FROM now())) AS active,
       block_count         AS times_banned
  FROM badips.jailed_ips WHERE ip = ?::inet ORDER BY last_seen_at DESC LIMIT 20
SQL
    my $exemptions = $db->query(<<"SQL", $ip)->hashes->to_array;
SELECT ip::text AS address,
       @{[ _iso('until_at') ]}   AS exempt_until,
       (until_at > extract(epoch FROM now())) AS active,
       reason,
       created_by AS by,
       @{[ _iso('created_at') ]} AS at
  FROM badips.exemptions WHERE ip >>= ?::inet ORDER BY created_at DESC LIMIT 10
SQL
    my $geo = $db->query(
        q{SELECT country, asn, org AS network_owner FROM badips.ip_geo WHERE ip = ?::inet}, $ip)->hash;
    return { address => $ip, bans => $bans, exemptions => $exemptions, ($geo ? (where => $geo) : ()) };
}

# End every active ban on $ip and exempt it for $hours. Runs in the caller's
# transaction when one is passed, so the audit row can commit with it.
# Returns how many bans were ended.
sub unban_address ($db, $ip, %a) {
    my $hours  = $a{hours}  // 24;
    my $reason = $a{reason} // 'manual unban';
    my $by     = $a{by}     // 'unknown';
    my $ended = $db->query(
        q{UPDATE badips.jailed_ips SET expires_at = extract(epoch FROM now())::bigint
           WHERE ip = ?::inet AND expires_at > extract(epoch FROM now())}, $ip)->rows;
    $db->query(
        q{INSERT INTO badips.exemptions (ip, until_at, reason, created_by, created_at)
          VALUES (?::inet, extract(epoch FROM now())::bigint + ? * 3600, ?, ?, extract(epoch FROM now())::bigint)},
        $ip, $hours, $reason, $by);
    return $ended;
}

1;
