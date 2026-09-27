/**
 * invite_sender plugin JS. Same APIs, same confirmed-real-against-
 * installed-roundcube-core discipline, as recipient_blocking.js's own
 * header comment -- rcmail.register_command/http_post/addEventListener,
 * output->command('plugin.NAME', data) always mapping to
 * rcmail.triggerEvent('plugin.NAME', data) with a single data argument.
 * Settings-tab only -- no cross-frame concerns at all (unlike
 * recipient_blocking, which has to bridge state out of a framed message
 * preview into the outer window), since sending/listing/revoking
 * invites has no per-message context.
 */

rcmail.addEventListener('init', function () {
    if (rcmail.task != 'settings') {
        return;
    }

    $('#sendinviteform').on('submit', function (e) {
        e.preventDefault();
        var recipient = $('#inviterecipient').val();
        var message = $('#invitemessage').val();
        if (!recipient) {
            return;
        }
        rcmail.http_post(
            'plugin.send_invite',
            { recipient: recipient, message: message },
            rcmail.set_busy(true, 'invite_sender.sending')
        );
    });

    $(document).on('click', '#sendinvitelist .revoke-button', function () {
        var id = $(this).data('id');
        if (!id) {
            return;
        }
        rcmail.http_post('plugin.revoke_invite', { id: id }, rcmail.set_busy(true, 'invite_sender.revoking'));
    });

    // Fired by action_send_invite() via output->command(
    // 'plugin.invite_sender_refresh') -- simplest correct way to show
    // the newly-created row without duplicating the PHP-side table-
    // building logic in JS: just reload the whole Settings frame.
    rcmail.addEventListener('plugin.invite_sender_refresh', function () {
        rcmail.goto_url('plugin.sendinvite', {}, false, true);
        $('#sendinviteform')[0].reset();
    });

    // Fired by action_revoke_invite() via output->command(
    // 'plugin.invite_sender_remove_row', id) on success only -- a
    // failed revoke leaves the row in place, matching recipient_
    // blocking's own success-only row-removal pattern.
    rcmail.addEventListener('plugin.invite_sender_remove_row', function (id) {
        $('#sendinvitelist .revoke-button[data-id="' + id + '"]').closest('tr').remove();
    });
});
