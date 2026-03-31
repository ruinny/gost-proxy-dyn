"""
monitor/api.py — Gost 动态代理池监控后端 API
基于 FastAPI，提供代理状态、节点列表等接口
"""

from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ── 常量配置 ──────────────────────────────────────────────
PROXY_LIST_JSON = Path(os.getenv("PROXY_LIST_JSON", "/var/lib/gost/proxy_list.json"))
GOST_CONFIG = Path(os.getenv("GOST_CONFIG", "/etc/gost/gost.yaml"))
WEB_DIR = Path("/app/web")

# ── FastAPI 应用初始化 ─────────────────────────────────────
app = FastAPI(
    title="Gost 动态代理池监控 API",
    description="实时监控代理池状态、节点列表和健康情况",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ── 工具函数 ──────────────────────────────────────────────
def _read_proxy_data() -> dict[str, Any]:
    """读取代理列表 JSON 文件"""
    if not PROXY_LIST_JSON.exists():
        return {"updated_at": None, "country": "US", "count": 0, "proxies": []}
    with PROXY_LIST_JSON.open("r", encoding="utf-8") as f:
        return json.load(f)


def _is_gost_running() -> bool:
    """检查 Gost 进程是否运行"""
    try:
        pid_file = Path("/var/run/gost.pid")
        if not pid_file.exists():
            return False
        pid = int(pid_file.read_text().strip())
        # 发送信号 0 检查进程是否存在
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, ValueError, PermissionError, OSError):
        return False


def _get_gost_pid() -> int | None:
    """获取 Gost 进程 PID"""
    try:
        pid_file = Path("/var/run/gost.pid")
        if pid_file.exists():
            return int(pid_file.read_text().strip())
    except (ValueError, OSError):
        pass
    return None


# ── API 路由 ──────────────────────────────────────────────

@app.get("/api/health")
async def health_check() -> JSONResponse:
    """健康检查端点"""
    gost_ok = _is_gost_running()
    return JSONResponse(
        content={
            "status": "ok" if gost_ok else "degraded",
            "gost": "running" if gost_ok else "stopped",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        status_code=200 if gost_ok else 503,
    )


@app.get("/api/status")
async def get_status() -> dict[str, Any]:
    """获取代理池整体状态"""
    data = _read_proxy_data()
    gost_running = _is_gost_running()
    gost_pid = _get_gost_pid()

    # 计算号池 Key 数量
    api_keys_str = os.getenv("WEBSHARE_API_KEYS", "")
    api_key_count = len([k for k in api_keys_str.split(",") if k.strip()]) if api_keys_str else 0

    return {
        "service": {
            "gost_running": gost_running,
            "gost_pid": gost_pid,
            "socks5_port": 1080,
        },
        "proxy_pool": {
            "count": data.get("count", 0),
            "country": data.get("country", "US"),
            "updated_at": data.get("updated_at"),
            "strategy": "random",
            "key_count": data.get("key_count", api_key_count),
            "key_success": data.get("key_success", 0),
        },
        "config": {
            "max_proxies": int(os.getenv("MAX_PROXIES", "50")),
            "refresh_interval_min": int(os.getenv("REFRESH_INTERVAL", "30")),
        },
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/proxies")
async def get_proxies(
    page: int = 1,
    page_size: int = 20,
    mask: bool = True,
) -> dict[str, Any]:
    """获取代理节点列表（支持分页，默认对密码脱敏）"""
    data = _read_proxy_data()
    proxies: list[dict] = data.get("proxies", [])
    total = len(proxies)

    # 分页
    start = (page - 1) * page_size
    end = start + page_size
    page_proxies = proxies[start:end]

    # 脱敏处理
    if mask:
        for p in page_proxies:
            p = dict(p)
            if "password" in p:
                p["password"] = "****"

    return {
        "total": total,
        "page": page,
        "page_size": page_size,
        "pages": (total + page_size - 1) // page_size if total > 0 else 1,
        "updated_at": data.get("updated_at"),
        "proxies": page_proxies,
    }


@app.post("/api/reload")
async def trigger_reload() -> dict[str, str]:
    """手动触发代理列表热重载"""
    try:
        result = subprocess.run(
            ["/app/scripts/reload.sh"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            return {"status": "success", "message": "热重载已触发，Gost 配置已更新。"}
        else:
            raise HTTPException(
                status_code=500,
                detail=f"热重载失败：{result.stderr}",
            )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="热重载超时（60s）。")


# ── 静态文件服务 ──────────────────────────────────────────
if WEB_DIR.exists():
    app.mount("/", StaticFiles(directory=str(WEB_DIR), html=True), name="web")
