<?php

/**
 * invite_sender -- self-service "invite someone" in the web UI, backed
 * by homelab-invite's own gateway-fronted API (POST/GET/DELETE
 * /api/v1/invites/*) -- the SAME endpoints `homelab-cli invite send/
 * list/revoke` already use. No new credential: this plugin reads the
 * JWT Roundcube's own core already holds in
 * $_SESSION['oauth_token']['access_token'] for IMAP/SMTP XOAUTH2 (see
 * program/include/rcmail_oauth.php) and forwards it as a Bearer token
 * -- same trust boundary as the CLI, nothing new. Deliberately holds NO
 * database credential of its own (unlike homelab-invite itself) -- see
 * ../../invite/README.md and homelab-roundcube-invite's own package
 * Description for why.
 *
 * Settings-tab-only (no taskbar/message-toolbar integration) --
 * deliberately simpler than recipient_blocking's own shape: sending an
 * invite has no per-message context the way blocking a recipient does,
 * so there's no reason to take on that plugin's iframe-bridging
 * complexity (see its own header comment) for a feature that doesn't
 * need it. Structure (settings_actions hook, register_handler(
 * 'plugin.body', ...), the Guzzle-availability workaround, the
 * api_request() retry logic) is copied from recipient_blocking's own
 * Settings-tab code, which already solved these -- see that plugin's
 * header comment for why each piece is there.
 */
class invite_sender extends rcube_plugin
{
    public $task = 'settings';

    private $rc;

    public function init()
    {
        $this->rc = rcube::get_instance();
        $this->add_texts('localization', true);

        $this->add_hook('settings_actions', [$this, 'settings_actions']);
        $this->register_action('plugin.sendinvite', [$this, 'action_sendinvite']);
        $this->register_action('plugin.send_invite', [$this, 'action_send_invite']);
        $this->register_action('plugin.revoke_invite', [$this, 'action_revoke_invite']);
        // 'plugin.body' is elastic's own generic template object name
        // (confirmed real by recipient_blocking's own use of it -- see
        // that plugin's comment), not a plugin-specific one -- reusing
        // it means this plugin ships no skin template of its own either.
        // But it also means only ONE plugin can hold it at a time --
        // register_handler() throws "already taken by another plugin"
        // if a second one claims it. recipient_blocking ALSO registers
        // 'plugin.body' whenever task=='settings' (unconditionally, not
        // gated on ITS OWN action either), so with both plugins active,
        // claiming this unconditionally in init() collided on every
        // settings page load, not just this plugin's own -- confirmed
        // live (2026-09-25): a plain "Preferences" page load 500'd with
        // exactly that error the moment this plugin started loading
        // successfully. Gating on the actual current action (only true
        // when the user is on THIS plugin's own settings page) fixes it
        // without touching recipient_blocking's own working code.
        if ($this->rc->action === 'plugin.sendinvite') {
            $this->register_handler('plugin.body', [$this, 'sendinvite_body']);
        }
        $this->include_script('invite_sender.js');
        $this->rc->output->add_label('invite_sender.sending', 'invite_sender.revoking');
    }

    // -----------------------------------------------------------------
    // Talking to homelab-invite via homelab-api's own gateway
    // -----------------------------------------------------------------

    private function current_token()
    {
        return $_SESSION['oauth_token']['access_token'] ?? null;
    }

