#!/bin/bash

set -e

dir=${1}
if [ -n "${dir}" ];then
    echo "repo path: ${dir}"
    cd "${dir}"
fi

# Check if the repository is clean
if git diff --quiet && git diff --cached --quiet; then
    echo "The repository is clean. Proceeding with git pull."
    git pull
else
    echo "The repository has changes. Aborting git pull."
fi
