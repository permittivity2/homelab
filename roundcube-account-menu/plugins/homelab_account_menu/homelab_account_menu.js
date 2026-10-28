/**
 * homelab_account_menu plugin JS.
 *
 * One cosmetic job: turn the rail button's icon into a Gmail-style
 * circular avatar with the signed-in address's initial. We do this by
 * setting a `data-initial` attribute + a class on the button; the CSS
 * then renders the initial THROUGH the button's :before pseudo-element --
 * the same slot every other elastic rail icon uses -- so the avatar
 * stacks above the "Account" label exactly like the other buttons,
 * instead of sitting beside it.
 *
 * Purely progressive: if this doesn't run, the CSS :before shows a plain
 * fa-user-circle glyph and the dropdown still works (elastic's own
 * dropdowns_init() wires the data-popup trigger to #account-menu).
 */
rcmail.addEventListener('init', function () {
    var $btn = $('#accountmenulink');
    if (!$btn.length) {
        return;
    }

    $btn.addClass('has-account-avatar')
        .attr('data-initial', (rcmail.env.account_menu_initial || '?') + '');

    if (rcmail.env.account_menu_email) {
        $btn.attr('title', rcmail.env.account_menu_email);
    }
});

/**
 * Second trigger for the SAME dropdown: the brand logo above the task
 * rail (top-left). One menu, two openers -- the user asked for the logo
 * to behave like the Account rail button, and duplicating the menu would
 * duplicate its ids.
 *
 * The logo lives in elastic's own skin TEMPLATE
 * (templates/includes/menu.html), so add_button() cannot attach to it
 * from PHP and this package's whole design rule is to make no core skin
 * edits -- so it is wired here, the same way the avatar above is.
 * UI.popup_init() is elastic's public API (ui.js exports it precisely so
 * framed/mobile callers can re-init a popup), which means the logo gets
 * the identical Bootstrap popover, outside-click close, Esc handling and
 * aria wiring as every other elastic dropdown, with no handler of our own.
 */
rcmail.addEventListener('init', function () {
    var $logo = $('#logo');

    // Gate on the rail button, not on the task name: if #accountmenulink
    // is absent there is no rendered account menu to open (the login page
    // has a logo but no task rail), and wiring the logo there would pop an
    // empty menu.
    if (!$logo.length || !$('#accountmenulink').length) {
        return;
    }
    if (!window.UI || typeof UI.popup_init !== 'function') {
        return;
    }

    // A <button>, NOT an <a>: elastic's own layout.less hides anchors
    // inside .popover-header on anything wider than a phone
    // ("a { display: none !important; }"), so an anchor wrapper would make
    // the logo vanish on every desktop. A button keeps it clickable AND
    // keyboard-reachable without tripping that rule.
    $logo.wrap($('<button type="button" class="account-logo-btn">').attr({
        'data-popup': 'account-menu',
        'aria-label': rcmail.gettext('homelab_account_menu.account'),
        title: rcmail.env.account_menu_email || ''
    }));

    UI.popup_init($logo.parent().get(0));
});
