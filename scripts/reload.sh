#!/bin/sh
# reload.sh — 定时热重载脚本
# 重新拉取代理列表并向 Gost 发送 SIGHUP 信号触发无中断重载

set -eu

GOST_PID_FILE="/var/run/gost.pid"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [reload]"

echo "${LOG_PREFIX} 开始代理列表热重载..."

# 重新拉取并生成配置
if /app/scripts/fetch_proxies.sh; then
  echo "${LOG_PREFIX} ✓ 配置生成成功，发送 SIGHUP 到 Gost..."

  if [ -f "$GOST_PID_FILE" ]; then
    GOST_PID=$(cat "$GOST_PID_FILE")
    if kill -0 "$GOST_PID" 2>/dev/null; then
      kill -HUP "$GOST_PID"
      echo "${LOG_PREFIX} ✓ 已向 PID ${GOST_PID} 发送 SIGHUP，Gost 已热重载。"
    else
      echo "${LOG_PREFIX} ✗ Gost 进程 (PID ${GOST_PID}) 不存在，尝试重启..."
      /app/scripts/entrypoint.sh &
    fi
  else
    echo "${LOG_PREFIX} ✗ 未找到 PID 文件 ${GOST_PID_FILE}。"
  fi
else
  echo "${LOG_PREFIX} ✗ 代理列表拉取失败，保持当前配置不变。"
fi

echo "${LOG_PREFIX} 热重载完成。"
