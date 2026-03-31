#!/bin/sh
# reload.sh — 定时热重载脚本
# 重新拉取代理列表并向 Gost 发送 SIGHUP 信号触发无中断重载

set -eu

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [reload]"

echo "${LOG_PREFIX} 开始代理列表热重载..."

# 重新拉取并生成配置
if /app/scripts/fetch_proxies.sh; then
  echo "${LOG_PREFIX} ✓ 配置生成成功，发送 SIGHUP 到 Gost..."

  GOST_PID=$(pidof gost || echo "")
  if [ -n "$GOST_PID" ]; then
    kill -HUP $GOST_PID
    echo "${LOG_PREFIX} ✓ 已向 Gost (PID $GOST_PID) 发送 SIGHUP 进行无中断重载。"
  else
    echo "${LOG_PREFIX} ✗ Gost 进程缺失（等待 Supervisor 自动恢复）。"
    supervisorctl -c /etc/supervisord.conf restart gost >/dev/null 2>&1 || true
  fi
else
  echo "${LOG_PREFIX} ✗ 代理列表拉取失败，保持当前配置不变。"
fi

echo "${LOG_PREFIX} 热重载完成。"
