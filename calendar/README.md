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
(`timeZone=`), which is the account's zone when homelab-api carries one (phase
2 of the plan), else this app's saved preference (the browser's zone, saved on
the first visit), else `calendar.default_timezone`.

## Routes

Signed in (session cookie; writes carry `X-CSRF-Token`): `/`, `/login`,
`/oauth/callback`, `POST /logout`; `/api/calendars` (GET, POST), `/api/calendars/:id`
(PATCH), `/api/calendars/:id/delete` (POST), `/api/calendars/:id/visible` (PUT),
`/api/calendars/:id/shares` (GET, POST), `/api/calendars/:id/export.ics`;
`/api/events?start&end&timeZone`, `POST /api/events`, `/api/events/:id` (GET with
`recurrence_id`, PATCH with `scope` = all | this | following), `/api/events/:id/delete`
(POST, same scope), `/api/events/:id/shares` (GET, POST), `/api/shares/:id/revoke`
(POST), `/api/prefs` (GET, PUT). Public: `/c/:token[.ics]`, `/c/:token/events`,
`/e/:token[.ics]`, `/health`. Nothing is gateway-fronted yet (phase 3 adds
`/api/v1/calendar/account` for myaccount's consent switch).

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
