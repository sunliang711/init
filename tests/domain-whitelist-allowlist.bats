#!/usr/bin/env bats

# domain-whitelist 白名单解析与 IPv6 掩码的单元测试。
# 脚本尾部有 BASH_SOURCE 守卫，source 进来只加载函数，不会进入命令分发。

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    DWL="${REPO_ROOT}/tools/domain-whitelist/domain-whitelist"
}

# 在独立 bash 里调用被测函数：脚本自带 set -e，
# 出错路径靠它把命令替换里的 die 变成非零退出码。
dwl_call() {
    bash -c 'source "$1"; shift; "$@"' _ "${DWL}" "$@"
}

@test "parse_allowlist_line keeps the legacy bare source format" {
    run dwl_call parse_allowlist_line "example.com"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src=example.com" ]
}

@test "parse_allowlist_line accepts a bare source followed by a family flag" {
    run dwl_call parse_allowlist_line "example.com v4only"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src=example.com v4only" ]
}

@test "parse_allowlist_line normalizes field order" {
    run dwl_call parse_allowlist_line "v4only dport=9100 proto=tcp src=example.com"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src=example.com proto=tcp dport=9100 v4only" ]
}

@test "parse_allowlist_line normalizes a zero-padded v6prefix" {
    run dwl_call parse_allowlist_line "src=example.com v6prefix=064"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src=example.com v6prefix=64" ]
}

@test "parse_allowlist_line rejects two family flags on one line" {
    run dwl_call parse_allowlist_line "src=example.com v4only v6only"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"conflicting family flag"* ]]
}

@test "parse_allowlist_line rejects a family flag written as key=value" {
    run dwl_call parse_allowlist_line "src=example.com v4only=1"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"takes no value"* ]]
}

@test "parse_allowlist_line rejects a family flag on a public port entry" {
    run dwl_call parse_allowlist_line "proto=tcp dport=443 v4only"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"requires 'src'"* ]]
}

@test "parse_allowlist_line rejects a family flag that contradicts the source" {
    run dwl_call parse_allowlist_line "src=203.0.113.10 v6only"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"contradicts the IPv4 source"* ]]
}

@test "parse_allowlist_line rejects v6prefix on a static source" {
    run dwl_call parse_allowlist_line "src=2001:db8::1 v6prefix=64"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"only applies to domain sources"* ]]
}

@test "parse_allowlist_line rejects v6prefix combined with v4only" {
    run dwl_call parse_allowlist_line "src=example.com v6prefix=64 v4only"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"contradicts 'v4only'"* ]]
}

@test "parse_allowlist_line refuses v6prefix=0" {
    run dwl_call parse_allowlist_line "src=example.com v6prefix=0"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"allow every IPv6 source"* ]]
}

@test "parse_allowlist_line rejects an out-of-range v6prefix" {
    run dwl_call parse_allowlist_line "src=example.com v6prefix=129"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"expected 1-128"* ]]
}

@test "parse_allowlist_line points v4prefix at the CIDR syntax" {
    run dwl_call parse_allowlist_line "src=example.com v4prefix=24"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CIDR"* ]]
}

@test "entry_family_field does not match a domain that contains the flag name" {
    run dwl_call entry_family_field "src=v4only.example.com"

    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "entry_src_field ignores trailing flags" {
    run dwl_call entry_src_field "src=example.com v6prefix=64 v4only"

    [ "${status}" -eq 0 ]
    [ "${output}" = "example.com" ]
}

@test "ipv6_mask_to_prefix collapses a host address onto its /64" {
    run dwl_call ipv6_mask_to_prefix "240e:b8f:29f:c200:1234:5678:9abc:def0" 64

    [ "${status}" -eq 0 ]
    [ "${output}" = "240e:b8f:29f:c200::/64" ]
}

@test "ipv6_mask_to_prefix handles a prefix that is not on a group boundary" {
    run dwl_call ipv6_mask_to_prefix "2001:db8:abcd:1234::1" 60

    [ "${status}" -eq 0 ]
    [ "${output}" = "2001:db8:abcd:1230::/60" ]
}

@test "ipv6_mask_to_prefix leaves a single zero group uncompressed" {
    run dwl_call ipv6_mask_to_prefix "1:0:2:3:4:5:6:7" 128

    [ "${status}" -eq 0 ]
    [ "${output}" = "1:0:2:3:4:5:6:7/128" ]
}

@test "ipv6_mask_to_prefix compresses the longest zero run" {
    run dwl_call ipv6_mask_to_prefix "1:0:2:0:0:0:0:3" 128

    [ "${status}" -eq 0 ]
    [ "${output}" = "1:0:2::3/128" ]
}

@test "resolve_source_to_files drops the other family for a static source" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        resolve_source_to_files "203.0.113.10" "${TMP_DIR}/v4" "${TMP_DIR}/v6" "6" ""
        printf "[%s][%s]\n" "$(cat "${TMP_DIR}/v4")" "$(cat "${TMP_DIR}/v6")"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "[][]" ]
}

