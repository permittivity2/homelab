/**
 * recipient_blocking plugin JS.
 *
 * Every API used here was confirmed against the real installed
 * roundcube-core program/js/app.js and common.js before use:
 * rcmail.register_command, rcmail.http_post, rcmail.env,
 * rcmail.addEventListener/triggerEvent (common.js's event-engine mixin).
 * output->command('plugin.NAME', data) on the PHP side always maps to
 * exactly rcmail.triggerEvent('plugin.NAME', data) with a SINGLE data
 * argument (confirmed in rcmail_output_html.php's command() method) --
 * not a plain function call, and not multiple arguments.
 */

function recipient_blocking_apply_button_state(blocked) {
    var link = $('#recipient-blocking-button');
    if (!link.length) {
        return;
    }
    if (blocked) {
        link.addClass('disabled').removeClass('active')
            .attr('aria-disabled', 'true')
            .attr('title', rcmail.gettext('recipient_blocking.alreadyblocked'));
        link.find('.inner').text(rcmail.gettext('recipient_blocking.alreadyblocked'));
    }
    else {
        link.removeClass('disabled').addClass('active')
            .removeAttr('aria-disabled')
            .attr('title', rcmail.gettext('recipient_blocking.blocktitle'));
        link.find('.inner').text(rcmail.gettext('recipient_blocking.blocklabel'));
    }
}

rcmail.addEventListener('init', function () {
    if (rcmail.task == 'mail') {
        if (!rcmail.env.recipient_blocking_available) {
            var link = $('#recipient-blocking-button');
            link.addClass('disabled').removeClass('active')
                .attr('aria-disabled', 'true')
                .attr('title', rcmail.gettext('recipient_blocking.ssorequired'));
        }
        else {
            recipient_blocking_apply_button_state(!!rcmail.env.recipient_already_blocked);

            rcmail.register_command('plugin.block-recipient', function () {
                if (!rcmail.env.recipient_to_block || rcmail.env.recipient_already_blocked) {
                    return;
                }
                rcmail.http_post('plugin.block_recipient', { recipient: rcmail.env.recipient_to_block }, rcmail.set_busy(true, 'recipient_blocking.blocking'));
            }, true);
        }

        // Fired by action_block_recipient()/action_unblock_recipient()
        // via output->command('plugin.recipient_blocking_set_state', {...})
        // -- see the PHP-side comment on command() for why this is a
        // single-object event payload, not two separate arguments.
        rcmail.addEventListener('plugin.recipient_blocking_set_state', function (e) {
            if (e && e.recipient === rcmail.env.recipient_to_block) {
                rcmail.env.recipient_already_blocked = !!e.blocked;
                recipient_blocking_apply_button_state(!!e.blocked);
            }
        });
    }

    if (rcmail.task == 'settings') {
        $(document).on('click', '#blockedaddresseslist .unblock-button', function () {
            var recipient = $(this).data('recipient');
            if (!recipient) {
                return;
            }
            rcmail.http_post('plugin.unblock_recipient', { recipient: recipient }, rcmail.set_busy(true, 'recipient_blocking.unblocking'));
        });

        $('#blockedaddressessearch').on('submit', function (e) {
            e.preventDefault();
            var q = $('#blockedaddressesq').val();
            rcmail.goto_url('plugin.blockedaddresses', { q: q }, false, true);
        });

        rcmail.addEventListener('plugin.recipient_blocking_remove_row', function (recipient) {
            $('#blockedaddresseslist .unblock-button[data-recipient="' + recipient + '"]').closest('tr').remove();
        });
    }
});
