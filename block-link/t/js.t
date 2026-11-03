use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(path tempdir);

# The block list's sort and filter rules, which run in the visitor's browser.
# The page's script (templates/blocklist.js.ep) is plain JavaScript with no
# template tags, so it is run here as-is under gjs, followed by
# t/js/blocklist.test.js, which prints TAP. Skips where gjs is not installed
# (CI runners); run it on the workstation, which has it.

my $gjs = (grep { -x "$_/gjs" } split /:/, $ENV{PATH} // '')[0];
plan skip_all => 'gjs is not installed' unless $gjs;

my $script = path('templates/blocklist.js.ep')->slurp;
# The template engine treats a line starting with % (after any spaces) as
# Perl and <% as a tag. Either would change the script the browser gets.
unlike $script, qr/^\s*%|<%/m, 'blocklist.js.ep has no template syntax in it';

my $dir = tempdir;
my $file = $dir->child('run.js');
$file->spew($script . "\n" . path('t/js/blocklist.test.js')->slurp);

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