@test "apply_v6_prefix merges addresses that share a prefix" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "240e:b8f:29f:c200:1::1\n240e:b8f:29f:c200:2::2\n240e:b8f:29f:c201::9\n" >"${TMP_DIR}/v6"
        apply_v6_prefix "${TMP_DIR}/v6" 64
        paste -sd" " - <"${TMP_DIR}/v6"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "240e:b8f:29f:c200::/64 240e:b8f:29f:c201::/64" ]
}

@test "warn_shadowed_port_entries stays quiet when the families are disjoint" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "src=a.example.com v4only\nsrc=a.example.com proto=tcp dport=22 v6only\n" >"${TMP_DIR}/e"
        warn_shadowed_port_entries "${TMP_DIR}/e" 2>&1
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "warn_shadowed_port_entries reports an overlapping full-access entry" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "src=a.example.com v4only\nsrc=a.example.com proto=tcp dport=22 v4only\n" >"${TMP_DIR}/e"
        warn_shadowed_port_entries "${TMP_DIR}/e" 2>&1
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shadowed by a full-access entry"* ]]
}

# 裸条目限定了家族、端口条目没限定时，端口条目的另一半仍然生效。
# 报成完全遮蔽会诱导运维删掉一条活规则，所以措辞必须区分开。
@test "warn_shadowed_port_entries distinguishes a partial shadow" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "src=a.example.com v4only\nsrc=a.example.com proto=tcp dport=22\n" >"${TMP_DIR}/e"
        warn_shadowed_port_entries "${TMP_DIR}/e" 2>&1
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shadowed for IPv4 only"* ]]
    [[ "${output}" != *"is shadowed by a full-access entry"* ]]
}

# 本次改动的主功能：域名解析结果按家族过滤。桩掉 resolve_domain 才能不依赖 DNS。
@test "resolve_source_to_files keeps only the requested family for a domain" {
    run bash -c '
        source "$1"
        resolve_domain() {
            RESOLVE_FOUND=2
            RESOLVE_V4_FAILED=0
            RESOLVE_V6_FAILED=0
            printf "203.0.113.7\n" >>"$2"
            printf "2001:db8::1\n" >>"$3"
        }
        ensure_tmp_dir
        mkdir -p "${TMP_DIR}/dns"
        : >"${TMP_DIR}/resolve.cache.new"
        resolve_source_to_files "a.example.com" "${TMP_DIR}/v4" "${TMP_DIR}/v6" "4" ""
        printf "[%s][%s]" "$(cat "${TMP_DIR}/v4")" "$(cat "${TMP_DIR}/v6")"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "[203.0.113.7][]" ]
}

@test "resolve_source_to_files masks a resolved IPv6 address with v6prefix" {
    run bash -c '
        source "$1"
        resolve_domain() {
            RESOLVE_FOUND=1
            RESOLVE_V4_FAILED=0
            RESOLVE_V6_FAILED=0
            printf "240e:b8f:29f:c200:aaaa:bbbb:cccc:dddd\n" >>"$3"
        }
        ensure_tmp_dir
        mkdir -p "${TMP_DIR}/dns"
        : >"${TMP_DIR}/resolve.cache.new"
        resolve_source_to_files "a.example.com" "${TMP_DIR}/v4" "${TMP_DIR}/v6" "" "64"
        cat "${TMP_DIR}/v6"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "240e:b8f:29f:c200::/64" ]
}

