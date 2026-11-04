// The block list's sort and filter rules, run by t/js.t under gjs after
// templates/blocklist.js.ep (which defines BlockList). Prints TAP.
var n = 0;
function ok(cond, name) { n++; print((cond ? 'ok ' : 'not ok ') + n + ' - ' + name); }
function is(got, want, name) {
  var g = JSON.stringify(got), w = JSON.stringify(want);
  ok(g === w, g === w ? name : name + ' -- got ' + g + ', want ' + w);
}

var L = ['b@x.org', 'Zed@a.org', 'A@y.org', 'c@a.org', 'a@x.org'];

// --- the four sorts, in the order the button cycles through them ---
is(BlockList.SORTS.map(function (s) { return s.label; }),
   ['A → Z', 'Z → A', 'Domain A → Z', 'Domain Z → A'], 'four sorts, in cycle order');
is(BlockList.sorted(L, 0), ['a@x.org', 'A@y.org', 'b@x.org', 'c@a.org', 'Zed@a.org'], 'A to Z ignores case');
is(BlockList.sorted(L, 1), ['Zed@a.org', 'c@a.org', 'b@x.org', 'A@y.org', 'a@x.org'], 'Z to A is the exact reverse');
is(BlockList.sorted(L, 2), ['c@a.org', 'Zed@a.org', 'a@x.org', 'b@x.org', 'A@y.org'], 'by domain, then by the part before the @');
is(BlockList.sorted(L, 3), ['A@y.org', 'b@x.org', 'a@x.org', 'Zed@a.org', 'c@a.org'], 'by domain, reversed');
is(BlockList.sorted(['B@x.org', 'b@x.org'], 0), ['B@x.org', 'b@x.org'], 'same address in two cases: a stable, exact-text tiebreak');
is(L, ['b@x.org', 'Zed@a.org', 'A@y.org', 'c@a.org', 'a@x.org'], 'sorting never reorders the list it was given');
is(BlockList.sortKey('Shop@Sub.Example.COM', 'domain'), 'sub.example.com\u0000shop', 'the domain key is lowercased domain, then local part');
is(BlockList.sortKey('a@b@c.org', 'domain'), 'c.org\u0000a@b', 'the domain is after the LAST @');

// --- the filter: nothing below 3 characters ---
is(BlockList.filtered(L, ''), L, 'empty filter: the whole list');
is(BlockList.filtered(L, 'ab'), L, 'two characters: still the whole list');
is(BlockList.filtered(L, '  a@'), L, 'leading spaces do not count towards the three');
is(BlockList.filtered(L, 'a.o'), ['Zed@a.org', 'c@a.org'], 'three characters: filters, as a regex (. is any character)');

// --- Perl regex, case-insensitive ---
is(BlockList.filtered(L, '^ZED'), ['Zed@a.org'], 'ignores case');
is(BlockList.filtered(L, '@x\\.org$'), ['b@x.org', 'a@x.org'], 'anchors and an escaped dot');
is(BlockList.filtered(L, '^(a|b)@'), ['b@x.org', 'A@y.org', 'a@x.org'], 'groups and alternation');
is(BlockList.filtered(L, '\\Ac@'), ['c@a.org'], 'Perl \\A means start of string');
is(BlockList.filtered(L, 'y\\.org\\z'), ['A@y.org'], 'Perl \\z means end of string');
is(BlockList.filtered(L, 'x\\.org\\Z'), ['b@x.org', 'a@x.org'], 'Perl \\Z means end of string too');
is(BlockList.filtered(L, '(?i)zed'), ['Zed@a.org'], 'a leading (?i) is accepted and dropped');
is(BlockList.filtered(['a@b.org', 'A@b.org', 'xA@b.org'], '[\\A]@b'), ['a@b.org', 'A@b.org', 'xA@b.org'],
   'inside a [...] class \\A is left alone (not turned into ^)');
is(BlockList.filtered(L, '\\\\A'), [], 'an escaped backslash before A is not an anchor');
is(BlockList.filtered(['shop1@a.org', 'shop22@a.org', 'shop@a.org'], 'shop\\d{2}'), ['shop22@a.org'], 'classes and counted repeats');
is(BlockList.filtered(['ab@x.org', 'ac@x.org'], 'a(?=c)'), ['ac@x.org'], 'lookahead');

// --- a pattern that is not usable yet ---
var bad = BlockList.compileFilter('shop[');
is(bad.error, true, 'an unfinished pattern is reported as an error');
is(bad.re, null, '... with no regex');
is(BlockList.filtered(L, 'shop['), L, '... and the whole list stays visible');
is(BlockList.compileFilter('a++b').error, true, 'a possessive quantifier (Perl-only) is reported, not silently mangled');
is(BlockList.compileFilter('ab').error, false, 'a short text is not an error, just not a filter yet');

// --- unblocking: the list without an address, ignoring case ---
is(BlockList.contains(L, 'ZED@A.ORG'), true, 'contains ignores case');
is(BlockList.contains(L, 'zed@a.or'), false, '... and matches whole addresses only');
is(BlockList.without(L, 'zed@A.org'), ['b@x.org', 'A@y.org', 'c@a.org', 'a@x.org'], 'without drops it, whatever its case');
is(BlockList.without(['B@x.org', 'b@x.org', 'c@x.org'], 'b@X.org'), ['c@x.org'], '... every spelling of it');
is(BlockList.without(L, 'nobody@x.org'), L, '... and leaves the list alone when it is not there');
is(L, ['b@x.org', 'Zed@a.org', 'A@y.org', 'c@a.org', 'a@x.org'], 'without never changes the list it was given');
ok(/^Unblock a@b\.org\?\n\nMail sent to it will be delivered to you again\.$/.test(BlockList.confirmText('a@b.org')),
   'the fallback confirm box asks the same question as the dialog');

print('1..' + n);
