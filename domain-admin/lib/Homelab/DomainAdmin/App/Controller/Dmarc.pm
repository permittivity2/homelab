package Homelab::DomainAdmin::App::Controller::Dmarc;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# Read-only views over the DMARC aggregate reports that
# homelab-dmarc-ingest stores. All site_admin-gated via authenticated_email.
#
# The question these exist to answer, in the order you actually ask it:
#   1. summary  -- is anything of OURS failing alignment, per domain?
#   2. sources  -- which IPs are sending as us, and do they pass?
#   3. reports  -- what has arrived, from whom, covering what window?
#   4. report   -- the per-record detail behind one report, incl. DKIM
#                  selector, which is what makes a failure actionable.
#
# Every count here is a SUM of message_count, never a row count: one
# dmarc_records row already represents N messages, so counting rows would
# silently under-report a high-volume sender as a single event.

my $DEFAULT_DAYS = 30;

sub _window ($c) {
    my $days = $c->param('days') // $DEFAULT_DAYS;
    $days = $DEFAULT_DAYS unless $days =~ /^\d+$/ && $days > 0 && $days <= 3650;
    return $days + 0;
}

# GET /internal/v1/dmarc/summary[?days=30]
# Per-domain rollup. "aligned" means DMARC itself passed (policy_evaluated),
# which is the only thing that decides disposition -- see the warning in
# migrations/008-dmarc-reports.sql about not reading auth_results instead.
sub summary ($c) {
    $c->authenticated_email or return;
    my $days = _window($c);
    my $rows = $c->app->pg->db->query(q{
        SELECT r.policy_domain                                        AS domain,
               MAX(r.policy_p)                                        AS policy_p,
               COUNT(DISTINCT r.id)                                   AS reports,
               COUNT(DISTINCT r.org_name)                             AS reporters,
               COUNT(DISTINCT d.source_ip)                            AS sources,
               COALESCE(SUM(d.message_count), 0)                      AS messages,
               COALESCE(SUM(CASE WHEN d.dkim_result = 'pass' OR d.spf_result = 'pass'
                                 THEN d.message_count ELSE 0 END), 0) AS aligned,
               COALESCE(SUM(CASE WHEN COALESCE(d.dkim_result,'fail') <> 'pass'
                                  AND COALESCE(d.spf_result,'fail')  <> 'pass'
                                 THEN d.message_count ELSE 0 END), 0) AS failing,
               COALESCE(SUM(CASE WHEN d.disposition IN ('quarantine','reject')
                                 THEN d.message_count ELSE 0 END), 0) AS acted_on,
               MIN(r.date_begin)                                      AS window_start,
               MAX(r.date_end)                                        AS window_end
          FROM domainadmin.dmarc_reports r
          LEFT JOIN domainadmin.dmarc_records d ON d.report_id = r.id
         WHERE r.date_begin >= NOW() - (? || ' days')::interval
         GROUP BY r.policy_domain
         ORDER BY failing DESC, messages DESC, r.policy_domain
    }, $days)->hashes->to_array;
    return $c->render(json => { days => $days, domains => $rows });
}

