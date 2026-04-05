#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
}

@test "install.sh help exits successfully" {
    run bash "${REPO_ROOT}/install.sh" help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Commands:"* ]]
}

@test "install.sh components lists update component" {
    run bash "${REPO_ROOT}/install.sh" components

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"update"* ]]
}
