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

@test "nomad-manager help groups commands by usage stage" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1. Set up the node"* ]]
    [[ "${output}" == *"2. Enable capabilities"* ]]
    [[ "${output}" == *"3. Provide resources to jobs"* ]]
    [[ "${output}" == *"4. Tune the node"* ]]
    [[ "${output}" == *"5. Run jobs"* ]]
    [[ "${output}" == *"6. Maintain and remove"* ]]
    [[ "${output}" == *"7. Learn"* ]]
}

@test "nomad-manager vault jwt replaces the vault-jwt command" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" vault jwt --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"apply"* ]]

    run "${REPO_ROOT}/tools/nomad/nomad-manager" vault-jwt --help
    [ "${status}" -ne 0 ]
}

@test "nomad-manager docker no longer duplicates the driver denylist" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" docker --help

    [ "${status}" -eq 0 ]
    [[ "${output}" != *"disable-driver"* ]]
    [[ "${output}" != *"enable-driver"* ]]
}

@test "consul-manager help groups commands by usage stage" {
    run "${REPO_ROOT}/tools/consul/consul-manager" --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1. Set up the node"* ]]
    [[ "${output}" == *"2. Connect Nomad"* ]]
    [[ "${output}" == *"3. Tune the node"* ]]
    [[ "${output}" == *"4. Maintain and remove"* ]]
    [[ "${output}" == *"5. Learn"* ]]
}

@test "consul-manager nomad-jwt uses doctor instead of status" {
    run "${REPO_ROOT}/tools/consul/consul-manager" nomad-jwt --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doctor"* ]]
    [[ "${output}" != *"status"* ]]
}

@test "manager command groups stay in sync with the parsers" {
    run python3 "${REPO_ROOT}/tests/test_manager_command_groups.py"

    [ "${status}" -eq 0 ]
}

@test "nomad-manager doctor reads managed config values" {
    run python3 "${REPO_ROOT}/tests/test_nomad_manager_doctor.py"

    [ "${status}" -eq 0 ]
}

@test "nomad-manager status shows the effective configuration" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" status

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Managed configuration:"* ]]
    [[ "${output}" == *"Host volumes:"* ]]
    [[ "${output}" == *"Client meta:"* ]]
}

@test "nomad-manager doctor reports node and host volume sections" {
    run "${REPO_ROOT}/tools/nomad/nomad-manager" doctor

    [[ "${output}" == *"Node runtime:"* ]]
    [[ "${output}" == *"Node configuration:"* ]]
    [[ "${output}" == *"Host volumes:"* ]]
}

@test "consul-manager doctor reads managed config values" {
    run python3 "${REPO_ROOT}/tests/test_consul_manager_doctor.py"

    [ "${status}" -eq 0 ]
}

@test "consul-manager status shows the effective configuration" {
    run "${REPO_ROOT}/tools/consul/consul-manager" status

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Base configuration:"* ]]
    [[ "${output}" == *"Managed configuration:"* ]]
    [[ "${output}" == *"Nomad integration:"* ]]
}

@test "consul-manager doctor reports runtime and base config sections" {
    run "${REPO_ROOT}/tools/consul/consul-manager" doctor

    [[ "${output}" == *"Node runtime:"* ]]
    [[ "${output}" == *"Base configuration:"* ]]
}

@test "managers refuse to update from their own installed copy" {
    run python3 "${REPO_ROOT}/tests/test_manager_tool_source.py"

    [ "${status}" -eq 0 ]
}

@test "vault-manager help groups commands by usage stage" {
    run "${REPO_ROOT}/tools/vault/vault-manager" --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1. Set up the node"* ]]
    [[ "${output}" == *"2. Bring Vault online"* ]]
    [[ "${output}" == *"3. Configure Vault"* ]]
    [[ "${output}" == *"4. Maintain and remove"* ]]
    [[ "${output}" == *"5. Learn"* ]]
}

@test "vault-manager uninstall dry-run warns about the unseal keys" {
    run "${REPO_ROOT}/tools/vault/vault-manager" uninstall --dry-run --purge

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Vault uninstall plan:"* ]]
    [[ "${output}" == *"destroys the unseal keys and root token"* ]]
}

@test "vault-manager status and doctor report the seal path" {
    run "${REPO_ROOT}/tools/vault/vault-manager" status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Configuration:"* ]]
    [[ "${output}" == *"Init output:"* ]]

    run "${REPO_ROOT}/tools/vault/vault-manager" doctor
    [[ "${output}" == *"Node runtime:"* ]]
    [[ "${output}" == *"Vault state:"* ]]
}

@test "vault-manager logic tests pass" {
    run python3 "${REPO_ROOT}/tests/test_vault_manager.py"

    [ "${status}" -eq 0 ]
}

@test "the bash vault manager is still available under vault-sh" {
    run bash "${REPO_ROOT}/tools/vault-sh/vault-manager" help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Vault manager"* ]]
}
