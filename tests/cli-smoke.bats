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

@test "sdctl help documents dump command" {
    run bash "${REPO_ROOT}/bin/sdctl" help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dump SRC_NAME DST_NAME"* ]]
    [[ "${output}" == *"/lib/systemd/system"* ]]
    [[ "${output}" == *"/usr/lib/systemd/system"* ]]
}

@test "consul-manager help lists install and nomad-jwt" {
    run "${REPO_ROOT}/tools/consul/consul-manager" help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"install"* ]]
    [[ "${output}" == *"nomad-jwt"* ]]
}

@test "consul-manager install help documents the acl flag" {
    run "${REPO_ROOT}/tools/consul/consul-manager" install --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--no-acl"* ]]
    [[ "${output}" == *"--acl-default-policy"* ]]
}

@test "consul-manager uninstall dry-run prints a plan without changing files" {
    run "${REPO_ROOT}/tools/consul/consul-manager" uninstall --dry-run

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Consul uninstall plan:"* ]]
    [[ "${output}" == *"/opt/consul/data/consul"* ]]
}

@test "nomad-manager consul help documents setup-local and token" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" consul --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-local"* ]]
    [[ "${output}" == *"token"* ]]
}
