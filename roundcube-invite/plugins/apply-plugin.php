<?php
/**
 * homelab-roundcube-invite's own postinst helper: idempotently adds
 * 'invite_sender' to an ALREADY-WRITTEN /etc/roundcube/config.inc.php's
 * $config['plugins'] array. A dedicated PHP script instead of a sed/
 * shell one-liner -- see README.md's "Why a PHP script, not sed"
 * section: PHP array syntax (arbitrary existing entries, single vs
 * double quotes, whitespace) is exactly the kind of thing a regex
 * mangles silently on some but not all real config.inc.php shapes, and
 * PHP itself is a guaranteed-present tool on any host running
 * php-fpm/roundcube, so there's no reason to reach for a less precise
 * one.
 *
 * Usage: php apply-plugin.php /etc/roundcube/config.inc.php
 * Exit 0 + prints ALREADY_PRESENT: no change needed, config untouched.
 * Exit 0 + prints EDITED: config.inc.php rewritten in place.
 * Exit 1 + message on stderr: plugins array not found in the expected
 * shape (postinst's own caller is responsible for NOT treating this as
 * fatal to the whole apt transaction -- see debian/postinst).
 *
 * Deliberately does NOT write the file back if $config['plugins'] isn't
 * found in the expected single-statement-assignment shape at all
 * (e.g. someone hand-edited it into something exotic) -- failing loud
 * and leaving the file untouched is safer than a best-effort guess that
 * could corrupt a working Roundcube install.
 */

if ($argc < 2) {
    fwrite(STDERR, "usage: php apply-plugin.php /path/to/config.inc.php\n");
    exit(1);
}

$file = $argv[1];
if (!is_readable($file)) {
    fwrite(STDERR, "cannot read $file\n");
    exit(1);
}
$content = file_get_contents($file);

$pattern = '/(\$config\[[\'"]plugins[\'"]\]\s*=\s*\[)([^\]]*)(\]\s*;)/';
if (!preg_match($pattern, $content, $m)) {
    fwrite(STDERR, "\$config['plugins'] = [...]; not found in $file in the expected shape\n");
    exit(1);
}

if (preg_match('/[\'"]invite_sender[\'"]/', $m[2])) {
    echo "ALREADY_PRESENT\n";
    exit(0);
}

$inner = trim($m[2]);
$new_inner = ($inner === '') ? "'invite_sender'" : $inner . ", 'invite_sender'";
$new_content = preg_replace($pattern, '${1}' . $new_inner . '${3}', $content, 1);

if (file_put_contents($file, $new_content) === false) {
    fwrite(STDERR, "failed to write $file\n");
    exit(1);
}

echo "EDITED\n";
exit(0);
