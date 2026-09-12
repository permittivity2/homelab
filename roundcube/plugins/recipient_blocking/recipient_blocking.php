<?php

/**
 * recipient_blocking -- self-service "block one of my own addresses"
 * in the web UI, backed by homelab-domain-admin's existing self-service
 * API (POST/GET/DELETE /api/v1/domains/recipient-access/mine[...]) --
 * the SAME endpoints `homelab-cli mail block/unblock/blocked` already
 * use. No new credential: this plugin reads the JWT Roundcube's own
 * core already holds in $_SESSION['oauth_token']['access_token'] for
 * IMAP/SMTP XOAUTH2 (see program/include/rcmail_oauth.php) and forwards
 * it as a Bearer token -- same trust boundary as the CLI, nothing new.
 *
 * Every hook/method this class calls was confirmed against the real
 * installed roundcube-core source before being used here (add_button,
 * message_headers_output, settings_actions, register_action,
 * register_handler, set_env, Guzzle's Client -- already a real,
 * in-use dependency of rcmail_oauth.php, not a new one introduced
 * here).
 */
class recipient_blocking extends rcube_plugin
{
    public $task = 'mail|settings';

    private $rc;

    public function init()
    {
        $this->rc = rcube::get_instance();
        $this->add_texts('localization', true);

        if ($this->rc->task == 'mail') {
            $this->add_hook('message_headers_output', [$this, 'message_headers_output']);
            $this->register_action('plugin.block_recipient', [$this, 'action_block_recipient']);
            $this->register_action('plugin.unblock_recipient', [$this, 'action_unblock_recipient']);
            $this->include_script('recipient_blocking.js');
            // These specific labels are read client-side via rcmail.gettext()
            // for dynamic post-load UI updates (button state after a click) --
            // add_button()'s own label/title attribs are resolved server-side
            // at render time and don't need this, but anything the JS looks
            // up later does.
            $this->rc->output->add_label(
                'recipient_blocking.blocklabel', 'recipient_blocking.blocktitle',
                'recipient_blocking.alreadyblocked', 'recipient_blocking.ssorequired',
                'recipient_blocking.blocking'
            );

            // Harmless to register unconditionally -- container resolution
            // means this only ever renders on a template that actually has
            // a 'toolbar' container (the message view does; the message
            // list doesn't ask for it).
            $this->add_button(
                [
                    'command'  => 'plugin.block-recipient',
                    'id'       => 'recipient-blocking-button',
                    'type'     => 'link',
                    'class'    => 'button-block-recipient disabled',
                    'classact' => 'button-block-recipient active',
                    'label'    => 'recipient_blocking.blocklabel',
                    'title'    => 'recipient_blocking.blocktitle',
                    'innerclass' => 'inner',
                ],
                'toolbar'
            );
        }

        if ($this->rc->task == 'settings') {
            $this->add_hook('settings_actions', [$this, 'settings_actions']);
            $this->register_action('plugin.blockedaddresses', [$this, 'action_blockedaddresses']);
            $this->register_action('plugin.unblock_recipient', [$this, 'action_unblock_recipient']);
            // 'plugin.body' is elastic's own generic template object name
            // (confirmed real: skins/elastic/templates/plugin.html), not a
            // plugin-specific one -- reusing it means this plugin ships no
            // skin template of its own at all.
            $this->register_handler('plugin.body', [$this, 'blockedaddresses_body']);
            $this->include_script('recipient_blocking.js');
            $this->rc->output->add_label('recipient_blocking.unblocking');
        }
    }

    // -----------------------------------------------------------------
    // Shared: talking to homelab-api's self-service recipient-access API
    // -----------------------------------------------------------------

    /**
     * The JWT Roundcube's own OAuth core already holds for this session's
     * IMAP/SMTP XOAUTH2 -- confirmed real in program/include/rcmail_oauth.php.
     * Returns null if the user logged in via the plain-password fallback
     * (SSO down), which never populates this -- callers must treat that
     * as "feature unavailable this session", not an error.
     */
    private function current_token()
    {
        return $_SESSION['oauth_token']['access_token'] ?? null;
    }

