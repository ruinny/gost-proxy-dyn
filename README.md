# 🌐 Gost V3 动态代理池

基于 [Gost V3](https://github.com/go-gost/gost) 构建的高可用动态 SOCKS5 代理池，自动从 [Webshare.io](https://webshare.io) 获取代理节点，支持热重载和前端监控面板。

---

## ✨ 功能特性

| 功能 | 说明 |
|------|------|
| 🔄 **动态代理池** | 启动时自动从 Webshare Download API 获取最新代理列表 |
| 🔑 **多 Key 号池** | 支持多个 API Key 组队，聚合代理节点提高吞吐量 |
| ♻ **无中断热重载** | Cron 定时拉取 + `SIGHUP` 信号重载，服务不中断 |
| ⚖ **高可用出口** | Random 策略随机选择节点，MaxFails 自动熔断 |
| 🌍 **区域筛选** | 通过 Download API 路径级国家过滤，确保精准匹配 |
| 🔐 **统一认证** | 统一入口凭证，客户端连接简单 |
| 📊 **监控面板** | 赛博朋克风格 Web 监控面板，实时查看节点状态 |
| 🐳 **Docker 部署** | 一键 Docker 部署，适配 Zeabur PaaS |

---

## 🏗 架构图

```
客户端
  │ SOCKS5 (1080)
  ▼
┌────────────────────────────────┐
│  Gost V3 (SOCKS5 入口)         │
│  认证：PROXY_USERNAME/PASSWORD  │
└──────────────┬─────────────────┘
               │ Random 策略
       ┌───────┼───────┐
       ▼       ▼       ▼
   Webshare  Webshare  Webshare
   代理节点1  代理节点2  代理节点N
       (US Region, SOCKS5)

┌────────────────────────────────┐
│  监控 API (FastAPI :8080)       │
│  Web 面板 (Vanilla JS)          │
└────────────────────────────────┘

Cron → reload.sh → fetch_proxies.sh → SIGHUP → Gost 热重载
```

---

## 🚀 快速开始

### 方式一：Docker Compose（推荐）

```bash
# 1. 克隆项目
git clone <your-repo-url>
cd gost-proxy-pool

# 2. 创建配置文件
cp .env.example .env
# 编辑 .env，填入你的 Webshare API Key 和自定义密码

# 3. 启动服务
docker compose up -d

# 4. 查看日志
docker compose logs -f
```

### 方式二：Zeabur 部署

1. Fork 本仓库
2. 在 Zeabur 控制台中 **新建服务** → **从 GitHub 部署**
3. 在 **环境变量** 面板中配置以下变量（参考 `.env.example`）
4. 部署完成后，TCP 端口 1080 即为 SOCKS5 入口，HTTP 端口 8080 为监控面板

---

## ⚙ 环境变量

| 变量 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `WEBSHARE_API_KEYS` | ✅ | — | Webshare API Token，多个用逗号分隔组成号池 |
| `PROXY_USERNAME` | ✅ | `proxyuser` | SOCKS5 入口认证用户名 |
| `PROXY_PASSWORD` | ✅ | — | SOCKS5 入口认证密码 |
| `PROXY_COUNTRY` | ❌ | `US` | 代理节点国家（ISO 代码），多国用连字符分隔 |
| `MAX_PROXIES` | ❌ | `50` | 最大使用代理数量（从合并池中截取） |
| `REFRESH_INTERVAL` | ❌ | `30` | 定时刷新间隔（分钟） |
| `MONITOR_PORT` | ❌ | `8080` | 监控面板端口 |

---

## 📡 连接代理

```bash
# 测试 SOCKS5 代理（替换为你的认证信息和服务器 IP）
curl -x socks5h://${PROXY_USERNAME}:${PROXY_PASSWORD}@localhost:1080 \
  https://ipinfo.io/json

# 示例输出：显示美国 IP
```

---

## 📊 监控面板

访问 `http://<服务器IP>:8080` 查看监控面板：

- 实时 Gost 服务状态
- 代理节点总数与更新时间
- 节点列表搜索与分页
- 手动触发热重载按钮

### API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/status` | GET | 代理池整体状态 |
| `/api/proxies` | GET | 代理节点列表（分页） |
| `/api/health` | GET | 健康检查 |
| `/api/reload` | POST | 手动触发热重载 |

---

## 📁 项目结构

```
.
├── scripts/
│   ├── entrypoint.sh      # 容器入口：编排所有服务
│   ├── fetch_proxies.sh   # 拉取 Webshare API + 生成 Gost 配置
│   └── reload.sh          # 热重载：fetch + SIGHUP
├── monitor/
│   ├── api.py             # FastAPI 监控后端
│   └── requirements.txt
├── web/
│   └── index.html         # 前端监控面板
├── Dockerfile
├── docker-compose.yml
├── zbpack.json            # Zeabur 构建配置
└── .env.example
```

---

## 🔧 手动热重载

```bash
# 在容器内手动触发热重载
docker exec gost-proxy-pool /app/scripts/reload.sh

# 或通过 API
curl -X POST http://localhost:8080/api/reload
```

---

## 📝 注意事项

- Webshare 免费计划代理节点数量有限，建议使用付费计划以获取更多节点
- SOCKS5 入口密码请设置为强密码，避免暴露在公网时被滥用
- Zeabur 部署时，SOCKS5 TCP 端口需要在 Zeabur 控制台中配置 TCP 端口转发

---

## 📄 License

MIT
