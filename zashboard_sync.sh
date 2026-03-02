#!/bin/sh
# Zashboard 标签同步脚本 (强化 IP 抓取逻辑)

# --- 1. 配置路径 ---
CONFIG_DIR="/mnt/sata2-1/Configs/zashboard"
mkdir -p "$CONFIG_DIR"

CONFIG_FILE="$CONFIG_DIR/zashboard-settings-bak.json"
OUTPUT_FILE_GENERAL="$CONFIG_DIR/zashboard-settings.json"
TEMP_DIR="/tmp/zaboard_update"

# 初始化基础配置文件 (如果不存在)
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"config/source-ip-label-list": "[]", "config/theme-color": "blue"}' > "$CONFIG_FILE"
fi

# --- 2. ID 生成函数 ---
generate_id() {
    printf "z%s%s" "$(date +%s)" "$(head /dev/urandom | tr -dc a-f0-9 | head -c 4 2>/dev/null)"
}

# --- 3. 数据提取 ---
rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
TEMP_MAC_V4="$TEMP_DIR/mac_ipv4.map"
TEMP_MAC_V6="$TEMP_DIR/mac_ipv6.map"

# 3.1 提取邻居表数据 (MAC -> IP)
ip neigh show | grep -E 'REACHABLE|STALE|DELAY' | grep 'lladdr' | awk '
{
    ip_addr = $1; mac_addr = ""
    for (i=1; i<=NF; i++) { if ($i == "lladdr") { mac_addr = tolower($(i+1)); break } }
    if (mac_addr != "") {
        if (ip_addr ~ /^[0-9.]+$/) { print mac_addr, ip_addr > "'"$TEMP_MAC_V4"'" } 
        else if (ip_addr ~ /^24/) { print mac_addr, ip_addr > "'"$TEMP_MAC_V6"'" }
    }
}'
touch "$TEMP_MAC_V6" "$TEMP_MAC_V4"

# --- 4. 构造映射逻辑 ---
EXISTING_LIST_JSON=$(jq -r '.["config/source-ip-label-list"]' "$CONFIG_FILE")
[ "$EXISTING_LIST_JSON" = "null" ] || [ -z "$EXISTING_LIST_JSON" ] && EXISTING_LIST_JSON="[]"

NEW_ENTRIES="[]"

# 4.1 同步手动定义的 IPv4 标签到其对应的 IPv6
IPV4_LABEL_MAP=$(echo "$EXISTING_LIST_JSON" | jq -r '.[] | select(.key | contains(".") ) | "\(.key):\(.label)"' 2>/dev/null)

for item in $IPV4_LABEL_MAP; do
    v4_ip=$(echo $item | cut -d: -f1)
    v4_label=$(echo $item | cut -d: -f2)
    v4_mac=$(grep " $v4_ip$" "$TEMP_MAC_V4" | awk '{print $1}')
    
    if [ -n "$v4_mac" ]; then
        v6_ips=$(grep "^$v4_mac " "$TEMP_MAC_V6" | awk '{print $2}')
        for v6 in $v6_ips; do
            new_id=$(generate_id)
            NEW_ENTRIES=$(echo "$NEW_ENTRIES" | jq --arg ip "$v6" --arg label "$v4_label" --arg id "$new_id" \
                '. += [{"key": $ip, "label": $label, "id": $id}]')
        done
    fi
done

# 4.2 自动识别 10.x 和 100.x 标记为 iStore (含自身接口和邻居设备)
# 合并抓取逻辑
SELF_IPS=$(ip addr | grep -oE 'inet (10\.|100\.)[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | awk '{print $2}')
NEIGH_IPS=$(awk '{print $2}' "$TEMP_MAC_V4" | grep -E '^(10\.|100\.)')
INTERNAL_IPS=$(echo -e "$SELF_IPS\n$NEIGH_IPS" | sort -u)

for ip in $INTERNAL_IPS; do
    [ -z "$ip" ] && continue
    new_id=$(generate_id)
    NEW_ENTRIES=$(echo "$NEW_ENTRIES" | jq --arg ip "$ip" --arg label "iStore" --arg id "$new_id" \
        '. += [{"key": $ip, "label": $label, "id": $id}]')
    
    # 尝试关联 IPv6
    int_mac=$(grep " $ip$" "$TEMP_MAC_V4" | awk '{print $1}')
    if [ -n "$int_mac" ]; then
        int_v6_ips=$(grep "^$int_mac " "$TEMP_MAC_V6" | awk '{print $2}')
        for v6 in $int_v6_ips; do
            new_id_v6=$(generate_id)
            NEW_ENTRIES=$(echo "$NEW_ENTRIES" | jq --arg ip "$v6" --arg label "iStore" --arg id "$new_id_v6" \
                '. += [{"key": $ip, "label": $label, "id": $id}]')
        done
    fi
done

# 4.3 合并并按 IP 去重 (手动定义的标签优先级更高)
FINAL_DATA_JSON=$(echo "$NEW_ENTRIES" | jq --argjson old "$EXISTING_LIST_JSON" \
    '$old + . | unique_by(.key)')

# --- 5. 生成配置文件 ---
JSON_STR=$(echo "$FINAL_DATA_JSON" | jq -c '.')
jq --arg val "$JSON_STR" '.["config/source-ip-label-list"] = $val' "$CONFIG_FILE" > "$OUTPUT_FILE_GENERAL"

rm -rf "$TEMP_DIR"
echo "成功：iStore IP ($INTERNAL_IPS) 及 IPv6 标签已同步至 $OUTPUT_FILE_GENERAL"
