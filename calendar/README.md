# homelab-calendar

`calendar.<domain>`: calendars, single and repeating events, sharing, ICS feeds.
Post-cutover item #74 (the plan and the record live in the tracker, not here).

## The model

- A **calendar** belongs to an account (by address, like every app schema here).
  Every account gets one on its first visit.
- An **event** is stored once: title, place, description, a colour, and its first
  occurrence as a **wall-clock time in an IANA zone** (`starts_at`/`ends_at` are
  the derived instants; all-day events are dates with an exclusive end). A
  repeating event carries an RFC 5545 **RRULE**. Occurrences are computed by
  `Homelab::Calendar::Recurrence` in the event's zone, so 09:00 stays 09:00
  across a DST change. Per-occurrence edits and cancellations are rows in
  `event_exceptions`, keyed by the occurrence's original start (RECURRENCE-ID);
  "this and following" splits the series into two events.
- **Sharing** is drive's shape: every share has a token; `shared_with_email`
  NULL means "anyone with the link". Named shares are `read` or `edit` (an
  editor may add, change and remove events, never share on or change the
  calendar); link shares are read-only and show everything or busy times only.
  `/c/<token>` opens a calendar, `/c/<token>.ics` is its feed (occurrences
  expanded in UTC for a year back and two ahead, so no VTIMEZONE is needed);
  `/e/<token>` and `/e/<token>.ics` do the same for one event.
- **Export** (`/api/calendars/:id/export.ics`) keeps the rules: masters with
  RRULE, `DTSTART;TZID=`, EXDATE and RECURRENCE-ID overrides. TZID without a
  VTIMEZONE component, as Google's exports do; a consumer that insists on the
  component is the known limit.

## Dates on the wire

FullCalendar runs in a named zone with no timezone plugin ("UTC-coercion"):
every Date it hands out holds the wall clock in that zone in its UTC fields and
it ignores offsets on the strings it reads. So the page and the server speak
**offset-less wall-clock strings plus a zone name** (`2026-11-14T09:00:00`,
`timezone: America/Chicago`; all-day `2026-11-14`), and the server does every
conversion. `GET /api/events` renders occurrences in the zone the page asks for
(`timeZone=`).

**The viewer's zone (0.4.0, #88) is Local by default:** the zone of the device
the page is looked at from, as the browser reports it (a phone sets its clock
from where it is, so a drive from Montana into Kansas moves the grid to
Central on the next load, or when the tab is next looked at). A fixed zone can
be chosen in Settings or from the zone code after the view switcher
(`user_prefs.timezone`; NULL = Local). The page reports the device's zone
(`user_prefs.device_zone`) so mail written while nobody is looking (reminders)
uses it. The server's `viewer_zone` order: the request's `timeZone`, the fixed
preference, the device zone, the zone from My Account, the default. No IP
geolocation anywhere: the device already knows.

