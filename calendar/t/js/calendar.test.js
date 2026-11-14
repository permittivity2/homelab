// The page script's pure helpers, run by t/js.t under gjs after
// templates/calendar.js.ep (which defines Cal). Prints TAP.
var n = 0;
function ok(cond, name) { n++; print((cond ? 'ok ' : 'not ok ') + n + ' - ' + name); }
function is(got, want, name) {
  var g = JSON.stringify(got), w = JSON.stringify(want);
  ok(g === w, g === w ? name : name + ' -- got ' + g + ', want ' + w);
}

// --- wall clocks: a UTC-coerced Date <-> '2026-11-14T09:05:00' ---
var d = Cal.parseWall('2026-11-14T09:05:07');
is(Cal.wall(d), '2026-11-14T09:05:07', 'parse and format a wall clock');
is(Cal.wallDate(d), '2026-11-14', 'the date part');
is(Cal.wall(Cal.parseWall('2026-11-14')), '2026-11-14T00:00:00', 'a date alone is midnight');
is(Cal.parseWall('garbage'), null, 'garbage is null');
is(Cal.parseWall(''), null, 'empty is null');
is(Cal.addMinutes('2026-11-14T23:30:00', 60), '2026-11-15T00:30:00', 'adding minutes crosses midnight');
is(Cal.addDays('2026-10-31T09:00:00', 1), '2026-11-01T09:00:00', 'adding a day crosses the month (and the DST night, with no hour lost)');
is(Cal.addDays('2026-11-01T00:00:00', -1), '2026-10-31T00:00:00', 'subtracting a day');
is(Cal.minutesBetween('2026-11-14T09:00:00', '2026-11-14T10:30:00'), 90, 'minutes between');
is(Cal.splitWall('2026-11-14T09:05:00'), { date: '2026-11-14', time: '09:05' }, 'split for the two inputs');
is(Cal.joinWall('2026-11-14', '09:05'), '2026-11-14T09:05:00', 'join from the two inputs');
is(Cal.joinWall('2026-11-14', ''), '2026-11-14T00:00:00', 'join with no time is midnight');
is(Cal.joinWall('', '09:05'), '', 'join with no date is nothing');
is(Cal.weekdayOf('2026-11-14'), 6, '2026-11-14 is a Saturday');

// --- display ---
is(Cal.fmtTime('2026-11-14T09:05:00', false), '9:05 AM', '12-hour');
is(Cal.fmtTime('2026-11-14T00:05:00', false), '12:05 AM', '12-hour midnight');
is(Cal.fmtTime('2026-11-14T12:05:00', false), '12:05 PM', '12-hour noon');
is(Cal.fmtTime('2026-11-14T21:05:00', true), '21:05', '24-hour');
is(Cal.fmtDate('2026-11-14'), 'Sat, Nov 14, 2026', 'a date');
is(Cal.fmtRange('2026-11-14T09:00:00', '2026-11-14T10:00:00', false, false), 'Sat, Nov 14, 2026 9:00 AM - 10:00 AM', 'a same-day range');
is(Cal.fmtRange('2026-11-14T22:00:00', '2026-11-15T01:00:00', false, true), 'Sat, Nov 14, 2026 22:00 - Sun, Nov 15, 2026 01:00', 'a range over midnight');
is(Cal.fmtRange('2026-11-14T00:00:00', '2026-11-15T00:00:00', true), 'Sat, Nov 14, 2026', 'a one-day all-day event (exclusive end)');
is(Cal.fmtRange('2026-11-20T00:00:00', '2026-11-22T00:00:00', true), 'Fri, Nov 20 - Sat, Nov 21, 2026', 'a two-day all-day event shows its last day');

// --- repeat summaries ---
is(Cal.repeatSummary(null), 'Does not repeat', 'no rule');
is(Cal.repeatSummary({ freq: 'daily', interval: 1 }), 'Daily', 'daily');
is(Cal.repeatSummary({ freq: 'daily', interval: 2 }), 'Every 2 days', 'every 2 days');
is(Cal.repeatSummary({ freq: 'weekly', interval: 1, byday: ['MO', 'WE'] }), 'Weekly on Mon, Wed', 'weekly on days');
is(Cal.repeatSummary({ freq: 'weekly', interval: 1, byday: [] }, '2026-11-14T09:00:00'), 'Weekly on Sat', 'weekly with no days ticked: the start day');
is(Cal.repeatSummary({ freq: 'weekly', interval: 3, byday: ['FR'], until: '2026-12-31' }), 'Every 3 weeks on Fri, until Thu, Dec 31, 2026', 'interval and until');
is(Cal.repeatSummary({ freq: 'monthly', interval: 1, monthly_by: 'monthday' }, '2026-11-14T09:00:00'), 'Monthly on day 14', 'monthly by date');
is(Cal.repeatSummary({ freq: 'monthly', interval: 1, monthly_by: 'weekday' }, '2026-11-10T09:00:00'), 'Monthly on the second Tuesday', 'monthly by weekday');
is(Cal.repeatSummary({ freq: 'monthly', interval: 1, monthly_by: 'weekday' }, '2026-10-30T09:00:00'), 'Monthly on the last Friday', 'a 5th weekday is "the last"');
is(Cal.repeatSummary({ freq: 'yearly', interval: 1, count: 1 }, '2026-02-14T09:00:00'), 'Yearly on Feb 14, 1 time', 'yearly with a count of one');
is(Cal.repeatSummary({ freq: 'daily', interval: 1, count: 10 }), 'Daily, 10 times', 'a count');
is(Cal.repeatSummary({ freq: 'hourly', interval: 1 }), '', 'an unknown frequency: nothing');
is(Cal.ordinal(1), 'first', 'ordinal 1');
is(Cal.ordinal(-1), 'last', 'ordinal -1');

// --- views ---
is(Cal.viewName('month'), 'dayGridMonth', 'month view');
is(Cal.viewName('agenda'), 'listWeek', 'agenda view');
is(Cal.viewName('nonsense'), 'dayGridMonth', 'unknown falls back to month');
is(Cal.WEEKDAYS, ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'], 'weekday codes in RFC 5545 order from Sunday');
ok(Cal.ZONES.indexOf('America/Chicago') === 0, 'Chicago leads the zone list');

print('1..' + n);
