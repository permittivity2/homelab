<?php

$labels = [];

// Dropdown entries (match the cross-app "Account Management" convention
// the other homelab web apps use, worded Gmail-style).
$labels['title']          = 'Account';
// The rail button's own label/tooltip (shown next to the avatar in the
// mobile menu). Without this key, Roundcube renders the raw "[account]".
$labels['account']        = 'Account';
$labels['signedinas']     = 'Signed in as';
$labels['manageaccount']  = 'Manage your account';
$labels['security']       = 'Password & security';
$labels['sessions']       = 'Signed-in devices';
$labels['signout']        = 'Sign out';
// Shown as the avatar's tooltip and for screen readers.
$labels['accountfor']     = 'Account: $email';
