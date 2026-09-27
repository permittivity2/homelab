<?php

$labels = [];

$labels['sendinvite']        = 'Send Invite';
$labels['sendinviteintro']   = 'Invite someone to create an account. They\'ll get an email with a link that expires after a few days.';
$labels['recipientemail']    = 'Recipient Email';
$labels['optionalmessage']   = 'Personal message (optional)';
$labels['sendbutton']        = 'Send Invite';
$labels['sending']           = 'Sending...';
$labels['revoking']          = 'Revoking...';
$labels['yourinvites']       = 'Your Invites';
$labels['status']            = 'Status';
$labels['datecreated']       = 'Date Sent';
$labels['revoke']            = 'Revoke';
$labels['noinvites']         = 'You haven\'t sent any invites yet.';
$labels['nooauthtoken']      = 'This feature requires signing in via Homelab SSO.';
$labels['invalidrecipient']  = 'Enter a valid email address to invite.';
$labels['sendfailed']        = 'Could not send this invite.';
$labels['sentok']            = 'Invite sent to $address.';
// The invite itself was created server-side successfully; only the
// EMAIL delivery step failed -- distinct from sentok/sendfailed, since
// the link is real and usable even though the automatic email wasn't
// delivered (see invite_sender.php's own comment on this branch).
$labels['sentnomail']        = 'Invite created for $address, but the email could not be sent. Share this link directly: $url';
$labels['revokedok']         = 'Invite revoked.';
$labels['revokefailed']      = 'Could not revoke this invite.';
$labels['invitesubject']     = 'You\'re invited';
// Server-interpolated (see action_send_invite()'s $this->gettext(['vars' => ...])) --
// $url is the real one-time acceptance link, $days is the configured TTL.
$labels['invitebody']        = 'Click here to accept your invitation and create an account: $url' . "\n\n" . 'This link expires in $days days.';