# 家族过滤把一条条目滤空时必须留下日志，否则定时刷新下这条规则静默消失。
@test "resolve_source_to_files logs when the family filter empties an entry" {
    run bash -c '
        source "$1"
        resolve_domain() {
            RESOLVE_FOUND=1
            RESOLVE_V4_FAILED=0
            RESOLVE_V6_FAILED=0
            printf "203.0.113.7\n" >>"$2"
        }
        ensure_tmp_dir
        mkdir -p "${TMP_DIR}/dns"
        : >"${TMP_DIR}/resolve.cache.new"
        resolve_source_to_files "a.example.com" "${TMP_DIR}/v4" "${TMP_DIR}/v6" "6" "" 2>&1
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"removed every resolved address"* ]]
}

# entry_v6prefix_field -> apply_v6_prefix 这条真实接线，不是直接调掩码函数。
@test "resolve_allowlist_to_files wires v6prefix through from the entry" {
    run bash -c '
        source "$1"
        resolve_domain() {
            RESOLVE_FOUND=2
            RESOLVE_V4_FAILED=0
            RESOLVE_V6_FAILED=0
            printf "203.0.113.7\n" >>"$2"
            printf "240e:b8f:29f:c200:1::1\n240e:b8f:29f:c200:2::2\n" >>"$3"
        }
        ensure_tmp_dir
        ALLOWLIST_FILE="${TMP_DIR}/whitelist.allow"
        RESOLVE_CACHE_FILE="${TMP_DIR}/resolve.cache"
        printf "src=a.example.com proto=tcp dport=22 v6prefix=64\n" >"${ALLOWLIST_FILE}"
        d="${TMP_DIR}/out"
        mkdir -p "$d"
        resolve_allowlist_to_files "$d/v4" "$d/v6" "$d/v4p" "$d/v6p" "$d/pt" "$d/pu" >/dev/null 2>&1
        cat "$d/v6p"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "240e:b8f:29f:c200::/64 . tcp . 22" ]
}

# addr_to_prefix_bits 是本次重构唯一改动的既有函数，出错会让 prune 裁错、nft 提交失败。
@test "addr_to_prefix_bits truncates an IPv4 CIDR to its prefix" {
    run dwl_call addr_to_prefix_bits "192.0.2.10/24"

    [ "${status}" -eq 0 ]
    [ "${output}" = "110000000000000000000010" ]
}

@test "addr_to_prefix_bits expands an embedded IPv4 suffix to 128 bits" {
    run bash -c 'source "$1"; printf "%s" "$(addr_to_prefix_bits "::ffff:192.0.2.1")" | wc -c | tr -d " "' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "128" ]
}

# 畸形地址必须硬失败：命令替换的失败不会传给 read/printf，
# 一旦失手就会变成一个长度错误却退出码为 0 的前缀键，把合法来源裁掉。
@test "addr_to_prefix_bits fails hard on a malformed IPv6 address" {
    run dwl_call addr_to_prefix_bits "2001:db8:::1"

    [ "${status}" -ne 0 ]
}

# 组数过多不会产生空组，只有组数校验挡得住它。
@test "addr_to_prefix_bits fails hard on too many IPv6 groups" {
    run dwl_call addr_to_prefix_bits "1:2:3:4:5:6:7:8:9"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Malformed IPv6"* ]]
}

# prune 里取前缀键时若把命令替换直接当 printf 的参数，die 就传不出去，
# 畸形地址会变成一个短键，反而把合法来源当成「被它覆盖」裁掉。
@test "prune_covered_sources propagates a malformed address instead of pruning" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "2001:db8:::1\n2001:db8::1:abcd\n" >"${TMP_DIR}/v6"
        prune_covered_sources "${TMP_DIR}/v6"
    ' _ "${DWL}"

    [ "${status}" -ne 0 ]
}

@test "normalize_allowlist_entry rejects malformed IPv6 addresses" {
    run dwl_call normalize_allowlist_entry "2001:db8:::1"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid IPv6 address"* ]]
}

@test "normalize_allowlist_entry still accepts every valid IPv6 form" {
    run bash -c '
        source "$1"
        for a in "2001:db8::1" "::1" "::ffff:192.0.2.1" "1:2:3:4:5:6:7:8" "2001:DB8::1" "2001:db8::/32"; do
            normalize_allowlist_entry "$a" >/dev/null || exit 1
        done
        echo ok
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "ok" ]
}

@test "prune_covered_sources keeps sibling addresses that nothing covers" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "2001:db8::9\n2001:db8::1:abcd\n2001:db8::5\n" >"${TMP_DIR}/v6"
        prune_covered_sources "${TMP_DIR}/v6"
        sort "${TMP_DIR}/v6" | paste -sd" " -
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "2001:db8::1:abcd 2001:db8::5 2001:db8::9" ]
}