**Every event keeps its own zone** (`events.timezone`, the zone it was made in:
the address's when the AI read one off the email, #89), and since 0.4.0 an
update without `timezone` leaves it alone; `times_zone` says which zone the
wall clocks in the body are written in (a drag in a grid shown in another
zone), and the editor shows an existing event's clocks in the event's own zone.
**Pinned** (`events.pinned`) is display only: the chip keeps its true slot in
the viewer's zone but reads its own zone's clock, "1:30 PM CST" with a pin
mark, in every view; the peek says both clocks. `event_zone_start` /
`event_zone_end` carry the event-zone clocks in the JSON.

## Search (0.2.0, 0.4.0)

`GET /api/search?q=` matches every typed word against title, place, notes and
the people invited, over the account's calendars, the calendars shared with it
and the single events shared with it. With `related=1` and the AI consent on,
`Homelab::Calendar::AI::relate` ranks the account's events of the last six and
next eighteen months by meaning ("doctor" finds the infusion at the hospital),
and the answer carries `related` with a `why` per hit; the page asks for the
literal part first and the related part second, the CLI asks for both.
`POST /api/zone-for-place` is the AI reading the zone off an address, for the
editor's "From the address" button.

## Routes

Signed in (session cookie; writes carry `X-CSRF-Token`): `/`, `/login`,
`/oauth/callback`, `POST /logout`; `/api/calendars` (GET, POST), `/api/calendars/:id`
(PATCH), `/api/calendars/:id/delete` (POST), `/api/calendars/:id/visible` (PUT),
`/api/calendars/:id/shares` (GET, POST), `/api/calendars/:id/export.ics`;
`/api/events?start&end&timeZone`, `POST /api/events`, `/api/events/:id` (GET with
`recurrence_id`, PATCH with `scope` = all | this | following), `/api/events/:id/delete`
(POST, same scope), `/api/events/:id/shares` (GET, POST), `/api/shares/:id/revoke`
(POST), `/api/prefs` (GET, PUT); `/api/account` (GET, PUT: the switches and
consents, the reminder addresses); `/api/mail-links/:token` (GET, `/propose`,
`/research`); `/api/suggestions` (GET, `/:token/save`, `/:token/dismiss`).
Public: `/c/:token[.ics]`, `/c/:token/events`, `/e/:token[.ics]`, `/health`.
Gateway-fronted through homelab-api (`/api/v1/calendar/*` -> `/internal/v1/calendar/*`,
Bearer): `account` (GET, PUT) for myaccount,
`admin/accounts/:email/entitlements` (PUT, site_admin) for what an account is
allowed (#80; #63's billing later), and for homelab-cli (#82): `calendars`
(GET), `events` (GET `from`, `to`, `calendar_id`, `limit` 1-200, `page`; POST
the editor's body), `events.ics` (GET: the range as one VEVENT per occurrence,
UTC instants), `export.ics` (GET: one calendar with its rules, like the page's
export) and `import` (POST, body `text/calendar`: `Homelab::Calendar::ICSImport`;
a UID already in one of your editable calendars updates that event, EXDATE
cancels occurrences, a VALARM trigger is the reminder, RECURRENCE-ID
components are skipped with a reason). The range: a date, a wall clock, `today`
or `tomorrow` in the account's zone; neither means today, `from` alone a year
on, a date as `to` that whole day, three years at most.

Events carry `reminder_minutes` (one reminder per event, by email, `null` for
none; new events get 10 in the editor) and, on creation, an optional
`share_with` address (#79).

A link reused after it became an event (#81): `POST /api/events` and `PATCH
/api/events/:id` take `mail_link_token`, and the link then remembers the event
for that account (`calendar.mail_link_events`; one link serves every recipient
of a message, and may become several events). `GET /api/mail-links/:token`
lists them as `events_made` (live events only, wall clocks in the viewer's
zone, `made_at`), and the page shows them first with Open, "Update from this
email" (the email's details laid over the event; Save is a PATCH, so the event
keeps its id, reminder and shares) and "Add another event". A suggestion an
account saved stays out of its Suggestions list even if the event is deleted
later; events are soft-deleted, so a deleted one drops out of `events_made`
and the link behaves like a first click again.

0.2.0 (#83): every event JSON carries `url`, a deep link `/?date=YYYY-MM-DD&event=ID[&rid=]`
that opens the page on that day with the event highlighted and its editor open
(reminder emails and share notices use it); `reminders` is a list of up to three
`{minutes_before, channel}` (email or webhook; `reminder_minutes` still works
as the single-reminder form); `GET /api/trash` and `POST /api/events/:id/restore`
(events are soft-deleted; 30 days); `GET /api/search?q=`; `POST /api/quick-add
{text}` (a draft by the plain parser, nothing saved); `GET /api/events/similar?title&start`
(the duplicate check before Save); `PUT /api/calendars/:id/position {direction}`;
`GET /metrics` (Prometheus text, no sign-in, fleet planes only). Preferences gained
`default_reminder_minutes`, `all_day_reminder_hour`, `default_duration_minutes`,
`date_format` (mdy|dmy|ymd), `remind_shared` and `webhook_url`. The same verbs sit
under `/internal/v1/calendar/` for homelab-cli (one event: GET, PATCH, `/delete`,
`/restore`, `/shares`; `trash`, `search`, `calendars` POST, `calendars/:id/shares`,
`shares/:id/revoke`, `suggestions`, `prefs`), each the session handler behind a
Bearer check (a Bearer caller passes the CSRF check). The import takes `dry_run=1`.

## The background runner (#79, #80)

`Homelab::Calendar::Runner` runs from a 30 s timer in every hypnotoad worker;
the six processes on the pool share one queue in Postgres and claim rows with
`FOR UPDATE SKIP LOCKED` (homelab-worker's pattern), so nothing is sent or
proposed twice. Each tick: queue the next 48 h of occurrences of events with a
reminder (`calendar.reminder_queue`, one row per reminder, occurrence and
account: the owner and everyone the calendar or event is shared with), send
the due ones through `mailer:` (the submission VIP, like drive's; a few per
tick), then pick up links whose email arrived for an account with the
"propose automatically" consent, run the plain-parse gate
(`Runner::looks_like_event`), and call homelab-ai without blocking (promises;
at most `runner.ai_in_flight` calls per process). Results land on the
`mail_links` row (`proposal`, `facts`); the Suggestions list and the `/m/:token`
page read them. `runner.enabled: 0` (or `HOMELAB_CALENDAR_RUNNER=0`, the tests)
keeps it off. Without `mailer:` reminders queue and wait. Reminders for an
all-day event are relative to 9 AM of its first day.

## Invitations (#85)

An event's owner (the organizer) invites people by address: `calendar.event_attendees`
holds each with a status (`needs-action` until they answer), an RSVP token and the
iCalendar SEQUENCE last mailed to them. The mail goes through `calendar.notice_queue`,
claimed by the runner as reminders are, so Save never waits on SMTP: a `request`
(the invitation; also when the event changes, with SEQUENCE+1 and everyone asked
again when the time or place changed, their answers kept for a retitle), a `cancel`
(the event deleted, or the person taken off the list) and a `reply` (to the
organizer: who answered what, plus their webhook when set). `Homelab::Calendar::Invite`
renders the text; `Homelab::Common::Mailer`'s `calendar` option gives the message
the shape Google's own invitations have (multipart/mixed > multipart/alternative of
text/plain + `text/calendar; method=REQUEST`, then the .ics attached), which is what
Gmail, Outlook and Apple Mail turn into their own Yes / Maybe / No buttons; the body
carries the same three choices as one-tap links to `/i/<token>` (no sign-in; the
token is the capability, as `/c/` and `/e/` links are), and `/i/<token>.ics` is a copy
for any calendar program. An invited address that is an account here gets a
read-only event share at once, so the event sits in their calendar and their
reminders follow the shared-reminder switch; the editor and the peek offer them
Yes / Maybe / No. Answers sent by a mail program (a `METHOD:REPLY` part) are read by
the block-link milter on the mail pool into `calendar.itip_inbox`; the runner
applies them. Free/busy for accounts here (`GET /api/freebusy`): bare busy
intervals from the person's own calendars, no titles. No counter-proposals (by
decision, 2026-11-15; maybe later).

## The page on a phone (0.3.2)

Under the shared theme's 860px breakpoint the sidebar is a drawer (`#cal-side`
with class `open`, backdrop `#side-backdrop`), not the theme's sideways strip:
it keeps its column and headings, slides in over the grid, and closes on a tap
outside, the x, or Escape. The action row `#cal-actions` above the grid is
phone-only and carries twins of the sidebar's controls: the drawer toggle,
Search (the search dialog has its own box, `#q2`), the suggestions pill while
there are any, and New event. The sidebar's own New event, search box and
Suggestions button are hidden in the drawer (`.cal-side__twin`). The row, the
drawer head and the backdrop are `display: none` on a wide screen, so nothing
there is invisible but clickable. The breakpoint is the theme's, on purpose:
the drawer takes over exactly where the strip would have appeared.

Dialogs are capped at `100dvh` (0.4.3), the height of the part of the window the
phone's browser is not covering with its own bars, with a `100vh` line before it
for old browsers. `100vh` on Android and iOS is the height with every bar hidden,
so the editor, centred on the screen, stuck out under Brave's bottom bars and its
Delete / Save / Cancel could not be reached. Never size a fixed box with `100vh`.

## Install

Pool on prod-homelab50/51/52 via `install-orchestrators/calendar-orchestrate.sh`
(the tier-3 role runbook run from the workstation, one shared role, node 1's
config copied with `registry.host` rewritten) after
`install-orchestrators/web-name-provision.sh calendar.mailmasker.org 2519 50 51 52`
has put the name, certificate, vhost (all three edges) and the SSO client in
place. Later upgrades: `pkg-upgrade.sh homelab-calendar 50 51 52`.

## Tests

`prove -I lib t/` : `recurrence.t` (rules, DST, windows), `ics.t` (both ICS
shapes parsed back), `access.t` (who may do what), `basic.t` (start-up checks,
sign-in, CSRF, the bundle; no database), `js.t` (the page script's pure
helpers under gjs; skips where gjs is missing). Data paths are proven against
the live pool from offsite as the test account (the tracker item's checklist).
