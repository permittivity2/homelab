#!/usr/bin/env python3
"""Targeted line-level editor for config.yml that preserves comments/layout.

Only understands the fixed structure of config.example.yml (top-level keys,
and one level of nesting). Used by install.sh to fill in blanks
interactively without doing a full YAML load/dump (which would strip the
documentation comments).
"""

import sys


def _iter_key_paths(lines):
    stack = []  # list of (indent, key)
    for i, raw in enumerate(lines):
        stripped = raw.rstrip("\n")
        content = stripped.strip()
        if not content or content.startswith("#"):
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        if ":" not in content:
            continue
        key = content.split(":", 1)[0].strip().strip('"').strip("'")
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path = tuple(k for _, k in stack) + (key,)
        stack.append((indent, key))
        yield i, indent, path


def find_line(lines, path):
    path = tuple(path)
    for i, indent, p in _iter_key_paths(lines):
        if p == path:
            return i, indent
    return None, None


def find_insertion_point(lines, path):
    """For a key that doesn't exist yet (e.g. a field added in a newer
    config.example.yml than the one a deployed config.yml was copied
    from), find where to insert it: right after its parent's own line,
    at the end of the parent's existing children. Top-level keys with
    no parent are appended at end of file."""
    parent_path = tuple(path[:-1])
    if not parent_path:
        return len(lines), 0
    parent_i, parent_indent = find_line(lines, parent_path)
    if parent_i is None:
        if len(parent_path) > 1:
            # This editor only understands one level of nesting -- a
            # missing grandparent means the file isn't shaped the way
            # this tool expects at all, not something to paper over.
            return None, None
        # The top-level section itself doesn't exist yet -- e.g. a
        # host migrated forward from the pre-redesign package, whose
        # config.yml predates the homelab_cli: block entirely. Append
        # a brand-new section rather than failing outright: this used
        # to crash `setup` with "key not found and parent path missing"
        # on every such host, since there was no way to create a
        # missing parent, only insert under an existing one.
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.append(f"{parent_path[0]}:\n")
        return len(lines), 2
    item_indent = parent_indent + 2
    j = parent_i + 1
    while j < len(lines):
        stripped = lines[j].rstrip("\n")
        if stripped.strip() and not stripped.strip().startswith("#"):
            cur_indent = len(stripped) - len(stripped.lstrip(" "))
            if cur_indent < item_indent:
                break
        j += 1
    return j, item_indent


# Old field names, from before the borg_backup_server -> backup_server
# rename (see CLAUDE.md/the redesign plan's config-path migration
# section). A config.yml copied forward from the legacy package via
# install.sh's migrate_legacy_config_dir() still uses these until the
# admin re-runs `setup`; this fallback keeps cfg_get() from silently
# returning "" for it in the meantime. One release cycle only.
_LEGACY_KEY_ALIASES = {
    ("backup_server",): ("borgbackup_server",),
    ("ssh_backup_server_username",): ("ssh_borgbackup_server_username",),
    ("backup_server_location",): ("borgbackup_server_backup_location",),
}


def cmd_get(path_file, keys):
    with open(path_file) as f:
        lines = f.readlines()
    i, _ = find_line(lines, keys)
    if i is None:
        legacy = _LEGACY_KEY_ALIASES.get(tuple(keys))
        if legacy:
            i, _ = find_line(lines, legacy)
        if i is None:
            print("")
            return
    value = lines[i].split(":", 1)[1].strip()
    value = value.strip('"').strip("'")
    if value in ("[]", "{}", "~", "null", "None"):
        value = ""
    print(value)