# GET /internal/v1/dmarc/sources[?days=30&domain=&failing=1]
# "Who is sending mail as us." This is the forgery view: an IP that is not
# ours, sending volume that fails alignment, is the signal that matters
# before any move to p=reject.
sub sources ($c) {
    $c->authenticated_email or return;
    my $days   = _window($c);
    my $domain = $c->param('domain');
    my $only_failing = $c->param('failing') ? 1 : 0;

    my $sql = q{
        SELECT d.source_ip::text                                      AS source_ip,
               r.policy_domain                                        AS domain,
               COALESCE(SUM(d.message_count), 0)                      AS messages,
               COALESCE(SUM(CASE WHEN d.dkim_result = 'pass' OR d.spf_result = 'pass'
                                 THEN d.message_count ELSE 0 END), 0) AS aligned,
               COALESCE(SUM(CASE WHEN COALESCE(d.dkim_result,'fail') <> 'pass'
                                  AND COALESCE(d.spf_result,'fail')  <> 'pass'
                                 THEN d.message_count ELSE 0 END), 0) AS failing,
               COUNT(DISTINCT r.org_name)                             AS reporters,
               MAX(r.date_end)                                        AS last_seen
          FROM domainadmin.dmarc_records d
          JOIN domainadmin.dmarc_reports r ON r.id = d.report_id
         WHERE r.date_begin >= NOW() - (? || ' days')::interval
    };
    my @bind = ($days);
    if (defined $domain && length $domain) { $sql .= ' AND r.policy_domain = ?'; push @bind, $domain }
    $sql .= ' GROUP BY d.source_ip, r.policy_domain';
    # HAVING, not WHERE: "failing" is an aggregate over the group, so it
    # cannot be filtered before grouping.
    $sql .= ' HAVING SUM(CASE WHEN COALESCE(d.dkim_result,\'fail\') <> \'pass\''
          . ' AND COALESCE(d.spf_result,\'fail\') <> \'pass\' THEN d.message_count ELSE 0 END) > 0'
        if $only_failing;
    $sql .= ' ORDER BY failing DESC, messages DESC LIMIT 500';

    my $rows = $c->app->pg->db->query($sql, @bind)->hashes->to_array;
    return $c->render(json => { days => $days, domain => $domain, sources => $rows });
}

# GET /internal/v1/dmarc/reports[?days=30&domain=&limit=100]
sub reports ($c) {
    $c->authenticated_email or return;
    my $days   = _window($c);
    my $domain = $c->param('domain');
    my $limit  = $c->param('limit') // 100;
    $limit = 100 unless $limit =~ /^\d+$/ && $limit > 0 && $limit <= 1000;

    my $sql = q{
        SELECT r.id, r.org_name, r.report_id, r.policy_domain,
               r.policy_p, r.policy_pct, r.policy_adkim, r.policy_aspf,
               r.date_begin, r.date_end, r.ingested_at,
               COALESCE(SUM(d.message_count), 0) AS messages,
               COUNT(d.id)                       AS records
          FROM domainadmin.dmarc_reports r
          LEFT JOIN domainadmin.dmarc_records d ON d.report_id = r.id
         WHERE r.date_begin >= NOW() - (? || ' days')::interval
    };
    my @bind = ($days);
    if (defined $domain && length $domain) { $sql .= ' AND r.policy_domain = ?'; push @bind, $domain }
    $sql .= ' GROUP BY r.id ORDER BY r.date_end DESC, r.org_name LIMIT ' . $limit;

    return $c->render(json => {
        days => $days, reports => $c->app->pg->db->query($sql, @bind)->hashes->to_array,
    });
}

# GET /internal/v1/dmarc/reports/:id
sub report ($c) {
    $c->authenticated_email or return;
    my $id = $c->stash('id');
    my $r  = $c->app->pg->db->query(
        'SELECT * FROM domainadmin.dmarc_reports WHERE id = ?', $id)->hash;
    return $c->render(json => { error => 'report not found' }, status => 404) unless $r;
    $r->{records} = $c->app->pg->db->query(q{
        SELECT source_ip::text AS source_ip, message_count, disposition,
               dkim_result, spf_result, header_from, auth_results
          FROM domainadmin.dmarc_records
         WHERE report_id = ?
         ORDER BY message_count DESC, source_ip
    }, $id)->expand(json => 'auth_results')->hashes->to_array;
    return $c->render(json => $r);
}

# GET /internal/v1/dmarc/status
# Is the ingest actually running? A summary that is quietly empty because
# nothing has fetched in a week looks identical to "no problems", which is
# the worst possible failure mode for a compliance view.
sub status ($c) {
    $c->authenticated_email or return;
    my $lock = $c->app->pg->db->query(
        'SELECT last_run, last_host, last_note FROM domainadmin.dmarc_ingest_lock WHERE id = TRUE')->hash // {};
    my $counts = $c->app->pg->db->query(q{
        SELECT COUNT(*)                                     AS reports,
               MAX(ingested_at)                             AS last_ingest,
               MIN(date_begin)                              AS earliest,
               MAX(date_end)                                AS latest
          FROM domainadmin.dmarc_reports
    })->hash // {};
    return $c->render(json => { ingest => $lock, store => $counts });
}

1;
