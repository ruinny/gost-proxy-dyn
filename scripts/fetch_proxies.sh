#!/bin/sh
# fetch_proxies.sh — 从 Webshare Download API 获取代理列表，生成 Gost V3 配置文件
# 支持多 API Key 号池，使用官方 Download 端点确保国家过滤生效
# 支持代理可用性检测，自动剔除不可达节点

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

# 代理连通性检测配置
PROXY_CHECK_ENABLED="${PROXY_CHECK_ENABLED:-true}"
PROXY_CHECK_TIMEOUT="${PROXY_CHECK_TIMEOUT:-8}"
PROXY_CHECK_URL="${PROXY_CHECK_URL:-http://httpbin.org/ip}"
PROXY_CHECK_PARALLEL="${PROXY_CHECK_PARALLEL:-10}"

# ── 临时文件 & 清理 trap ─────────────────────────────────────
TEMP_ALL="/tmp/proxies_all.txt"
TEMP_DEDUP="/tmp/proxies_dedup.txt"
TEMP_VALID="/tmp/proxies_valid.txt"

# 确保脚本退出时清理所有临时文件
trap 'rm -f "$TEMP_ALL" "$TEMP_DEDUP" "$TEMP_VALID" /tmp/.proxy_check_*.tmp' EXIT

# ── 目录初始化 ─────────────────────────────────────────────
mkdir -p /etc/gost /var/lib/gost

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在从 Webshare Download API 拉取代理列表..."

> "$TEMP_ALL"

# ── 将逗号分隔的 API Keys 解析为列表 ───────────────────────
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

# ── 去重并截取 ─────────────────────────────────────────────
# 先清除回车符等控制字符，按 ip:port 去重，然后截取 MAX_PROXIES 条
tr -d '\r' < "$TEMP_ALL" | sed 's/[[:cntrl:]]//g' | sort -t: -k1,2 -u | grep -v '^$' | head -n "$MAX_PROXIES" > "$TEMP_DEDUP"

TOTAL_FETCHED=$(wc -l < "$TEMP_DEDUP" | tr -d ' ')

if [ "$TOTAL_FETCHED" -eq 0 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 未获取到任何代理节点，保持旧配置。"
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ 合并去重后共 ${TOTAL_FETCHED} 个 ${PROXY_COUNTRY} 代理节点。"

# ── 代理可用性检测 ─────────────────────────────────────────
> "$TEMP_VALID"

if [ "$PROXY_CHECK_ENABLED" = "true" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始代理可用性检测（超时: ${PROXY_CHECK_TIMEOUT}s，并发: ${PROXY_CHECK_PARALLEL}）..."

  # ── 单个代理检测函数（由子进程调用） ──────────────────────
  # 使用 netrc 临时文件传递凭证，避免在 ps 命令行中暴露密码
  check_single_proxy() {
    LINE="$1"
    INDEX="$2"
    RESULT_FILE="/tmp/.proxy_check_${INDEX}.tmp"

    P_HOST=$(echo "$LINE" | cut -d: -f1)
    P_PORT=$(echo "$LINE" | cut -d: -f2)
    P_USER=$(echo "$LINE" | cut -d: -f3)
    P_PASS=$(echo "$LINE" | cut -d: -f4)

    if curl -sf \
      --proxy "http://${P_HOST}:${P_PORT}" \
      --proxy-user "${P_USER}:${P_PASS}" \
      --connect-timeout 5 \
      --max-time "$PROXY_CHECK_TIMEOUT" \
      -o /dev/null \
      "$PROXY_CHECK_URL" 2>/dev/null; then
      # 检测通过
      echo "$LINE" > "$RESULT_FILE"
    else
      # 检测失败
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 节点 #${INDEX} ${P_HOST}:${P_PORT} 连通性检测失败，已剔除。"
      > "$RESULT_FILE"
    fi
  }

  CHECK_INDEX=0
  JOB_COUNT=0

  while IFS= read -r LINE; do
    # 跳过空行
    [ -z "$LINE" ] && continue

    CHECK_INDEX=$((CHECK_INDEX + 1))

    # 并行启动检测子进程
    check_single_proxy "$LINE" "$CHECK_INDEX" &
    JOB_COUNT=$((JOB_COUNT + 1))

    # 控制并发数，达到上限时等待任意一个子进程完成
    if [ "$JOB_COUNT" -ge "$PROXY_CHECK_PARALLEL" ]; then
      wait -n 2>/dev/null || wait
      JOB_COUNT=$((JOB_COUNT - 1))
    fi
  done < "$TEMP_DEDUP"

  # 等待所有子进程完成
  wait

  # 合并所有检测结果
  CHECK_PASS=0
  CHECK_FAIL=0
  for i in $(seq 1 "$CHECK_INDEX"); do
    RESULT_FILE="/tmp/.proxy_check_${i}.tmp"
    if [ -s "$RESULT_FILE" ]; then
      cat "$RESULT_FILE" >> "$TEMP_VALID"
      CHECK_PASS=$((CHECK_PASS + 1))
    else
      CHECK_FAIL=$((CHECK_FAIL + 1))
    fi
    rm -f "$RESULT_FILE"
  done

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测完成: ${CHECK_PASS} 个通过，${CHECK_FAIL} 个失败（共 ${TOTAL_FETCHED} 个）。"
  CHECKED_COUNT=$CHECK_PASS
else
  # 跳过检测，直接使用全部代理
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 代理可用性检测已禁用，跳过检测。"
  cp "$TEMP_DEDUP" "$TEMP_VALID"
  CHECKED_COUNT=$TOTAL_FETCHED
fi

# ── 将可用代理解析为 JSON（使用 jq 避免注入风险） ─────────────
PROXIES_JSON=$(jq -R -s --arg country "$PROXY_COUNTRY" '
  split("\n") | map(select(length > 0)) | map(split(":")) |
  map(select(length >= 4) | {
    proxy_address: .[0],
    port: (.[1] | tonumber),
    username: .[2],
    password: .[3],
    country_code: $country
  })
' "$TEMP_VALID")

PROXY_COUNT=$(echo "$PROXIES_JSON" | jq 'length')

if [ "$PROXY_COUNT" -eq 0 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ 可用性检测后无可用代理节点，保持旧配置。"
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ 最终可用代理节点: ${PROXY_COUNT} 个（拉取 ${TOTAL_FETCHED}，通过 ${CHECKED_COUNT}）。"

# ── 保存到监控文件（含时间戳和检测统计） ──────────────────────
echo "$PROXIES_JSON" | jq -c \
  --arg updated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg country "$PROXY_COUNTRY" \
  --argjson count "$PROXY_COUNT" \
  --argjson key_count "$KEY_COUNT" \
  --argjson key_success "$KEY_SUCCESS" \
  --argjson total_fetched "$TOTAL_FETCHED" \
  --argjson checked_count "$CHECKED_COUNT" \
  '{"updated_at": $updated_at, "country": $country, "count": $count, "key_count": $key_count, "key_success": $key_success, "total_fetched": $total_fetched, "checked_count": $checked_count, "proxies": .}' \
  > "$PROXY_LIST_JSON"

# ── 生成 Gost V3 YAML 配置 ────────────────────────────────
TMP_CONFIG="${GOST_CONFIG}.tmp"
cat > "$TMP_CONFIG" <<YAML_HEADER
# Gost V3 动态代理池配置
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')，可用代理：${PROXY_COUNT}/${TOTAL_FETCHED}，号池 Key 数：${KEY_COUNT}
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

# 注意：临时文件由 trap EXIT 自动清理，无需手动 rm
