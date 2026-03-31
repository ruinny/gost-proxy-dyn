#!/bin/sh
# entrypoint.sh — 容器入口脚本
# 初始化环境、启动 Gost、启动监控 API、设置 Cron 热重载

set -eu

MONITOR_PORT="${MONITOR_PORT:-8080}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-30}"
GOST_PID_FILE="/var/run/gost.pid"
GOST_CONFIG="/etc/gost/gost.yaml"

echo "============================================================"
echo "  Gost V3 动态代理池 启动中..."
echo "  SOCKS5 入口：:1080"
echo "  监控面板  ：:${MONITOR_PORT}"
echo "  代理国家  ：${PROXY_COUNTRY:-US}"
echo "  最大代理数：${MAX_PROXIES:-50}"
echo "  刷新间隔  ：每 ${REFRESH_INTERVAL} 分钟"
echo "============================================================"

# ── 1. 初始拉取代理列表并生成配置 ─────────────────────────
echo "[entrypoint] 初始化代理配置..."
/app/scripts/fetch_proxies.sh

# ── 2. 启动 Gost（后台运行） ──────────────────────────────
echo "[entrypoint] 启动 Gost V3..."
gost -C "$GOST_CONFIG" &
GOST_PID=$!
echo "$GOST_PID" > "$GOST_PID_FILE"
echo "[entrypoint] Gost 已启动，PID: ${GOST_PID}"

# 等待 Gost 完全启动
sleep 2

# ── 3. 启动监控 API（后台运行） ───────────────────────────
echo "[entrypoint] 启动监控 API（端口 ${MONITOR_PORT}）..."
cd /app/monitor
uvicorn api:app \
  --host 0.0.0.0 \
  --port "$MONITOR_PORT" \
  --workers 1 \
  --log-level warning &
echo "[entrypoint] 监控 API 已启动。"

# ── 4. 设置 Cron 定时热重载 ───────────────────────────────
echo "[entrypoint] 设置 Cron 定时任务（每 ${REFRESH_INTERVAL} 分钟）..."
# 将环境变量写入 /etc/environment 供 cron 读取
env | grep -E '^(WEBSHARE_API_KEYS|PROXY_USERNAME|PROXY_PASSWORD|PROXY_COUNTRY|MAX_PROXIES|REFRESH_INTERVAL|MONITOR_PORT)=' \
  > /etc/environment 2>/dev/null || true

# 写入 cron 任务
echo "*/${REFRESH_INTERVAL} * * * * . /etc/environment; /app/scripts/reload.sh >> /var/log/gost-reload.log 2>&1" \
  | crontab -

echo "[entrypoint] Cron 任务已配置。"

# ── 5. 启动 crond（前台，保持容器运行） ──────────────────
echo "[entrypoint] ✓ 所有服务已启动，启动 crond..."
echo ""
echo "  访问监控面板：http://<你的IP>:${MONITOR_PORT}"
echo "  SOCKS5 代理  ：socks5://${PROXY_USERNAME}:${PROXY_PASSWORD}@<你的IP>:1080"
echo ""

exec crond -f -l 8