@test "prune_covered_sources still drops an address inside a broader CIDR" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        printf "2001:db8::/32\n2001:db8::1:abcd\n" >"${TMP_DIR}/v6"
        prune_covered_sources "${TMP_DIR}/v6"
        paste -sd" " - <"${TMP_DIR}/v6"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "2001:db8::/32" ]
}

# 漏写 src= 的公开端口行必须继续报错，不能被静默解释成限源条目。
@test "parse_allowlist_line rejects a bare source after other fields" {
    run dwl_call parse_allowlist_line "proto=tcp dport=443 example.com"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"expected key=value"* ]]
}

@test "parse_allowlist_line accepts family flags regardless of case" {
    run dwl_call parse_allowlist_line "example.com V4ONLY"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src=example.com v4only" ]
}

# ── 下游放行观测 ─────────────────────────────────────────────────
# 夹具是 nft 1.0.6（Debian 12）对观测规则的真实渲染：写进去的
# `tcp flags & (fin|syn|rst|ack) == syn` 会被列成 `tcp flags syn / fin,syn,rst,ack`，
# 解析只能依赖行尾的 `counter packets N bytes M comment "..."`。
NFT_ENTER_FIXTURE='table inet domain_whitelist {
	chain observe_enter {
		type filter hook input priority -99; policy accept;
		iifname "lo" return
		ct state != new return
		tcp dport @public_tcp tcp flags syn / fin,syn,rst,ack counter packets 31 bytes 1860 comment "pub|tcp"
		udp dport @public_udp counter packets 0 bytes 0 comment "pub|udp"
		ip saddr @allow_v4 counter packets 0 bytes 0 comment "full|v4"
		ip6 saddr @allow_v6 counter packets 0 bytes 0 comment "full|v6"
		ip saddr 124.77.19.119 tcp dport 9100 tcp flags syn / fin,syn,rst,ack counter packets 22 bytes 1320 comment "src|124.77.19.119|tcp|9100"
		ip saddr 180.165.8.185 tcp dport 22 tcp flags syn / fin,syn,rst,ack counter packets 2 bytes 120 comment "src|180.165.8.185|tcp|22"
		ip6 saddr 240e:b8f:29f:c200::/64 tcp dport 22 tcp flags syn / fin,syn,rst,ack counter packets 0 bytes 0 comment "src|240e:b8f:29f:c200::/64|tcp|22"
	}
}'
NFT_EXIT_FIXTURE='table inet domain_whitelist {
	chain observe_exit {
		type filter hook input priority 200; policy accept;
		iifname "lo" return
		ct state != new return
		tcp dport @public_tcp tcp flags syn / fin,syn,rst,ack counter packets 27 bytes 1620 comment "pub|tcp"
		udp dport @public_udp counter packets 0 bytes 0 comment "pub|udp"
		ip saddr @allow_v4 counter packets 0 bytes 0 comment "full|v4"
		ip6 saddr @allow_v6 counter packets 0 bytes 0 comment "full|v6"
		ip saddr 124.77.19.119 tcp dport 9100 tcp flags syn / fin,syn,rst,ack counter packets 0 bytes 0 comment "src|124.77.19.119|tcp|9100"
		ip saddr 180.165.8.185 tcp dport 22 tcp flags syn / fin,syn,rst,ack counter packets 2 bytes 120 comment "src|180.165.8.185|tcp|22"
		ip6 saddr 240e:b8f:29f:c200::/64 tcp dport 22 tcp flags syn / fin,syn,rst,ack counter packets 0 bytes 0 comment "src|240e:b8f:29f:c200::/64|tcp|22"
	}
}'

# 在 source 之后用同名函数顶替 nft：按被查询的链返回对应夹具。
# command_exists 走 command -v，函数同样算「命令存在」。
OBSERVE_STUB='
    nft() {
        case "$*" in
            *observe_enter*) printf "%s\n" "${ENTER}" ;;
            *observe_exit*) printf "%s\n" "${EXIT}" ;;
            *) return 1 ;;
        esac
    }
'

