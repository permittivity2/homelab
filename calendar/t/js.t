use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(path tempdir);

# The page script's pure helpers (wall clocks, repeat summaries, formatting),
# run under gjs with t/js/calendar.test.js, which prints TAP. Skips where gjs
# is not installed (CI); run it on the workstation.

my $gjs = (grep { -x "$_/gjs" } split /:/, $ENV{PATH} // '')[0];
plan skip_all => 'gjs is not installed' unless $gjs;

my $script = path('templates/calendar.js.ep')->slurp;
unlike $script, qr/^\s*%|<%/m, 'calendar.js.ep has no template syntax in it';

my $dir = tempdir;
my $file = $dir->child('run.js');
# No window/document under gjs: give the script just enough to load.
$file->spew("var window = {}; var document = { addEventListener: function () {} };\n" . $script . "\n" . path('t/js/calendar.test.js')->slurp);

my $out = `"$gjs/gjs" "$file" 2>&1`;
is $?, 0, 'gjs ran the script and its tests' or diag $out;

my ($plan) = $out =~ /^1\.\.(\d+)$/m;
ok $plan, 'the JavaScript tests printed a plan' or diag $out;
my $seen = 0;
for my $line (split /\n/, $out) {
    next unless $line =~ /^(not )?ok \d+ - (.*)$/;
    $seen++;
    ok !$1, "js: $2";
}
is $seen, $plan, 'every planned JavaScript test reported';

done_testing;
