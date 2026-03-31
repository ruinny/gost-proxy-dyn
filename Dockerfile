# =================================================================
# Gost V3 动态代理池 — Dockerfile
# 基于 Alpine Linux，轻量高效，适配 Zeabur 部署
# =================================================================
FROM alpine:3.20

# ── 构建参数（Gost 版本） ─────────────────────────────────────
ARG GOST_VERSION=3.0.0
ARG TARGETARCH=amd64

# ── 安装系统依赖 ─────────────────────────────────────────────
RUN apk add --no-cache \
    curl \
    jq \
    python3 \
    py3-pip \
    busybox-suid \
    bash \
    ca-certificates \
    dos2unix \
    tzdata

# ── 设置时区 ─────────────────────────────────────────────────
ENV TZ=Asia/Shanghai

# ── 下载并安装 Gost V3 ───────────────────────────────────────
RUN set -eux; \
    ARCH="${TARGETARCH}"; \
    if [ "$ARCH" = "arm64" ]; then ARCH="arm64"; \
    elif [ "$ARCH" = "amd64" ]; then ARCH="amd64"; \
    fi; \
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"; \
    curl -fsSL "$GOST_URL" -o /tmp/gost.tar.gz; \
    tar -xzf /tmp/gost.tar.gz -C /tmp; \
    mv /tmp/gost /usr/local/bin/gost; \
    chmod +x /usr/local/bin/gost; \
    rm -rf /tmp/gost*; \
    gost -V

# ── 安装 Python 依赖 ─────────────────────────────────────────
COPY monitor/requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt

# ── 创建目录结构 ─────────────────────────────────────────────
RUN mkdir -p /etc/gost /var/lib/gost /var/log /app/scripts /app/monitor /app/web

# ── 复制应用文件 ─────────────────────────────────────────────
COPY scripts/ /app/scripts/
COPY monitor/api.py /app/monitor/api.py
COPY web/ /app/web/

# ── 转换行尾并设置可执行权限 ──────────────────────────────────
RUN dos2unix /app/scripts/*.sh && chmod +x /app/scripts/*.sh

# ── 暴露端口 ─────────────────────────────────────────────────
# 1080: SOCKS5 代理入口
# 8080: 监控面板 & API
EXPOSE 1080 8080

# ── 健康检查 ─────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8080/api/health | grep -q '"status":"ok"' || exit 1

# ── 入口点 ───────────────────────────────────────────────────
ENTRYPOINT ["/bin/sh", "/app/scripts/entrypoint.sh"]
