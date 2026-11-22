use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Homelab::Worker::JobType::HtmlPdf;

# The html_pdf job type (post-cutover #101): what it refuses (runs in CI), and
# a real layout when WeasyPrint is installed (the worker nodes; skipped
# elsewhere).
my $r = \&Homelab::Worker::JobType::HtmlPdf::html_refusal;
is($r->('<!doctype html><html><body><p>hi</p><img src="data:image/gif;base64,R0lGOD" alt="x"></body></html>'), '', 'a self-contained document is allowed');
like($r->(undef), qr/string/, 'undef is refused');
like($r->({}), qr/string/, 'a reference is refused');
like($r->("  \n"), qr/empty/, 'an empty document is refused');
like($r->('x' x (4 * 1024 * 1024 + 1)), qr/too large/, 'over 4 MB is refused');
like($r->('<p><img src="https://drive.mailmasker.org/x.png"></p>'), qr/src may only be a data: URL/, 'an https image is refused (the caller inlines what it wants shown)');
like($r->('<p><img src="http://10.50.2.150:2379/version"></p>'), qr/src may only/, '... so a fleet address can never be fetched from the worker node');
like($r->('<link rel="stylesheet" href="https://static.mailmasker.org/theme/v1/theme.css">'), qr/<link>/, 'a stylesheet link is refused');
like($r->('<script>1</script>'), qr/<script>/, 'script is refused');
like($r->('<iframe src="data:text/html,hi"></iframe>'), qr/<iframe>/, 'an iframe is refused even with data:');
like($r->('<p style="background: url(https://x.example/a.png)">x</p>'), qr/style attribute/, 'url() in a style attribute is refused');
is($r->('<p style="background: url(data:image/png;base64,AAA)">x</p>'), '', '... a data: url() in one is fine');
like($r->('<style>@import "https://x.example/a.css";</style><p>x</p>'), qr/stylesheet in the document/, '@import in a style element is refused');
like($r->('<style>body { background: url("https://x.example/a.png") }</style>'), qr/stylesheet in the document/, 'url() in a style element is refused');
is($r->('<style>@page { size: Letter; margin: 2cm } body { font-family: Inter }</style><p>x</p>'), '', 'a plain stylesheet is fine');
like($r->('<video poster="https://x.example/p.jpg"></video>'), qr/poster may only/, 'a poster is checked too');

SKIP: {
    skip 'weasyprint is not installed here', 4 unless grep { -x "$_/weasyprint" } split /:/, $ENV{PATH};
    my $dir = tempdir(CLEANUP => 1);
    my @progress;
    my $out = Homelab::Worker::JobType::HtmlPdf::run(
        { output_name => 'x.pdf', html => "<!doctype html><html><head><meta charset=\"utf-8\"><title>T</title><style>\@page { size: Letter }</style></head><body><h1>Caf\x{e9} notes</h1><p>Hello.</p></body></html>" },
        $dir, sub { push @progress, [@_] });
    ok(-s $out, 'a PDF is written');
    like(path($out)->slurp, qr/\A%PDF-1\./, '... and it is one');
    is_deeply(\@progress, [[0, 1], [1, 1]], 'progress is reported at start and end');
    eval { Homelab::Worker::JobType::HtmlPdf::run({ html => '<img src="https://x.example/a.png">' }, $dir) };
    like($@, qr/html_pdf job: src may only/, 'run() refuses what html_refusal refuses');
}

done_testing;
