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
