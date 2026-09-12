<?php

$labels = [];

$labels['blocklabel']        = 'Block';
// Address-free fallback -- used for add_button()'s server-rendered
// initial title (no message selected yet at that point) and for the
// "nothing selected"/"SSO required" button states. Kept deliberately
// free of any $address token: those states never have one to fill in.
$labels['blocktitle']        = 'Block this address from receiving any further mail';
// JS-interpolated (rcmail.gettext() has no vars support -- see
// recipient_blocking.js) once a message with real address(es) is
// synced in. $address may be a single address or a ", "-joined list.
$labels['blocktitlewithaddress'] = 'Block mail to $address';
$labels['alreadyblocked']    = 'Already blocked';
// JS-interpolated tooltip counterpart to alreadyblocked above.
$labels['alreadyblockedtitle'] = 'Already blocked: $address';
$labels['ssorequired']       = 'Requires signing in via Homelab SSO';
$labels['blocking']          = 'Blocking...';
$labels['unblocking']        = 'Unblocking...';
// Server-interpolated via $this->gettext(['name' => ..., 'vars' => [...]])
// -- see action_block_recipient(). $address is a ", "-joined list when
// more than one address was blocked in the same click.
$labels['blockedok']         = '$address blocked. No further mail will be accepted there.';
$labels['blockfailed']       = 'Could not block $address.';
// Mixed outcome: some of the addresses on the message blocked, others
// (e.g. a transient API failure) didn't.
$labels['partialblockresult'] = 'Blocked $blocked. Could not block $failed.';
$labels['unblockedok']       = '$address unblocked.';
$labels['unblockfailed']     = 'Could not unblock this address.';
$labels['nooauthtoken']      = 'This feature requires signing in via Homelab SSO.';
$labels['norecipient']       = 'Could not determine an address to block.';
$labels['blockedaddresses']  = 'Blocked Addresses';
$labels['blockedaddressesintro'] = 'Addresses you have blocked from receiving mail. Mail sent to these addresses will be rejected by the server.';
$labels['recipientaddress']  = 'Recipient Address';
$labels['dateblocked']       = 'Date Blocked';
$labels['unblock']           = 'Unblock';
$labels['search']            = 'Search';
$labels['searchplaceholder'] = 'Filter by address';
$labels['noblockedaddresses'] = 'No blocked addresses.';