def cmd_get_list(path_file, keys):
    with open(path_file) as f:
        lines = f.readlines()
    i, indent = find_line(lines, keys)
    if i is None:
        return
    value = lines[i].split(":", 1)[1].strip()
    if value and value != "[]":
        # Inline list on the key's own line, e.g. `key: [1, 2]` — not a
        # format we write ourselves, but tolerate it if hand-edited.
        for item in value.strip("[]").split(","):
            item = item.strip().strip('"').strip("'")
            if item:
                print(item)
        return
    item_indent = indent + 2
    for line in lines[i + 1:]:
        stripped = line.rstrip("\n")
        if not stripped.strip():
            continue
        cur_indent = len(stripped) - len(stripped.lstrip(" "))
        if cur_indent < item_indent or not stripped.strip().startswith("-"):
            break
        item = stripped.strip()[1:].strip().strip('"').strip("'")
        if item:
            print(item)


def _locate_or_insert(lines, keys):
    """Return (index, indent, replacing) for a key: (index, indent) of the
    existing line to overwrite if found, or an insertion point (with
    replacing=False) if the key is missing — e.g. a field added to
    config.example.yml after this config.yml was first copied from it."""
    i, indent = find_line(lines, keys)
    if i is not None:
        return i, indent, True
    i, indent = find_insertion_point(lines, keys)
    if i is None:
        sys.exit(f"key not found and parent path missing: {'.'.join(keys)}")
    return i, indent, False


def cmd_set_scalar(path_file, keys, value):
    with open(path_file) as f:
        lines = f.readlines()
    i, indent, replacing = _locate_or_insert(lines, keys)
    key = keys[-1]
    escaped = value.replace('"', '\\"')
    new_line = f'{" " * indent}{key}: "{escaped}"\n'
    if replacing:
        lines[i] = new_line
    else:
        lines.insert(i, new_line)
    with open(path_file, "w") as f:
        f.writelines(lines)


def cmd_set_list(path_file, keys, items):
    with open(path_file) as f:
        lines = f.readlines()
    i, indent, replacing = _locate_or_insert(lines, keys)
    key = keys[-1]
    if not items:
        block = [f'{" " * indent}{key}: []\n']
    else:
        block = [f'{" " * indent}{key}:\n']
        for item in items:
            escaped = item.replace('"', '\\"')
            block.append(f'{" " * (indent + 2)}- "{escaped}"\n')
    if replacing:
        lines[i:i + 1] = block
    else:
        lines[i:i] = block
    with open(path_file, "w") as f:
        f.writelines(lines)


def cmd_set_databases(path_file, keys, entries):
    """entries: list of 'type:name:dump_dir' strings."""
    with open(path_file) as f:
        lines = f.readlines()
    i, indent, replacing = _locate_or_insert(lines, keys)
    key = keys[-1]
    if not entries:
        block = [f'{" " * indent}{key}: []\n']
    else:
        block = [f'{" " * indent}{key}:\n']
        item_indent = " " * (indent + 2)
        field_indent = " " * (indent + 4)
        for entry in entries:
            db_type, name, dump_dir = entry.split(":", 2)
            block.append(f'{item_indent}- type: "{db_type}"\n')
            block.append(f'{field_indent}name: "{name}"\n')
            block.append(f'{field_indent}dump_dir: "{dump_dir}"\n')
    if replacing:
        lines[i:i + 1] = block
    else:
        lines[i:i] = block
    with open(path_file, "w") as f:
        f.writelines(lines)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(
            "usage: configedit.py get|set-scalar|set-list|set-databases "
            "<config-path> <dot.key.path> [values...]"
        )
    action, path_file = args[0], args[1]
    rest = args[2:]

    if action == "get":
        keys = rest[0].split(".")
        cmd_get(path_file, keys)
    elif action == "get-list":
        keys = rest[0].split(".")
        cmd_get_list(path_file, keys)
    elif action == "set-scalar":
        keys = rest[0].split(".")
        cmd_set_scalar(path_file, keys, rest[1] if len(rest) > 1 else "")
    elif action == "set-list":
        keys = rest[0].split(".")
        cmd_set_list(path_file, keys, rest[1:])
    elif action == "set-databases":
        keys = rest[0].split(".")
        cmd_set_databases(path_file, keys, rest[1:])
    else:
        sys.exit(f"unknown action: {action}")


if __name__ == "__main__":
    main()
