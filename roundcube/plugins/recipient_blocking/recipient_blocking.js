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
 *
 * CROSS-FRAME NOTE (see the PHP class doc-comment for the full story):
 * this same script loads in TWO different documents for the mail task
 * -- the outer window (where the toolbar button and #mailtoolbar
 * actually live) and the framed message preview (where
 * message_headers_output computes the per-message address/blocked
 * state, via _framed=1, program/js/app.js's show_message). Those are
 * separate rcmail.env objects. The framed copy of this script's job is
 * ONLY to push what it knows up to the outer window via
 * parent.recipient_blocking_sync_from_frame(...) -- the exact
 * `rcmail.is_framed()` + `parent.rcmail...` pattern roundcube-core
 * itself already uses (program/js/app.js:325-328, :552-553). All the
 * actual button/command logic below runs in the outer window only.
 */

// `candidates` is the current message's array of {address, blocked}
// (rcmail.env.recipient_candidates), always non-empty here -- the
// empty case is recipient_blocking_set_no_selection() below instead.
// The tooltip only ever names the addresses a click would actually act
// on: every candidate when all are already blocked, or just the
// not-yet-blocked ones otherwise -- so the tooltip and a click always
// describe the same set.
function recipient_blocking_apply_button_state(candidates) {
    var link = $('#recipient-blocking-button');
    if (!link.length) {
        return;
    }
    var actionable = candidates.filter(function (c) { return !c.blocked; });

    if (!actionable.length) {
        var allAddresses = candidates.map(function (c) { return c.address; }).join(', ');
        link.addClass('disabled').removeClass('active')
            .attr('aria-disabled', 'true')
            .attr('title', rcmail.gettext('recipient_blocking.alreadyblockedtitle').replace('$address', allAddresses));
        link.find('.inner').text(rcmail.gettext('recipient_blocking.alreadyblocked'));
    }
    else {
        var actionableAddresses = actionable.map(function (c) { return c.address; }).join(', ');
        link.removeClass('disabled').addClass('active')
            .removeAttr('aria-disabled')
            .attr('title', rcmail.gettext('recipient_blocking.blocktitlewithaddress').replace('$address', actionableAddresses));
        link.find('.inner').text(rcmail.gettext('recipient_blocking.blocklabel'));
    }
}

// Distinct from "already blocked": nothing is selected (or several
// messages are, or the single selected message's preview hasn't
// finished loading yet, or it has no derivable address at all), so
// there's no one address to act on. Same disabled look, but keeps the
// plain "Block" label/title rather than implying anything has actually
// been blocked.
function recipient_blocking_set_no_selection() {
    var link = $('#recipient-blocking-button');
    if (!link.length) {
        return;
    }
    link.addClass('disabled').removeClass('active')
        .attr('aria-disabled', 'true')
        .attr('title', rcmail.gettext('recipient_blocking.blocktitle'));
    link.find('.inner').text(rcmail.gettext('recipient_blocking.blocklabel'));
}

// Outer-window-only. Called by the framed preview's own init handler
// below once it has computed the candidate address list for whatever
// message it just rendered. `uid` is compared against rcmail.preview_id
// (the UID core itself considers "currently previewed", set in
// show_message) so a slow-to-load preview for a message the user has
// since navigated away from can't clobber newer state that arrived
// first -- iframe loads are async, order of completion isn't
// guaranteed to match order of selection.
function recipient_blocking_sync_from_frame(data) {
    if (!data || data.uid == null || String(data.uid) !== String(rcmail.preview_id)) {
        return;
    }
    rcmail.env.recipient_candidates = data.candidates || [];
    if (rcmail.env.recipient_candidates.length) {
        recipient_blocking_apply_button_state(rcmail.env.recipient_candidates);
    }
    else {
        recipient_blocking_set_no_selection();
    }
}

// Applies a plugin.recipient_blocking_set_state event's outcome
// (addresses just blocked and/or unblocked) onto the outer window's
// current candidate list in place, case-insensitively, without needing
// a fresh preview load to see the button reflect it.
function recipient_blocking_merge_state(candidates, blockedAddrs, unblockedAddrs) {
    var blockedSet = {}, unblockedSet = {};
    (blockedAddrs || []).forEach(function (a) { blockedSet[a.toLowerCase()] = true; });
    (unblockedAddrs || []).forEach(function (a) { unblockedSet[a.toLowerCase()] = true; });
    return candidates.map(function (c) {
        var key = c.address.toLowerCase();
        if (blockedSet[key]) {
            return { address: c.address, blocked: true };
        }
        if (unblockedSet[key]) {
            return { address: c.address, blocked: false };
        }
        return c;
    });
}

rcmail.addEventListener('init', function () {
    if (rcmail.task == 'mail') {
        if (rcmail.is_framed()) {
            // We're the framed preview document -- push what this
            // render knows up to the parent; nothing else to do here.
            if (typeof parent.recipient_blocking_sync_from_frame === 'function') {
                parent.recipient_blocking_sync_from_frame({
                    uid: rcmail.env.uid,
                    candidates: rcmail.env.recipient_candidates || []
                });
            }
            return;
        }

        // Outer window from here on. recipient_blocking_available is
        // session-wide (set once in the PHP plugin's init(), not
        // per-message -- see its doc-comment), so this decision is
        // final for the whole session and doesn't need to wait on any
        // preview ever loading.
        if (!rcmail.env.recipient_blocking_available) {
            var link = $('#recipient-blocking-button');
            link.addClass('disabled').removeClass('active')
                .attr('aria-disabled', 'true')
                .attr('title', rcmail.gettext('recipient_blocking.ssorequired'));
        }
        else {
            // Starts in the "nothing selected" state; the first framed
            // preview to load will sync in the real per-message state.
            rcmail.env.recipient_candidates = [];
            recipient_blocking_set_no_selection();

            rcmail.register_command('plugin.block-recipient', function () {
                var actionable = (rcmail.env.recipient_candidates || [])
                    .filter(function (c) { return !c.blocked; })
                    .map(function (c) { return c.address; });
                if (!actionable.length) {
                    return;
                }
                rcmail.http_post('plugin.block_recipient', { recipients: actionable }, rcmail.set_busy(true, 'recipient_blocking.blocking'));
            }, true);

            // Selection changes (including drops to zero or jumps to
            // multiple -- e.g. moving/archiving/deleting the previewed
            // message, a routine action, not a rare one) must clear the
            // stale target immediately rather than leaving the button
            // pointing at a message that's no longer in view. Core's
            // own Reply/Forward/Delete buttons grey out the same way
            // via this exact same list event.
            if (rcmail.message_list) {
                rcmail.message_list.addEventListener('select', function () {
                    rcmail.env.recipient_candidates = [];
                    recipient_blocking_set_no_selection();
                });
            }
        }

        // Fired by action_block_recipient()/action_unblock_recipient()
        // via output->command('plugin.recipient_blocking_set_state', {...})
        // -- see the PHP-side comment on command() for why this is a
        // single-object event payload, not two separate arguments. The
        // block/unblock request always originates here in the outer
        // window (the command is only ever registered above), so the
        // response always comes back to this same window too.
        rcmail.addEventListener('plugin.recipient_blocking_set_state', function (e) {
            if (!e || !rcmail.env.recipient_candidates || !rcmail.env.recipient_candidates.length) {
                return;
            }
            rcmail.env.recipient_candidates = recipient_blocking_merge_state(
                rcmail.env.recipient_candidates, e.blocked, e.unblocked
            );
            recipient_blocking_apply_button_state(rcmail.env.recipient_candidates);
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