    private function api_base()
    {
        return rtrim($this->rc->config->get('recipient_blocking_api_base', ''), '/');
    }

    /**
     * @return array|null Decoded JSON body on any response (including
     *                     4xx, so callers can surface the server's own
     *                     error message), or null on a transport-level
     *                     failure (no response at all).
     */
    private function api_request($method, $path, $token, $json = null, $query = null)
    {
        $base = $this->api_base();
        if (empty($base) || empty($token)) {
            return null;
        }

        // Debian's roundcube-core ships no vendor/autoload.php at all --
        // GuzzleHttp\Client is only ever made available within a request
        // by program/include/rcmail_oauth.php's OWN conditional include
        // (confirmed real: that file's header does exactly this, not a
        // Composer autoloader registered once for the whole request), and
        // only when ITS code actually runs (e.g. IMAP/SMTP connection
        // setup) -- never guaranteed for a plugin's own standalone AJAX
        // action, which may hit this method before rcmail_oauth.php ever
        // executes in the same request. Without this, `new
        // \GuzzleHttp\Client(...)` below throws a fatal "class not found"
        // \Error, caught by this method's own \Throwable handler and
        // silently reported as a generic "Could not block this address"
        // -- caught only by a real end-to-end AJAX call, not by inspection
        // or by testing message_headers_output alone (message view always
        // already has an IMAP connection open, which happens to load this
        // as a side effect).
        if (!class_exists('\GuzzleHttp\Client') && stream_resolve_include_path('GuzzleHttp/autoload.php')) {
            include_once 'GuzzleHttp/autoload.php';
        }

        // The php-fpm SAPI here has no `curl` extension loaded (confirmed
        // real, not assumed), so Guzzle falls back to its plain PHP-stream
        // handler for every request -- no connection pooling/keep-alive,
        // no retry of its own, just a bare fsockopen. Confirmed by direct
        // repeated end-to-end testing: on this environment's homelab-api
        // (real concurrent load from other automated e2e suites), that
        // occasionally means a bare ECONNREFUSED even though the very next
        // attempt an instant later succeeds -- a real, reproducible ~1-in-3
        // failure rate observed, not a hypothetical. One bounded retry
        // (transport-level failures only, never a real 4xx/5xx response)
        // absorbs that without masking a genuinely-down backend, which
        // would still fail after the retry. Longer-term fix is enabling
        // php8.5-curl (would also make rcmail_oauth.php's own OAuth calls
        // more robust) -- out of this plugin's scope to install unasked.
        for ($attempt = 1; $attempt <= 2; $attempt++) {
            try {
                $client = new \GuzzleHttp\Client(['base_uri' => $base, 'timeout' => 8]);
                $options = ['headers' => ['Authorization' => 'Bearer ' . $token]];
                if ($json !== null) {
                    $options['json'] = $json;
                }
                if ($query !== null) {
                    $options['query'] = $query;
                }
                $response = $client->request($method, $path, $options);
                $body = json_decode((string) $response->getBody(), true);
                return ['status' => $response->getStatusCode(), 'body' => $body];
            } catch (\GuzzleHttp\Exception\RequestException $e) {
                // A 4xx/5xx from the server still has a real response body
                // (the API's own {"error": "..."} message) worth surfacing --
                // Guzzle throws for these by default, so unwrap it rather
                // than treating a clean 403/400 the same as "server unreachable".
                if ($e->hasResponse()) {
                    $response = $e->getResponse();
                    $body = json_decode((string) $response->getBody(), true);
                    return ['status' => $response->getStatusCode(), 'body' => $body];
                }
                if ($attempt === 1) {
                    continue;
                }
                rcube::write_log('errors', 'recipient_blocking: api_request to ' . $path . ' failed after retry: ' . $e->getMessage());
                return null;
            } catch (\Throwable $e) {
                // Logged, not silently swallowed -- a caught \Throwable here
                // (e.g. the Guzzle-not-loaded case above, before the fix, or
                // any other unexpected failure) would otherwise surface to
                // the user as nothing more than a generic "Could not block
                // this address", with zero trace in the log to diagnose it.
                rcube::write_log('errors', 'recipient_blocking: api_request to ' . $path . ' failed: ' . $e->getMessage());
                return null;
            }
        }

        return null;
    }

