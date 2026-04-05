#!/bin/sh
set -eu

max_kb="${1:-2048}"
allow_regex="${2:-}"

path_is_allowed() {
    local path="${1:?missing path}"

    [ -n "${allow_regex}" ] || return 1
    printf '%s\n' "${path}" | grep -Eq -- "${allow_regex}"
}

case "${max_kb}" in
    ''|*[!0-9]*)
        echo "Usage: $0 [max-kb] [allow-regex]" >&2
        exit 2
        ;;
esac

too_large_paths=""

while IFS= read -r path; do
    [ -n "${path}" ] || continue
    if path_is_allowed "${path}"; then
        continue
    fi

    size_bytes="$(git cat-file -s ":${path}")"
    size_kb="$(((size_bytes + 1023) / 1024))"

    if [ "${size_kb}" -gt "${max_kb}" ]; then
        too_large_paths="${too_large_paths}${path} (${size_kb} KB)\n"
    fi
done <<EOF
$(git diff --cached --name-only --diff-filter=AM --)
EOF

if [ -n "${too_large_paths}" ]; then
    printf 'Files larger than %s KB are staged for commit:\n' "${max_kb}" >&2
    printf '%b' "${too_large_paths}" >&2
    echo "Commit blocked. Reduce the file size, add a repository-specific allowlist, or use another storage path." >&2
    exit 1
fi