    private function api_base()
    {
        return rtrim($this->rc->config->get('invite_sender_api_base', ''), '/');
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
        // GuzzleHttp\Client is only made available within a request by
        // program/include/rcmail_oauth.php's OWN conditional include,
        // and only when ITS code actually runs -- never guaranteed for
        // a plugin's own standalone AJAX action. Confirmed real (not
        // assumed) by recipient_blocking's own identical fix -- see that
        // plugin's header comment on this exact line for the full story.
        if (!class_exists('\GuzzleHttp\Client') && stream_resolve_include_path('GuzzleHttp/autoload.php')) {
            include_once 'GuzzleHttp/autoload.php';
        }

        // One bounded retry on a transport-level failure only (never a
        // real 4xx/5xx response) -- same reasoning and same ~1-in-3
        // observed failure rate as recipient_blocking's own identical
        // retry loop (no curl extension loaded under this php-fpm SAPI,
        // so Guzzle falls back to a bare fsockopen with no pooling/
        // retry of its own).
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
                if ($e->hasResponse()) {
                    $response = $e->getResponse();
                    $body = json_decode((string) $response->getBody(), true);
                    return ['status' => $response->getStatusCode(), 'body' => $body];
                }
                if ($attempt === 1) {
                    continue;
                }
                rcube::write_log('errors', 'invite_sender: api_request to ' . $path . ' failed after retry: ' . $e->getMessage());
                return null;
            } catch (\Throwable $e) {
                rcube::write_log('errors', 'invite_sender: api_request to ' . $path . ' failed: ' . $e->getMessage());
                return null;
            }
        }

        return null;
    }

    // -----------------------------------------------------------------
    // Settings: "Send Invite" tab
    // -----------------------------------------------------------------

    public function settings_actions($args)
    {
        $args['actions'][] = [
            'action' => 'plugin.sendinvite',
            'type'   => 'link',
            'label'  => 'sendinvite',
            'title'  => 'sendinvite',
            'class'  => 'sendinvite',
        ];
        return $args;
    }

    public function action_sendinvite()
    {
        $this->rc->output->set_pagetitle($this->gettext('sendinvite'));
        $this->rc->output->send('plugin');
    }

    /**
     * POST /?_task=settings&_action=plugin.send_invite {recipient, message}
     * channel is always 'roundcube_plugin' -- this plugin sends the
     * actual invite email itself (below), unlike CLI-initiated invites
     * where homelab-invite does -- see ../../invite/README.md's API
     * section for why.
     */
    public function action_send_invite()
    {
        $token = $this->current_token();
        $recipient = trim((string) rcube_utils::get_input_value('recipient', rcube_utils::INPUT_POST));
        $message = trim((string) rcube_utils::get_input_value('message', rcube_utils::INPUT_POST));

        if (empty($token)) {
            $this->rc->output->show_message($this->gettext('nooauthtoken'), 'error');
            $this->rc->output->send();
            return;
        }
        if ($recipient === '' || !rcube_utils::check_email($recipient, false)) {
            $this->rc->output->show_message($this->gettext('invalidrecipient'), 'error');
            $this->rc->output->send();
            return;
        }

        $result = $this->api_request('POST', '/api/v1/invites', $token, [
            'recipient_email' => $recipient,
            'message' => $message !== '' ? $message : null,
            'channel' => 'roundcube_plugin',
        ]);

        if (!$result || !in_array($result['status'], [200, 201], true)) {
            $error = ($result && !empty($result['body']['error'])) ? $result['body']['error'] : $this->gettext('sendfailed');
            $this->rc->output->show_message($error, 'error');
            $this->rc->output->send();
            return;
        }

        // This plugin owns sending the actual email (channel=
        // roundcube_plugin means homelab-invite mints the token/URL but
        // does NOT send anything) -- using Roundcube's own native,
        // already-authenticated mail delivery, exactly the reason this
        // channel exists: no new mail-sending code, real DKIM alignment
        // to the sender's own domain, same trust boundary as every
        // other message this user sends. See ../../invite/README.md's
        // "Email sending" section.
        $url = $result['body']['url'] ?? '';
        $ttl_days = $this->rc->config->get('invite_sender_ttl_days_hint', 14);
        $body = $this->gettext(['name' => 'invitebody', 'vars' => ['url' => $url, 'days' => $ttl_days]]);
        if ($message !== '') {
            $body = $message . "\n\n" . $body;
        }
        $sent = $this->deliver_invite_email($recipient, $body);

        if ($sent) {
            $this->rc->output->show_message(
                $this->gettext(['name' => 'sentok', 'vars' => ['address' => $recipient]]), 'confirmation'
            );
        }
        else {
            // The invite row and its real, usable link already exist on
            // the server even though the mail delivery step below
            // failed -- surfaced distinctly rather than as a generic
            // failure, since the caller can still hand the URL to the
            // recipient another way (same posture homelab-invite's own
            // CLI-channel send takes on a mail failure).
            $this->rc->output->show_message(
                $this->gettext(['name' => 'sentnomail', 'vars' => ['address' => $recipient, 'url' => $url]]), 'warning'
            );
        }

        $this->rc->output->command('plugin.invite_sender_refresh');
        $this->rc->output->send();
    }

    /**
     * Roundcube-core's own real mail delivery -- Mail_mime (a PEAR-style
     * class, autoloaded application-wide from /usr/share/php/Mail/
     * mime.php, unlike GuzzleHttp\Client above which needs the explicit
     * workaround -- confirmed by checking for any require/include of it
     * anywhere in rcmail_sendmail.php: there is none, it's just used
     * directly, so a registered autoloader must already cover it on
     * every request) + rcube::deliver_message(), the same lower-level
     * method program/actions/mail/sendmdn.php calls for its own
     * self-contained (non-compose-form) send -- confirmed real against
     * the actual installed roundcube-core source, not guessed: exact
     * signature is deliver_message(&$message, $from, $mailto, &$error,
     * &$body_file=null, $options=null, $disconnect=false), defined in
     * program/lib/Roundcube/rcube.php.
     */
    private function deliver_invite_email($to, $body)
    {
        $identity = $this->rc->user->get_identity();
        $from = $identity['email'] ?? $this->rc->user->get_username();

        $headers = [
            'From' => $from,
            'To' => $to,
            'Subject' => $this->gettext('invitesubject'),
            'Date' => $this->rc->user_date(),
            'Message-ID' => $this->rc->gen_message_id(),
        ];

        $message = new Mail_mime("\r\n");
        $message->setTXTBody($body);
        $message->headers($headers);

        $smtp_error = null;
        $body_file = null;
        $sent = $this->rc->deliver_message($message, $from, [$to], $smtp_error, $body_file, null, true);
        if (!$sent) {
            rcube::write_log('errors', 'invite_sender: deliver_message to ' . $to . ' failed: ' . print_r($smtp_error, true));
        }
        return $sent;
    }

    /**
     * DELETE-equivalent (POST, since this is an AJAX form action, not a
     * real HTTP DELETE) -- id passed from the row the list rendered.
     */
    public function action_revoke_invite()
    {
        $token = $this->current_token();
        $id = rcube_utils::get_input_value('id', rcube_utils::INPUT_POST);

        if (empty($token) || empty($id)) {
            $this->rc->output->show_message($this->gettext('revokefailed'), 'error');
            $this->rc->output->send();
            return;
        }

        $result = $this->api_request('DELETE', '/api/v1/invites/' . rawurlencode($id), $token);

        if ($result && $result['status'] == 200) {
            $this->rc->output->show_message($this->gettext('revokedok'), 'confirmation');
            $this->rc->output->command('plugin.invite_sender_remove_row', $id);
        }
        else {
            $error = ($result && !empty($result['body']['error'])) ? $result['body']['error'] : $this->gettext('revokefailed');
            $this->rc->output->show_message($error, 'error');
        }

        $this->rc->output->send();
    }

    public function sendinvite_body($attrib)
    {
        $token = $this->current_token();
        if (empty($token)) {
            return html::div('boxwarning', $this->gettext('nooauthtoken'));
        }

        $out = html::p(null, $this->gettext('sendinviteintro'));

        $out .= html::tag('form', ['id' => 'sendinviteform', 'method' => 'post', 'action' => '#'],
            html::tag('label', ['for' => 'inviterecipient'], $this->gettext('recipientemail') . ': ') .
            html::tag('input', [
                'type' => 'email', 'id' => 'inviterecipient', 'name' => 'recipient', 'required' => 'required',
            ]) .
            html::tag('br') .
            html::tag('label', ['for' => 'invitemessage'], $this->gettext('optionalmessage') . ': ') .
            html::tag('textarea', ['id' => 'invitemessage', 'name' => 'message', 'rows' => 3]) .
            html::tag('br') .
            html::tag('button', ['type' => 'submit', 'class' => 'button mainaction'], $this->gettext('sendbutton'))
        );

        $result = $this->api_request('GET', '/api/v1/invites', $token);
        $rows = ($result && $result['status'] == 200 && is_array($result['body'])) ? $result['body'] : [];

        $out .= html::tag('h3', null, $this->gettext('yourinvites'));

        $table = new html_table(['id' => 'sendinvitelist', 'class' => 'records-table']);
        $table->add_header('recipient', $this->gettext('recipientemail'));
        $table->add_header('status', $this->gettext('status'));
        $table->add_header('created', $this->gettext('datecreated'));
        $table->add_header('actions', '');

        // html_table::add() appends a cell to the CURRENT row; add_row()
        // advances to a new one. Row 0 is already current after the
        // constructor, so add_row() must only run BETWEEN entries, never
        // before the first -- same pattern (and same reasoning) as
        // recipient_blocking's own identical table-building loop. No
        // per-row id attribute (unlike a guess at an unconfirmed
        // add_row($attribs) signature) -- the revoke button's own
        // data-id attribute is enough for the JS to find and remove the
        // right row via closest('tr'), matching recipient_blocking.js's
        // own DOM-traversal approach rather than a server-assigned id.
        $first_row = true;
        foreach ($rows as $row) {
            if (!$first_row) {
                $table->add_row();
            }
            $first_row = false;
            $table->add('recipient', rcube::Q($row['recipient_email']));
            $table->add('status', rcube::Q($row['status']));
            $table->add('created', rcube::Q($row['created_at'] ?? ''));
            $revoke = $row['status'] === 'pending'
                ? html::tag('button', [
                    'type' => 'button', 'class' => 'button revoke-button', 'data-id' => $row['id'],
                  ], $this->gettext('revoke'))
                : '';
            $table->add('actions', $revoke);
        }

        if (empty($rows)) {
            $out .= html::div('boxinformation', $this->gettext('noinvites'));
        }
        else {
            $out .= $table->show($attrib);
        }

        return $out;
    }
}