    /**
     * Extracts a bare email address from a raw header value that may be
     * "Name <addr@example.com>", a bare address, or a comma-separated
     * list (only the first entry is used -- see plan/README for why a
     * single representative address is the deliberate scope here).
     */
    private function extract_address($raw)
    {
        if (empty($raw)) {
            return null;
        }
        $raw = is_array($raw) ? reset($raw) : $raw;
        $first = trim(explode(',', $raw)[0]);
        if (preg_match('/<([^>]+)>/', $first, $m)) {
            return trim($m[1]);
        }
        return $first !== '' ? $first : null;
    }

    // -----------------------------------------------------------------
    // Message view: toolbar button + already-blocked indicator
    // -----------------------------------------------------------------

    public function message_headers_output($args)
    {
        $token = $this->current_token();
        $this->rc->output->set_env('recipient_blocking_available', !empty($token));

        if (empty($token)) {
            return $args;
        }

        $headers = $args['headers'];
        // Delivered-To is an MTA-added trace header recording the real
        // final delivery address -- more reliable than To: when present.
        // Falls back to To: otherwise (the honest ceiling once mail has
        // already landed in the mailbox -- envelope data doesn't survive
        // IMAP delivery, so there is nothing better to inspect here).
        $delivered_to = $headers->others['delivered-to'] ?? null;
        $address = $this->extract_address($delivered_to) ?: $this->extract_address($headers->to ?? null);

        if (empty($address)) {
            $this->rc->output->set_env('recipient_blocking_available', false);
            return $args;
        }

        $this->rc->output->set_env('recipient_to_block', $address);

        // Fail OPEN: any lookup failure just leaves the button in its
        // normal enabled state -- never blocks message rendering, never
        // shows a broken button, on the strength of an unrelated read.
        $already_blocked = false;
        $result = $this->api_request('GET', '/api/v1/domains/recipient-access/mine', $token, null, ['q' => $address]);
        if ($result && $result['status'] == 200 && is_array($result['body'])) {
            foreach ($result['body'] as $row) {
                if (isset($row['recipient']) && strcasecmp($row['recipient'], $address) === 0) {
                    $already_blocked = true;
                    break;
                }
            }
        }
        $this->rc->output->set_env('recipient_already_blocked', $already_blocked);

        return $args;
    }

    public function action_block_recipient()
    {
        $token = $this->current_token();
        $recipient = rcube_utils::get_input_value('recipient', rcube_utils::INPUT_POST);

        if (empty($token)) {
            $this->rc->output->show_message($this->gettext('nooauthtoken'), 'error');
            $this->rc->output->send();
            return;
        }
        if (empty($recipient)) {
            $this->rc->output->show_message($this->gettext('norecipient'), 'error');
            $this->rc->output->send();
            return;
        }

        $result = $this->api_request(
            'POST', '/api/v1/domains/recipient-access/mine', $token,
            ['recipient' => $recipient, 'action' => 'REJECT']
        );

        if ($result && in_array($result['status'], [200, 201])) {
            $this->rc->output->show_message($this->gettext('blockedok'), 'confirmation');
            $this->rc->output->command('plugin.recipient_blocking_set_state', ['recipient' => $recipient, 'blocked' => true]);
        }
        else {
            $message = ($result && !empty($result['body']['error'])) ? $result['body']['error'] : $this->gettext('blockfailed');
            $this->rc->output->show_message($message, 'error');
        }

        $this->rc->output->send();
    }

