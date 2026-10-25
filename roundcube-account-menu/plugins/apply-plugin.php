<?php
/**
 * homelab-roundcube-account-menu's own postinst helper: idempotently
 * adds 'homelab_account_menu' to an ALREADY-WRITTEN
 * /etc/roundcube/config.inc.php's $config['plugins'] array. A dedicated
 * PHP script instead of a sed/shell one-liner (same reasoning as
 * homelab-roundcube-invite's identical helper): PHP array syntax
 * (arbitrary existing entries, single vs double quotes, whitespace) is
 * exactly the kind of thing a regex mangles silently on some but not
 * all real config.inc.php shapes, and PHP itself is guaranteed present
 * on any host running php-fpm/roundcube, so there is no reason to reach
 * for a less precise tool.
 *
 * Usage: php apply-plugin.php /etc/roundcube/config.inc.php
 * Exit 0 + prints ALREADY_PRESENT: no change needed, config untouched.
 * Exit 0 + prints EDITED: config.inc.php rewritten in place.
 * Exit 1 + message on stderr: plugins array not found in the expected
 * shape (the postinst caller is responsible for NOT treating this as
 * fatal to the whole apt transaction -- see debian/postinst).
 *
 * Deliberately does NOT write the file back if $config['plugins'] is not
 * found in the expected single-statement-assignment shape (e.g. someone
 * hand-edited it into something exotic) -- failing loud and leaving the
 * file untouched is safer than a best-effort guess that could corrupt a
 * working Roundcube install.
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

if (preg_match('/[\'"]homelab_account_menu[\'"]/', $m[2])) {
    echo "ALREADY_PRESENT\n";
    exit(0);
}

$inner = trim($m[2]);
$new_inner = ($inner === '') ? "'homelab_account_menu'" : $inner . ", 'homelab_account_menu'";
$new_content = preg_replace($pattern, '${1}' . $new_inner . '${3}', $content, 1);

if (file_put_contents($file, $new_content) === false) {
    fwrite(STDERR, "failed to write $file\n");
    exit(1);
}

echo "EDITED\n";
exit(0);
