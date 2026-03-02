#!/bin/sh
# Zashboard 标签同步脚本 (包含清理逻辑、iStore识别及 Web 目录联动)

# --- 1. 配置路径 ---
CONFIG_DIR="/etc/openclash/zashboard"
UI_DIR="/usr/share/openclash/ui/zashboard"
CONFIG_FILE="$CONFIG_DIR/zashboard-settings-bak.json"
OUTPUT_FILE_GENERAL="$CONFIG_DIR/zashboard-settings.json"
TEMP_DIR="/tmp/zaboard_update"

# 初始化基础配置文件
[ ! -f "$CONFIG_FILE" ] && echo '{"config/source-ip-label-list": "[]", "config/theme-color": "blue"}' > "$CONFIG_FILE"

# --- 2. ID 生成函数 ---
generate_id() {
    printf "z%s%s" "$(date +%s)" "$(head /dev/urandom | tr -dc a-f0-9 | head -c 4 2>/dev/null)"
}

# --- 3. 数据提取 ---
rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
TEMP_MAC_V4="$TEMP_DIR/mac_ipv4.map"
TEMP_MAC_V6="$TEMP_DIR/mac_ipv6.map"

# 3.1 获取当前 IPv6 前缀 (用于保留有效的 EUI-64 地址)
CUR_PREFIX=$(ip -6 addr show br-lan | grep 'global' | grep '^    inet6 24' | awk '{print $2}' | cut -d: -f1-4 | head -n1)

# 3.2 提取邻居表
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

# 当前在线 IP 列表
ONLINE_LIST=$(cat "$TEMP_MAC_V4" "$TEMP_MAC_V6" | awk '{print $2}' | tr '\n' ' ')

# --- 4. 构造与清理逻辑 ---
EXISTING_LIST_JSON=$(jq -r '.["config/source-ip-label-list"]' "$CONFIG_FILE")
[ "$EXISTING_LIST_JSON" = "null" ] || [ -z "$EXISTING_LIST_JSON" ] && EXISTING_LIST_JSON="[]"

# 4.1 智能清理：保留 IPv4、在线地址、以及前缀匹配的 EUI-64
CLEANED_LIST_JSON=$(echo "$EXISTING_LIST_JSON" | jq --arg online "$ONLINE_LIST" --arg prefix "$CUR_PREFIX" '
  map(select(
    (.key | contains(".")) or 
    (.key as $k | $online | contains($k)) or
    (.key | (contains("ff:fe") or contains("fffe")) and startswith($prefix))
  ))
')

NEW_ENTRIES="[]"

# 4.2 同步手动标签
IPV4_LABEL_MAP=$(echo "$CLEANED_LIST_JSON" | jq -r '.[] | select(.key | contains(".") ) | "\(.key):\(.label)"' 2>/dev/null)
for item in $IPV4_LABEL_MAP; do
    v4_ip=$(echo $item | cut -d: -f1); v4_label=$(echo $item | cut -d: -f2)
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

# 4.3 自动识别 10.x/100.x 标记为 iStore
SELF_IPS=$(ip addr | grep -oE 'inet (10\.|100\.)[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | awk '{print $2}')
NEIGH_IPS=$(awk '{print $2}' "$TEMP_MAC_V4" | grep -E '^(10\.|100\.)')
INTERNAL_IPS=$(echo -e "$SELF_IPS\n$NEIGH_IPS" | sort -u)
for ip in $INTERNAL_IPS; do
    [ -z "$ip" ] && continue
    new_id=$(generate_id)
    NEW_ENTRIES=$(echo "$NEW_ENTRIES" | jq --arg ip "$ip" --arg label "iStore" --arg id "$new_id" \
        '. += [{"key": $ip, "label": $label, "id": $id}]')
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

# 4.4 合并去重
FINAL_DATA_JSON=$(echo "$NEW_ENTRIES" | jq --argjson old "$CLEANED_LIST_JSON" '$old + . | unique_by(.key)')

# --- 5. 生成配置文件 ---
JSON_STR=$(echo "$FINAL_DATA_JSON" | jq -c '.')
jq --arg val "$JSON_STR" '.["config/source-ip-label-list"] = $val' "$CONFIG_FILE" > "$OUTPUT_FILE_GENERAL"

# --- 6. 建立 UI 目录软链接 (新添加) ---
if [ -d "$UI_DIR" ]; then
    # 如果已经存在同名文件但不是软链接，先删除它
    [ -f "$UI_DIR/zashboard-settings.json" ] && [ ! -L "$UI_DIR/zashboard-settings.json" ] && rm -f "$UI_DIR/zashboard-settings.json"
    
    # 建立软链接
    ln -sf "$OUTPUT_FILE_GENERAL" "$UI_DIR/zashboard-settings.json"
    echo "Web Link Created: $UI_DIR/zashboard-settings.json"
fi

rm -rf "$TEMP_DIR"
echo "DONE: Labels synced and linked to UI directory."
