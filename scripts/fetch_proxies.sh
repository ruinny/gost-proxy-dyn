#!/bin/sh
# fetch_proxies.sh — 从 Webshare Download API 获取代理列表，生成 Gost V3 配置文件
# 支持多 API Key 号池，使用官方 Download 端点确保国家过滤生效

set -eu

# ── 配置变量 ──────────────────────────────────────────────
WEBSHARE_API_KEYS="${WEBSHARE_API_KEYS:?必须设置 WEBSHARE_API_KEYS 环境变量}"
PROXY_USERNAME="${PROXY_USERNAME:-proxyuser}"
PROXY_PASSWORD="${PROXY_PASSWORD:-proxypass}"
PROXY_COUNTRY="${PROXY_COUNTRY:-US}"
MAX_PROXIES="${MAX_PROXIES:-50}"
GOST_CONFIG="/etc/gost/gost.yaml"
PROXY_LIST_JSON="/var/lib/gost/proxy_list.json"
MONITOR_PORT="${MONITOR_PORT:-8080}"

# ── 目录初始化 ─────────────────────────────────────────────
mkdir -p /etc/gost /var/lib/gost

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在从 Webshare Download API 拉取代理列表..."

# ── 将逗号分隔的 API Keys 解析为列表 ───────────────────────
TEMP_ALL="/tmp/proxies_all.txt"
> "$TEMP_ALL"

KEY_COUNT=0
KEY_SUCCESS=0

# 保存原始 IFS 并按逗号分割
OLD_IFS="$IFS"
IFS=","

for API_KEY in $WEBSHARE_API_KEYS; do
  # 去除首尾空格
  API_KEY=$(echo "$API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$API_KEY" ]; then
    continue
  fi

  KEY_COUNT=$((KEY_COUNT + 1))
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 处理第 ${KEY_COUNT} 个 API Key..."

  # 第一步：通过 Proxy Config API 获取 proxy_list_download_token
  CONFIG_RESPONSE=$(curl -sf \
    "https://proxy.webshare.io/api/v2/proxy/config/" \
    -H "Authorization: Token ${API_KEY}" \
    --max-time 15 || echo "")

  if [ -z "$CONFIG_RESPONSE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ Key #${KEY_COUNT}: 获取 Proxy Config 失败，跳过。"
    continue
  fi

  DOWNLOAD_TOKEN=$(echo "$CONFIG_RESPONSE" | jq -r '.proxy_list_download_token // empty')

  if [ -z "$DOWNLOAD_TOKEN" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ Key #${KEY_COUNT}: 未找到 download_token，跳过。"
    continue
  fi

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Key #${KEY_COUNT}: 获取到 download_token。"

  # 第二步：使用 Download API 拉取代理列表（国家代码嵌入路径）
  # 格式: GET /api/v2/proxy/list/download/{token}/{country_codes}/any/{auth_method}/{endpoint_mode}/{search}/
  DOWNLOAD_URL="https://proxy.webshare.io/api/v2/proxy/list/download/${DOWNLOAD_TOKEN}/${PROXY_COUNTRY}/any/username/direct/-/"

  PROXY_TEXT=$(curl -sf "$DOWNLOAD_URL" --max-time 30 || echo "")

  if [ -z "$PROXY_TEXT" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ Key #${KEY_COUNT}: Download API 请求失败，跳过。"
    continue
  fi

  # 统计该 Key 获取到的代理数
  KEY_PROXY_COUNT=$(echo "$PROXY_TEXT" | grep -c '.' || true)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Key #${KEY_COUNT}: 获取到 ${KEY_PROXY_COUNT} 个代理节点。"

  # 追加到汇总文件（每行格式: ip:port:username:password），清除回车符
  printf '%s\n' "$PROXY_TEXT" | tr -d '\r' >> "$TEMP_ALL"

  KEY_SUCCESS=$((KEY_SUCCESS + 1))
done

IFS="$OLD_IFS"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 号池统计: 共 ${KEY_COUNT} 个 Key，${KEY_SUCCESS} 个成功。"

# ── 去重并解析为 JSON ──────────────────────────────────────
# 先清除回车符等控制字符，按 ip:port 去重，然后截取 MAX_PROXIES 条
PROXIES_JSON=$(tr -d '\r' < "$TEMP_ALL" | sed 's/[[:cntrl:]]//g' | sort -t: -k1,2 -u | grep -v '^$' | head -n "$MAX_PROXIES" | awk -F: '{
  # 清除字段中的残留控制字符
  for (i=1; i<=NF; i++) gsub(/[^[:print:]]/, "", $i)
  if ($1 != "" && $2 != "")
    printf "{\"proxy_address\":\"%s\",\"port\":%s,\"username\":\"%s\",\"password\":\"%s\",\"country_code\":\"'"${PROXY_COUNTRY}"'\"}\n", $1, $2, $3, $4
}' | jq -sc '.')

PROXY_COUNT=$(echo "$PROXIES_JSON" | jq 'length')

if [ "$PROXY_COUNT" -eq 0 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 未获取到任何代理节点，保持旧配置。"
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ 合并去重后共 ${PROXY_COUNT} 个 ${PROXY_COUNTRY} 代理节点。"

# ── 保存到监控文件（含时间戳） ───────────────────────────────
echo "$PROXIES_JSON" | jq -c \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg country "$PROXY_COUNTRY" \
  --argjson count "$PROXY_COUNT" \
  --argjson key_count "$KEY_COUNT" \
  --argjson key_success "$KEY_SUCCESS" \
  '{"updated_at": $updated_at, "country": $country, "count": $count, "key_count": $key_count, "key_success": $key_success, "proxies": .}' \
  > "$PROXY_LIST_JSON"

# ── 生成 Gost V3 YAML 配置 ────────────────────────────────
TMP_CONFIG="${GOST_CONFIG}.tmp"
cat > "$TMP_CONFIG" <<YAML_HEADER
# Gost V3 动态代理池配置
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')，代理数量：${PROXY_COUNT}，号池 Key 数：${KEY_COUNT}
services:
  - name: socks5-ingress
    addr: ":1080"
    handler:
      type: socks5
      chain: proxy-chain
      auth:
        username: "${PROXY_USERNAME}"
        password: "${PROXY_PASSWORD}"
      metadata:
        udpBufferSize: 4096
    listener:
      type: tcp

chains:
  - name: proxy-chain
    hops:
      - name: webshare-pool
        selector:
          strategy: random
          maxFails: 3
          failTimeout: 30s
        nodes:
YAML_HEADER

# 逐节点追加到配置（注意：Webshare 提供的是 HTTP 代理，connector 类型为 http）
echo "$PROXIES_JSON" | jq -r 'to_entries[] |
  "          - name: node-" + (.key | tostring) + "\n" +
  "            addr: \"" + .value.proxy_address + ":" + (.value.port | tostring) + "\"\n" +
  "            connector:\n" +
  "              type: http\n" +
  "              auth:\n" +
  "                username: \"" + .value.username + "\"\n" +
  "                password: \"" + .value.password + "\"\n" +
  "            dialer:\n" +
  "              type: tcp"' >> "$TMP_CONFIG"

# ── 追加 API 和监控配置 ───────────────────────────────────
cat >> "$TMP_CONFIG" <<YAML_FOOTER

api:
  addr: "127.0.0.1:18080"
  accesslog: false

log:
  level: warn
  format: json
YAML_FOOTER

# 原子替换为正式配置
mv "$TMP_CONFIG" "$GOST_CONFIG"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Gost 配置已写入 ${GOST_CONFIG}。"
