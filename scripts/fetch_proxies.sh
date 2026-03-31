#!/bin/sh
# fetch_proxies.sh — 从 Webshare API 获取代理列表，生成 Gost V3 配置文件

set -eu

# ── 配置变量 ──────────────────────────────────────────────
WEBSHARE_API_KEY="${WEBSHARE_API_KEY:?必须设置 WEBSHARE_API_KEY 环境变量}"
PROXY_USERNAME="${PROXY_USERNAME:-proxyuser}"
PROXY_PASSWORD="${PROXY_PASSWORD:-proxypass}"
PROXY_COUNTRY="${PROXY_COUNTRY:-US}"
MAX_PROXIES="${MAX_PROXIES:-50}"
GOST_CONFIG="/etc/gost/gost.yaml"
PROXY_LIST_JSON="/var/lib/gost/proxy_list.json"
MONITOR_PORT="${MONITOR_PORT:-8080}"

# ── 目录初始化 ─────────────────────────────────────────────
mkdir -p /etc/gost /var/lib/gost

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在从 Webshare API 拉取代理列表..."

# ── 拉取代理列表（分页，最多获取 MAX_PROXIES 个节点）──────────
# 每页最多 100 个，计算需要的页数
PAGE_SIZE=100
PAGES=$(( (MAX_PROXIES + PAGE_SIZE - 1) / PAGE_SIZE ))

# 收集所有节点到临时文件
TEMP_ALL="/tmp/proxies_all.json"
echo "[]" > "$TEMP_ALL"

i=1
TOTAL_FETCHED=0
while [ "$i" -le "$PAGES" ]; do
  RESPONSE=$(curl -sf \
    "https://proxy.webshare.io/api/v2/proxy/list/?mode=direct&page=${i}&page_size=${PAGE_SIZE}&country_code=${PROXY_COUNTRY}" \
    -H "Authorization: Token ${WEBSHARE_API_KEY}" \
    --max-time 30 || echo "")

  if [ -z "$RESPONSE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ 第 ${i} 页请求失败，跳过。"
    break
  fi

  # 提取该页节点并合并
  PAGE_NODES=$(echo "$RESPONSE" | jq -c '.results // []')
  COMBINED=$(jq -c --argjson new "$PAGE_NODES" '. + $new' "$TEMP_ALL")
  echo "$COMBINED" > "$TEMP_ALL"

  COUNT=$(echo "$PAGE_NODES" | jq 'length')
  TOTAL_FETCHED=$((TOTAL_FETCHED + COUNT))
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 第 ${i} 页获取到 ${COUNT} 个节点，累计 ${TOTAL_FETCHED} 个。"

  # 如果已够数量或者返回节点数小于 PAGE_SIZE（最后一页），停止
  if [ "$TOTAL_FETCHED" -ge "$MAX_PROXIES" ] || [ "$COUNT" -lt "$PAGE_SIZE" ]; then
    break
  fi
  i=$((i + 1))
done

# 截取到 MAX_PROXIES 限制
PROXIES=$(jq -c ".[0:${MAX_PROXIES}]" "$TEMP_ALL")
PROXY_COUNT=$(echo "$PROXIES" | jq 'length')

if [ "$PROXY_COUNT" -eq 0 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 未获取到任何代理节点，保持旧配置。"
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ 获取到 ${PROXY_COUNT} 个 ${PROXY_COUNTRY} 代理节点。"

# ── 保存到监控文件（含时间戳） ───────────────────────────────
echo "$PROXIES" | jq -c \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg country "$PROXY_COUNTRY" \
  --argjson count "$PROXY_COUNT" \
  '{"updated_at": $updated_at, "country": $country, "count": $count, "proxies": .}' \
  > "$PROXY_LIST_JSON"

# ── 生成 Gost V3 YAML 配置 ────────────────────────────────
cat > "$GOST_CONFIG" << YAML_HEADER
# Gost V3 动态代理池配置
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')，代理数量：${PROXY_COUNT}
services:
  - name: socks5-ingress
    addr: ":1080"
    handler:
      type: socks5
      auth:
        username: "${PROXY_USERNAME}"
        password: "${PROXY_PASSWORD}"
      metadata:
        udpBufferSize: 4096
    listener:
      type: tcp
    chain: proxy-chain

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

# 逐节点追加到配置
echo "$PROXIES" | jq -r 'to_entries[] | 
  "          - name: node-" + (.key | tostring) + "\n" +
  "            addr: \"" + .value.proxy_address + ":" + (.value.port | tostring) + "\"\n" +
  "            connector:\n" +
  "              type: socks5\n" +
  "              auth:\n" +
  "                username: \"" + .value.username + "\"\n" +
  "                password: \"" + .value.password + "\"\n" +
  "            dialer:\n" +
  "              type: tcp"' >> "$GOST_CONFIG"

# ── 追加 API 和监控配置 ───────────────────────────────────
cat >> "$GOST_CONFIG" << YAML_FOOTER

api:
  addr: "127.0.0.1:18080"
  accesslog: false

log:
  level: warn
  format: json
YAML_FOOTER

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Gost 配置已写入 ${GOST_CONFIG}。"
