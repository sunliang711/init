#!/bin/sh
set -eu

allow_regex="${1:-}"

path_is_allowed() {
    local path="${1:?missing path}"

    [ -n "${allow_regex}" ] || return 1
    printf '%s\n' "${path}" | grep -Eq -- "${allow_regex}"
}

binary_paths="$(
    git diff --cached --numstat --diff-filter=AM -- |
        awk -F '\t' '$1 == "-" && $2 == "-" { print $3 }' |
        while IFS= read -r path; do
            [ -n "${path}" ] || continue
            if ! path_is_allowed "${path}"; then
                printf '%s\n' "${path}"
            fi
        done
)"

if [ -n "${binary_paths}" ]; then
    echo "Binary files are staged for commit:" >&2
    printf '%s\n' "${binary_paths}" >&2
    echo "Commit blocked. Move them to Git LFS, an artifact store, or add an explicit allowlist." >&2
    exit 1
fi