build_sample_ruleset() {
    bash -c '
        source "$1"
        ensure_tmp_dir
        d="${TMP_DIR}"
        printf "124.77.19.119 . tcp . 9100\n10.0.0.5 . udp . 53\n" >"$d/v4p"
        printf "240e:b8f:29f:c200::/64 . tcp . 22\n" >"$d/v6p"
        : >"$d/v4"; : >"$d/v6"; printf "443\n" >"$d/pt"; : >"$d/pu"
        nft_build_ruleset "$d/v4" "$d/v6" "$d/v4p" "$d/v6p" "$d/pt" "$d/pu"
    ' _ "${DWL}"
}

@test "nft_build_ruleset brackets downstream firewalls with two observe chains" {
    run build_sample_ruleset

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"chain observe_enter {"*"type filter hook input priority -99; policy accept;"* ]]
    [[ "${output}" == *"chain observe_exit {"*"type filter hook input priority 200; policy accept;"* ]]
}

# 比较出入口计数的前提是两条链逐条镜像，去掉链名和优先级后必须完全一致。
@test "nft_build_ruleset emits identical rules in both observe chains" {
    run bash -c '
        ruleset="$(cat)"
        chain_body() {
            printf "%s\n" "${ruleset}" | sed -n "/chain $1 {/,/^    }/p" | sed "1,2d"
        }
        [ -n "$(chain_body observe_enter)" ] || exit 2
        [ "$(chain_body observe_enter)" = "$(chain_body observe_exit)" ]
    ' <<<"$(build_sample_ruleset)"

    [ "${status}" -eq 0 ]
}

# 观测只能计数、不能做判决：门禁链里不该出现任何观测规则，
# 观测链里除了开头两条 return 之外也不该有 accept / drop / return。
@test "nft_build_ruleset keeps verdicts out of the observe chains" {
    run bash -c '
        ruleset="$(cat)"
        gate="$(printf "%s\n" "${ruleset}" | sed -n "/chain input_gate {/,/^    }/p")"
        observe="$(printf "%s\n" "${ruleset}" | sed -n "/chain observe_enter {/,/^    }/p" | sed "1,4d")"
        [[ "${gate}" != *"comment"* ]] || exit 2
        ! printf "%s\n" "${observe}" | grep -Eq "(accept|drop|return|reject)"
    ' <<<"$(build_sample_ruleset)"

    [ "${status}" -eq 0 ]
}

@test "nft_build_ruleset counts only pure SYNs for tcp and every new udp flow" {
    run build_sample_ruleset

    [ "${status}" -eq 0 ]
    [[ "${output}" == *'ip saddr 124.77.19.119 tcp dport 9100 tcp flags & (fin|syn|rst|ack) == syn counter comment "src|124.77.19.119|tcp|9100"'* ]]
    [[ "${output}" == *'ip saddr 10.0.0.5 udp dport 53 counter comment "src|10.0.0.5|udp|53"'* ]]
    [[ "${output}" == *'ip6 saddr 240e:b8f:29f:c200::/64 tcp dport 22 tcp flags & (fin|syn|rst|ack) == syn counter comment "src|240e:b8f:29f:c200::/64|tcp|22"'* ]]
}

@test "nft_read_observe_counters parses the real nft 1.0.6 rendering" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        nft_read_observe_counters observe_enter
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "pub|tcp 31" ]
    [[ "${output}" == *"src|124.77.19.119|tcp|9100 22"* ]]
    [[ "${output}" == *"src|240e:b8f:29f:c200::/64|tcp|22 0"* ]]
    [ "${#lines[@]}" -eq 7 ]
}

# 表不存在（未启用、iptables 后端、非 root）时 nft 会失败，读取必须静默为空，
# 不能让 pipefail + set -e 把整个 status 或 refresh 带崩。
@test "nft_read_observe_counters stays silent when the chain is missing" {
    run bash -c '
        source "$1"
        nft() { return 1; }
        nft_read_observe_counters observe_enter
        echo "rc=$?"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "rc=0" ]
}

@test "observe_rows_to_file pairs enter and exit counts and skips idle entries" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        ensure_tmp_dir
        observe_rows_to_file "${TMP_DIR}/rows"
        sort "${TMP_DIR}/rows"
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "pub|tcp 31 27" ]
    [ "${lines[1]}" = "src|124.77.19.119|tcp|9100 22 0" ]
    [ "${lines[2]}" = "src|180.165.8.185|tcp|22 2 2" ]
    [ "${#lines[@]}" -eq 3 ]
}

