#!/bin/bash
_APISERVER=127.0.0.1:18080
_XRAY=/usr/local/bin/xray

apidata () {
    local ARGS=
    if [[ $1 == "reset" ]]; then
        ARGS="-reset=true"
    fi
    $_XRAY api statsquery --server=$_APISERVER "${ARGS}" \
    | awk '{
        if (match($1, /"name":/)) {
            f=1; gsub(/^"|link"|,$/, "", $2);
            split($2, p, ">>>");
            printf "%s:%s->%s\t", p[1],p[2],p[4];
        }
        else if (match($1, /"value":/) && f){
            f = 0;
            gsub(/"/, "", $2);
            printf "%.0f\n", $2;
        }
        else if (match($0, /}/) && f) { f = 0; print 0; }
    }'
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local FILTERED=$(echo "$DATA" | grep "^${PREFIX}")
    
    # 创建关联数组来存储每个用户的上行和下行数据
    declare -A uplink downlink
    local total_up=0 total_down=0
    
    # 解析数据并分组
    while IFS=$'\t' read -r name value; do
        if [[ -n "$name" && -n "$value" ]]; then
            # 使用字符串匹配替代正则表达式
            if [[ "$name" == *"->up" ]]; then
                local user="${name%->up}"
                uplink["$user"]=$value
                total_up=$((total_up + value))
            elif [[ "$name" == *"->down" ]]; then
                local user="${name%->down}"
                downlink["$user"]=$value
                total_down=$((total_down + value))
            fi
        fi
    done <<< "$FILTERED"
    
    # 获取所有用户名并排序
    local all_users=""
    for user in "${!uplink[@]}"; do
        all_users="$all_users$user"$'\n'
    done
    for user in "${!downlink[@]}"; do
        all_users="$all_users$user"$'\n'
    done
    
    # 去重并排序
    local users=($(echo "$all_users" | sort -u | grep -v '^$'))
    
    # 显示每个用户的上行和下行数据
    for user in "${users[@]}"; do
        local up=${uplink["$user"]:-0}
        local down=${downlink["$user"]:-0}
        local total=$((up + down))
        
        # 格式化数据大小
        local up_formatted=$(echo "$up" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${up}B")
        local down_formatted=$(echo "$down" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${down}B")
        local total_formatted=$(echo "$total" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${total}B")
        
        printf "%-25s ↑%-10s ↓%-10s Total:%-10s\n" "$user" "$up_formatted" "$down_formatted" "$total_formatted"
    done
    
    # 显示总计
    if [[ ${#users[@]} -gt 0 ]]; then
        local grand_total=$((total_up + total_down))
        local total_up_formatted=$(echo "$total_up" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${total_up}B")
        local total_down_formatted=$(echo "$total_down" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${total_down}B")
        local grand_total_formatted=$(echo "$grand_total" | numfmt --suffix=B --to=iec 2>/dev/null || echo "${grand_total}B")
        
        echo "-----------------------------"
        printf "%-25s ↑%-10s ↓%-10s Total:%-10s\n" "TOTAL" "$total_up_formatted" "$total_down_formatted" "$grand_total_formatted"
    fi
}

DATA=$(apidata $1)
echo "------------Inbound----------"
print_sum "$DATA" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "$DATA" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "$DATA" "user"
echo "-----------------------------"
