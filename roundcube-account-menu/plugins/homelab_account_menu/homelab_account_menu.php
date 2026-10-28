<?php

/**
 * homelab_account_menu -- a persistent "account menu" for the webmail
 * UI, modelled on the account dropdown the other homelab web apps
 * (drive, myaccount, ...) already show, adapted to Roundcube's stock
 * elastic skin. The trigger is the brand LOGO above the task rail
 * (top-left), which is where every other app in the fleet puts it; it
 * opens a native Bootstrap popover listing: the signed-in address, a
 * "Manage your account" link to the self-service account app
 * (myaccount.<domain> = homelab-accountmanage, which auto-logs-in via
 * the shared SSO session), a couple of deep links (security, sessions),
 * and "Sign out".
 *
 * Until 0.1.10 there was ALSO a circular avatar button in the task rail
 * labelled "Account". It was added first, before the logo could be
 * wired, and is gone now: two openers for one menu was one too many, and
 * the logo is where people look. The rail keeps elastic's own stock
 * Logout button, so signing out never depended on any of this.
 *
 * Holds NO credential of its own. The address is Roundcube's own session
 * value ($_SESSION['username'], i.e. the IMAP login = the mailbox
 * address); "Manage your account" is a plain browser link (the
 * accountmanage app is a registered SSO client, so it logs in with no
 * second password prompt); "Sign out" reuses Roundcube's own logout
 * command, which already chains through homelab-sso's single-logout (see
 * homelab-roundcube's rcmail_oauth.php patch). Same minimal trust
 * boundary it takes to render any other skin element.
 *
 * Attaches with NO core skin or template edits, so a Roundcube upgrade
 * cannot break it: add_footer() emits the popover markup, and the plugin
 * JS wraps the skin's own #logo and calls elastic's public
 * UI.popup_init() on it. See this package's README for the full elastic
 * specifics -- including why that wrapper must be a <button> and not an
 * <a>.
 */
class homelab_account_menu extends rcube_plugin
{
    // Empty task: the rail is app-wide chrome, so this must load on
    // every task (mail/contacts/settings), not just one.
    public $task = '';

    private $rc;

    public function init()
    {
        $this->rc = rcube::get_instance();
        $this->add_texts('localization', true);

        // Unconditional, not gated per-task: the rail avatar has to
        // render on every page, and loading the stylesheet only on this
        // plugin's own (non-existent) action leaves the avatar blank on
        // every other task -- the exact bug recipient_blocking.php
        // documents for its own task-rail icon.
        $this->include_stylesheet('homelab_account_menu.css');

        // Nothing to render for AJAX/background requests; the taskbar
        // button + footer markup only make sense for a full HTML page.
        if ($this->rc->output && $this->rc->output->type == 'html') {
            $email = isset($_SESSION['username']) && $_SESSION['username'] !== ''
                ? $_SESSION['username']
                : (string) $this->rc->get_user_name();

            // The address is read client-side for the logo trigger's
            // title/aria-label. account_menu_initial is gone with the rail
            // avatar it used to paint.
            $this->rc->output->set_env('account_menu_email', $email);
            // Exposed for the JS fallback: if elastic's popover machinery is
            // ever unavailable, clicking the logo navigates here instead of
            // doing nothing. See the plugin JS.
            $this->rc->output->set_env('account_menu_url',
                rtrim((string) $this->rc->config->get('account_menu_url', ''), '/'));

            $this->include_script('homelab_account_menu.js');
            $this->add_hook('render_page', [$this, 'render_page']);
        }
    }

    /**
     * Emit the popover markup once per full page load, into the
     * top-level window only -- never the framed message-preview request
     * (which would duplicate the #account-menu id and a second avatar).
     */
    public function render_page($args)
    {
        $framed = !empty($this->rc->output->framed)
            || rcube_utils::get_input_value('_framed', rcube_utils::INPUT_GPC);
        if ($framed) {
            return $args;
        }

        $email = isset($_SESSION['username']) && $_SESSION['username'] !== ''
            ? $_SESSION['username']
            : (string) $this->rc->get_user_name();
        $base = rtrim((string) $this->rc->config->get('account_menu_url', ''), '/');

        // Header row: the signed-in address (not a menu action).
        $items = html::tag('li', ['role' => 'presentation', 'class' => 'account-menu-card'],
            html::span('account-menu-who', $this->gettext('signedinas')) .
            html::span('account-menu-email', rcube::Q($email))
        );

        // Manage-account links -- only when a URL is configured. They
        // open the account app in a new tab so webmail stays put; the
        // app auto-logs-in via the shared SSO session.
        if ($base !== '') {
            $items .= $this->menu_link($base . '/', 'manageaccount', 'account-manage');
            $items .= $this->menu_link($base . '/#security', 'security', 'account-security');
            $items .= $this->menu_link($base . '/#sessions', 'sessions', 'account-sessions');
        }

        // Sign out -- reuse Roundcube's own logout command (the exact
        // command the stock rail Logout button uses), which chains
        // through homelab-sso's single-logout.
        $items .= html::tag('li', ['role' => 'menuitem'],
            html::a(
                ['href' => '#', 'class' => 'account-signout active', 'onclick' => "return rcmail.command('logout')"],
                rcube::Q($this->gettext('signout'))
            )
        );

        $menu = html::div(
            ['id' => 'account-menu', 'class' => 'popupmenu', 'aria-hidden' => 'true'],
            html::tag('h3', ['id' => 'aria-label-account-menu', 'class' => 'voice'], $this->gettext('title')) .
            html::tag('ul', ['class' => 'menu listing', 'role' => 'menu', 'aria-labelledby' => 'aria-label-account-menu'], $items)
        );

        $this->rc->output->add_footer($menu);
        return $args;
    }

    private function menu_link($href, $label_key, $class)
    {
        return html::tag('li', ['role' => 'menuitem'],
            html::a(
                ['href' => $href, 'class' => $class, 'target' => '_blank', 'rel' => 'noopener noreferrer'],
                rcube::Q($this->gettext($label_key))
            )
        );
    }

    private function initial_of($email)
    {
        $s = preg_replace('/[^a-zA-Z0-9]/', '', (string) $email);
        return $s === '' ? '?' : strtoupper($s[0]);
    }
}