# awk 的 NR == FNR 惯用法在第一个文件为空时会把第二个文件也当成第一个吞掉。
@test "observe_rows_to_file still reports entries when the exit chain is empty" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT=""
        eval "$4"
        ensure_tmp_dir
        observe_rows_to_file "${TMP_DIR}/rows"
        grep "9100" "${TMP_DIR}/rows"
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "src|124.77.19.119|tcp|9100 22 0" ]
}

@test "report_downstream_drops flags a source-scoped port dropped downstream" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        ensure_tmp_dir
        RESOLVE_CACHE_FILE="${TMP_DIR}/resolve.cache"
        printf "sh.example.com|4|124.77.19.119\n" >"${RESOLVE_CACHE_FILE}"
        report_downstream_drops log_change 2>&1
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${output}" == *"dropped 22 of 22 new connection(s) from sh.example.com (124.77.19.119) to tcp/9100"* ]]
}

# 公开端口被扫描器打到未使用的端口、再被下游丢掉是常态，告警只会是噪音；
# 出入口相等的限源条目也不该告警。
@test "report_downstream_drops ignores public ports and healthy entries" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        ensure_tmp_dir
        report_downstream_drops log_change 2>&1
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    # 夹具里公开端口 31 进 27 出、22 端口 2 进 2 出，都不该告警；
    # 唯一该告警的是 9100。按条数卡死，而不是排除某几个具体字样——
    # 误报的公开端口会被拆成「from pub to tcp/tcp」，排除式断言抓不到。
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c "Downstream firewall dropped")" -eq 1 ]
    [[ "${output}" == *"to tcp/9100"* ]]
}

@test "observe_tag_label renders each kind of observe key" {
    run bash -c '
        source "$1"
        ensure_tmp_dir
        RESOLVE_CACHE_FILE="${TMP_DIR}/none"
        observe_tag_label "src|240e:b8f:29f:c200::/64|tcp|7000-8000"
        observe_tag_label "pub|udp"
        observe_tag_label "full|v4"
    ' _ "${DWL}"

    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "src 240e:b8f:29f:c200::/64 tcp/7000-8000" ]
    [ "${lines[1]}" = "public udp" ]
    [ "${lines[2]}" = "full-access v4" ]
}

# 顺序不变量：nft 后端每次刷新都整表替换、计数归零，
# 所以必须在 apply_firewall 之前读计数。读晚了告警永远不会触发，而且完全静默。
# 这里把 apply_firewall 桩成「把计数清零」，读早了才能看到那 22 个被丢的连接。
@test "refresh_now reads downstream counters before replacing the table" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        ZEROED="$(printf "%s\n" "${ENTER}" | sed -E "s/counter packets [0-9]+/counter packets 0/")"
        validate_config_values() { :; }
        allowlist_count() { echo 1; }
        resolve_allowlist_to_files() { printf "203.0.113.1\n" >"$1"; : >"$2"; : >"$3"; : >"$4"; : >"$5"; : >"$6"; }
        require_port_support() { :; }
        apply_firewall() { ENTER="${ZEROED}"; EXIT="${ZEROED}"; }
        log_resolved_delta() { :; }
        save_resolved_snapshot() { :; }
        save_resolve_cache() { :; }
        ensure_tmp_dir
        refresh_now nft 2>&1
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dropped 22 of 22 new connection(s)"*"to tcp/9100"* ]]
}

# iptables 后端没有观测链，refresh 不能去读 nft 计数。
@test "refresh_now skips downstream observation on the iptables backend" {
    run bash -c '
        source "$1"
        ENTER="$2"
        EXIT="$3"
        eval "$4"
        validate_config_values() { :; }
        allowlist_count() { echo 1; }
        resolve_allowlist_to_files() { printf "203.0.113.1\n" >"$1"; : >"$2"; : >"$3"; : >"$4"; : >"$5"; : >"$6"; }
        require_port_support() { :; }
        apply_firewall() { :; }
        log_resolved_delta() { :; }
        save_resolved_snapshot() { :; }
        save_resolve_cache() { :; }
        ensure_tmp_dir
        refresh_now iptables 2>&1
    ' _ "${DWL}" "${NFT_ENTER_FIXTURE}" "${NFT_EXIT_FIXTURE}" "${OBSERVE_STUB}"

    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Downstream firewall dropped"* ]]
}
