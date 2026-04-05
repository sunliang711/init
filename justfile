set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

verify:
    bash bootstrap/verify.sh

syntax:
    bash bootstrap/verify.sh syntax

smoke:
    bash bootstrap/verify.sh smoke

integration:
    bash bootstrap/verify.sh integration

fmt-check:
    bash bootstrap/verify.sh fmt-check

fmt:
    bash bootstrap/verify.sh fmt

hooks:
    pre-commit install

bats:
    if command -v bats >/dev/null 2>&1; then bats tests; else echo "bats is not installed"; exit 1; fi