    public function action_unblock_recipient()
    {
        $token = $this->current_token();
        $recipient = rcube_utils::get_input_value('recipient', rcube_utils::INPUT_POST);

        if (empty($token) || empty($recipient)) {
            $this->rc->output->show_message($this->gettext('unblockfailed'), 'error');
            $this->rc->output->send();
            return;
        }

        $result = $this->api_request(
            'DELETE', '/api/v1/domains/recipient-access/mine/' . rawurlencode($recipient), $token
        );

        if ($result && $result['status'] == 200) {
            $this->rc->output->show_message($this->gettext('unblockedok'), 'confirmation');
            $this->rc->output->command('plugin.recipient_blocking_set_state', ['recipient' => $recipient, 'blocked' => false]);
            if ($this->rc->task == 'settings') {
                $this->rc->output->command('plugin.recipient_blocking_remove_row', $recipient);
            }
        }
        else {
            $message = ($result && !empty($result['body']['error'])) ? $result['body']['error'] : $this->gettext('unblockfailed');
            $this->rc->output->show_message($message, 'error');
        }

        $this->rc->output->send();
    }

    // -----------------------------------------------------------------
    // Settings: "Blocked Addresses" tab
    // -----------------------------------------------------------------

    public function settings_actions($args)
    {
        $args['actions'][] = [
            'action' => 'plugin.blockedaddresses',
            'type'   => 'link',
            'label'  => 'blockedaddresses',
            'title'  => 'blockedaddresses',
            'class'  => 'blockedaddresses',
        ];
        return $args;
    }

    public function action_blockedaddresses()
    {
        $this->rc->output->set_pagetitle($this->gettext('blockedaddresses'));
        $this->rc->output->send('plugin');
    }

    public function blockedaddresses_body($attrib)
    {
        $token = $this->current_token();
        $search = rcube_utils::get_input_value('q', rcube_utils::INPUT_GET);

        if (empty($token)) {
            return html::div('boxwarning', $this->gettext('nooauthtoken'));
        }

        $query = $search !== null && $search !== '' ? ['q' => $search] : null;
        $result = $this->api_request('GET', '/api/v1/domains/recipient-access/mine', $token, null, $query);
        $rows = ($result && $result['status'] == 200 && is_array($result['body'])) ? $result['body'] : [];

        $out = html::p(null, $this->gettext('blockedaddressesintro'));

        $out .= html::tag('form', ['id' => 'blockedaddressessearch', 'method' => 'get', 'action' => '#'],
            html::tag('label', ['for' => 'blockedaddressesq'], $this->gettext('search') . ': ') .
            html::tag('input', [
                'type' => 'text', 'id' => 'blockedaddressesq', 'name' => 'q',
                'value' => rcube::Q((string) $search), 'placeholder' => $this->gettext('searchplaceholder'),
            ])
        );

        $table = new html_table(['id' => 'blockedaddresseslist', 'class' => 'records-table']);
        $table->add_header('recipient', $this->gettext('recipientaddress'));
        $table->add_header('created', $this->gettext('dateblocked'));
        $table->add_header('actions', '');

        // html_table::add() appends a cell to the CURRENT row; add_row()
        // advances to a new one. Row 0 is already current after the
        // constructor, so add_row() must only run BETWEEN entries, never
        // before the first one, or the table gets a leading blank row.
        $first_row = true;
        foreach ($rows as $row) {
            if (!$first_row) {
                $table->add_row();
            }
            $first_row = false;
            $table->add('recipient', rcube::Q($row['recipient']));
            $table->add('created', rcube::Q($row['created_at'] ?? ''));
            $table->add('actions', html::tag('button', [
                'type' => 'button', 'class' => 'button unblock-button', 'data-recipient' => $row['recipient'],
            ], $this->gettext('unblock')));
        }

        if (empty($rows)) {
            $out .= html::div('boxinformation', $this->gettext('noblockedaddresses'));
        }
        else {
            $out .= $table->show($attrib);
        }

        return $out;
    }
}
