/**
 * homelab_account_menu plugin JS.
 *
 * ONE job: make the brand logo above elastic's task rail (top-left) open
 * the account dropdown.
 *
 * There used to be a second trigger -- a circular avatar button in the
 * task rail, labelled "Account" -- and this file's main job was painting
 * its initial. That button is GONE as of 0.1.10: the logo does the same
 * thing in the place people now expect to find it (every other homelab
 * app puts the account menu behind the top-left brand), and two openers
 * for one menu was one too many.
 *
 * The logo lives in elastic's own skin TEMPLATE
 * (templates/includes/menu.html), so add_button() cannot reach it from
 * PHP -- and this package's design rule is to make NO core skin edits, so
 * a Roundcube upgrade cannot break it. Hence wiring it from here.
 *
 * UI.popup_init() is elastic's public API (ui.js exports it precisely so
 * framed/mobile callers can re-init a popup), which gets the logo the
 * identical Bootstrap popover, outside-click close, Esc handling and aria
 * wiring as every other elastic dropdown, with no handler of our own.
 */
rcmail.addEventListener('init', function () {
    var $logo = $('#logo');

    // Gate on the MENU, not on the old rail button. This used to read
    // `if (!$('#accountmenulink').length) return;` -- which was correct
    // while the rail button existed and would have silently disabled the
    // logo the moment it was removed. What the logo actually needs is
    // something to open.
    if (!$logo.length || !$('#account-menu').length) {
        return;
    }

    // A <button>, NOT an <a>: elastic's own layout.less hides anchors
    // inside .popover-header on anything wider than a phone
    // ("a { display: none !important; }"), so an anchor wrapper would make
    // the logo vanish on every desktop. A button keeps it clickable AND
    // keyboard-reachable without tripping that rule.
    var $btn = $('<button type="button" class="account-logo-btn">').attr({
        'data-popup': 'account-menu',
        'aria-label': rcmail.gettext('homelab_account_menu.account'),
        title: rcmail.env.account_menu_email || ''
    });
    $logo.wrap($btn);
    $btn = $logo.parent();

    var wired = false;
    if (window.UI && typeof UI.popup_init === 'function') {
        try {
            UI.popup_init($btn.get(0));
            wired = true;
        } catch (e) {
            wired = false;
        }
    }

    // Fallback, only installed if elastic's own machinery was unavailable.
    //
    // Deliberately NOT a second dropdown implementation. #account-menu is a
    // Bootstrap popover SOURCE, not a CSS-toggled panel -- showing it by
    // hand would mean owning positioning too, and a half-placed menu is
    // worse than no menu. Since the account menu is now the only way to
    // reach the account app from webmail, degrade instead to the single most
    // useful thing it offers: just go there.
    if (!wired && rcmail.env.account_menu_url) {
        $btn.on('click', function () {
            window.location.href = rcmail.env.account_menu_url + '/';
        });
    }
});
