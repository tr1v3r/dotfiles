# Firecrawl 本地部署与 DSH MCP 接入

本文记录本机 Firecrawl 的 Docker Compose 部署、DSH MCP 接入、日常使用和排障方法。
所有路径使用 `~`、`$HOME` 或运行时表达式，禁止写入具体用户名。

## 架构

```text
DSH agent
  → @deepseek-ai/dsh-mcp-client
  → firecrawl-mcp（stdio 子进程）
  → http://127.0.0.1:3002
  → Firecrawl Docker Compose

DSH agent（web_search provider / read_page）
  → @liustack/modsearch 引擎链（firecrawl 引擎）
  → firecrawl.baseURL = http://127.0.0.1:3002
  → Firecrawl Docker Compose
```

`127.0.0.1:3002` 是 Firecrawl REST API，不是 MCP endpoint。DSH 不能直接连接
`http://127.0.0.1:3002/mcp`，必须通过 `firecrawl-mcp` 做协议桥接。

## 当前约定

| 项目 | 值 |
| --- | --- |
| Firecrawl checkout | `~/workspace/opensource/firecrawl` |
| Firecrawl release | `v2.11.0` |
| Firecrawl API | `http://127.0.0.1:3002` |
| Firecrawl MCP | `firecrawl-mcp@3.24.0` |
| modsearch 引擎 | `@liustack/modsearch@5.10.1`，`firecrawl.baseURL` 指向本地 |
| API 认证 | 本地关闭，不需要云端 API key |
| DSH profiles | `dsh-tui`、`headless`、`web` |

## 首次部署

### 1. 前置条件

- Git
- Docker Desktop / Docker Engine
- Docker Compose v2（命令为 `docker compose`）
- 建议为 Docker 预留至少 6 CPU、10–12 GB 内存

### 2. 下载固定版本

```bash
mkdir -p ~/workspace/opensource
git clone --branch v2.11.0 --depth 1 \
  https://github.com/mendableai/firecrawl.git \
  ~/workspace/opensource/firecrawl
cd ~/workspace/opensource/firecrawl
```

固定 release，避免 `main` 与浮动镜像同时变化导致难以复现。

### 3. 创建本地 `.env`

`.env` 已被 Firecrawl 的 `.gitignore` 忽略，不要提交。其中的密码只用于本地容器，
仍应使用随机值。

```dotenv
PORT=3002
HOST=0.0.0.0
USE_DB_AUTHENTICATION=false

# 保守的个人电脑并发
NUM_WORKERS_PER_QUEUE=2
CRAWL_CONCURRENT_REQUESTS=4
MAX_CONCURRENT_JOBS=2
BROWSER_POOL_SIZE=2

POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=<用 openssl rand -hex 24 生成>
POSTGRES_DB=postgres
BULL_AUTH_KEY=<用 openssl rand -hex 24 生成>
LOGGING_LEVEL=info
```

`POSTGRES_DB` 必须保持为 `postgres`。官方预构建 `nuq-postgres` 镜像的
`pg_cron` 默认绑定该数据库；改成其他名称会导致初始化失败。

### 4. 选择构建方式

普通网络环境可直接从源码构建：

```bash
docker compose build
docker compose up -d
```

如果构建时遇到 PostgreSQL apt 源 502，或公司网络代理导致 GitHub TLS 证书校验失败，
按官方 Compose 注释改用预构建镜像：

```yaml
x-common-service: &common-service
  image: ghcr.io/firecrawl/firecrawl
  # build: apps/api

services:
  playwright-service:
    image: ghcr.io/firecrawl/playwright-service:latest
    # build: apps/playwright-service-ts

  nuq-postgres:
    image: ghcr.io/firecrawl/nuq-postgres:latest
    # build: apps/nuq-postgres
```

然后启动：

```bash
docker compose up -d --pull always
```

预构建镜像使用浮动标签。需要强复现性时应记录镜像 digest，并在升级时主动更新。

### 5. 验证容器

```bash
docker compose ps
docker compose logs --tail=100 api
```

长期运行的主要服务包括 API、Playwright、PostgreSQL、Redis、RabbitMQ 和
FoundationDB。`foundationdb-init` 是一次性初始化容器，状态为 `Exited (0)` 属于正常。

## REST API 冒烟测试

本地配置 `USE_DB_AUTHENTICATION=false` 时，不需要 `Authorization` header，也不需要
真实 `FIRECRAWL_API_KEY`。

### 搜索

```bash
curl --noproxy '*' -sS -X POST http://127.0.0.1:3002/v2/search \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "Firecrawl official documentation",
    "limit": 3
  }'
```

### 抓取单页

```bash
curl --noproxy '*' -sS -X POST http://127.0.0.1:3002/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://example.com",
    "formats": ["markdown"]
  }'
```

响应中的 `creditsUsed` 是 Firecrawl 的内部计量字段；请求走本地实例时不会产生
Firecrawl Cloud 账单。

## DSH MCP 配置

三个 profile 的 `cordis.patch.yml` 都插入同一条插件配置：

```yaml
- insert:
    - id: mcp-firecrawl
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: firecrawl
        transport: stdio
        command: npx
        args:
          - -y
          - firecrawl-mcp@3.24.0
        env:
          FIRECRAWL_API_URL: http://127.0.0.1:3002
          NPM_CONFIG_CACHE: !!js process.env.HOME + '/.cache/dsh-npm'
        toolCallTimeoutMs: 180000
        failOnStartupError: false
```

涉及文件：

```text
~/.config/dsh/profiles/dsh-tui/cordis.patch.yml
~/.config/dsh/profiles/headless/cordis.patch.yml
~/.config/dsh/profiles/web/cordis.patch.yml
```

说明：

- `FIRECRAWL_API_URL` 指向本地 API，因此 `FIRECRAWL_API_KEY` 可省略。
- `NPM_CONFIG_CACHE` 使用 `process.env.HOME`，不要提交具体用户目录。
- 独立 npm cache 避免历史上 `~/.npm` 内 root-owned 文件造成 `EPERM`。
- `failOnStartupError: false` 确保 Firecrawl 暂时离线时不会阻止整个 DSH 启动。
- `toolCallTimeoutMs` 提高到 180 秒，适配 crawl、extract 等长调用。

### 验证组合配置

```bash
dsh --profile dsh-tui --dump-config
dsh --profile headless --dump-config
dsh --profile web --dump-config
```

每份输出应且只应包含一条：

```yaml
- id: mcp-firecrawl
```

TUI 和 Web 已运行时建议重启，以确保模型请求拿到新的工具目录；Headless 每次调用都会
重新加载 startup patch。

## modsearch 引擎接入

`@liustack/modsearch`（web profile 已装）把本地 Firecrawl 挂为搜索/抓取引擎链的第一跳，
替代 Firecrawl Cloud 的 keyless 额度。它与 MCP 桥是**并行的两条消费者链**：MCP 提供
`mcp__firecrawl__*` 工具，modsearch 接管 dsh 内置 `web_search` 的 provider 并新增
`read_page`。

### 配置

配置在 `~/.modsearch/config.json`（全局，不分 profile；权限 0600）：

```bash
# modsearch CLI 随插件分发，无全局安装
PKG=~/.config/dsh/profiles/web/node_modules/@liustack/modsearch
node $PKG/dist/main.js config set firecrawl.baseURL http://127.0.0.1:3002
```

生效后的引擎链：**本地 Firecrawl → Antigravity CLI（`agy`）→ 内置 local 抓取器**。
baseURL 覆盖官方端点后，云端 keyless 额度不再参与。dsh Web 的
设置 → 插件配置 → ModSearch 卡片读写的是同一份文件。

### 验证

```bash
# 1. 路由体检（不耗额度、不发请求）
node $PKG/dist/main.js doctor   # firecrawl 应为 READY

# 2. 实测搜索（强制 firecrawl 引擎）
node $PKG/dist/main.js search -q "smoke test" -e firecrawl --max-results 3

# 3. 取证请求落在本地实例
docker logs firecrawl-api-1 --since 2m 2>&1 | grep searchController
```

步骤 2 返回 `"engine": "firecrawl", "status": "ok"`、步骤 3 日志出现
`Searching for results` 即接线成功。

### 已知折衷

- 本地 Firecrawl 的搜索后端是 DuckDuckGo，结果质量以 DDG 为限；需要带引用的
  综合答案可 `modsearch config set engine antigravity-cli` 切 `agy`。
- 本地实例离线时 modsearch 自动 failover 到 `agy`/local，不影响 MCP 侧工具
  （它们会直接报错）。
- modsearch 的 SSRF 防护默认拒绝私网地址（针对抓取目标，不影响 baseURL 指向
  本地）；如遇 VPN 把公网域名解析进保留网段，见其 troubleshooting 的
  `allowPrivateNetwork`。

## 在 Agent 中使用

注册后的常用工具名包括：

```text
mcp__firecrawl__firecrawl_search
mcp__firecrawl__firecrawl_scrape
mcp__firecrawl__firecrawl_crawl
mcp__firecrawl__firecrawl_check_crawl_status
mcp__firecrawl__firecrawl_map
mcp__firecrawl__firecrawl_extract
mcp__firecrawl__firecrawl_parse
mcp__firecrawl__firecrawl_interact
```

通常无需手写工具名，直接描述目标：

```text
使用 Firecrawl 搜索 2025 年中国人形机器人产业的市场规模、产业链和主要玩家。
抓取可信的一手或权威来源，交叉验证关键数字，并为每项结论附来源 URL。
```

完整产业研究建议按以下顺序：

1. `consulting-analysis` 生成分析框架和数据需求。
2. `firecrawl-market-research` 调用本地 Firecrawl 搜索、抓取和交叉验证。
3. `competitive-intelligence` 补充竞品与竞争格局。
4. `customer-research` 补充需求侧、VOC、ICP 和 JTBD。
5. 回到 `consulting-analysis` 汇总为最终报告。

## 日常运维

```bash
cd ~/workspace/opensource/firecrawl

# 查看状态
docker compose ps

# 查看 API 日志
docker compose logs -f api

# 临时停止并保留现有容器
docker compose stop

# 恢复
docker compose start

# 重新创建服务
docker compose up -d
```

默认 Compose 对 PostgreSQL、Redis 和 RabbitMQ 没有完整的显式持久化设计。普通本地研究
可接受；不要把它直接当作生产部署。执行 `docker compose down -v` 会删除卷，只能用于
确认没有重要数据的首次部署排障。

## 常见问题

### `POSTGRES_DB` 修改后 PostgreSQL 初始化失败

典型错误包含：

```text
can only create extension in database postgres
relation "nuq.queue_scrape" does not exist
```

恢复 `POSTGRES_DB=postgres`。如果这是首次失败且没有有效数据，可重置新建的失败卷：

```bash
docker compose down -v --remove-orphans
docker compose up -d
```

### 源码构建下载失败

典型错误：

```text
apt.postgresql.org ... 502 Bad Gateway
SSL certificate problem: unable to get local issuer certificate
```

优先切换到官方预构建镜像，不要在 Dockerfile 中加入 `curl -k` 或关闭 TLS 校验。

### Compose 打印大量未设置变量警告

OpenAI、Ollama、Supabase、代理、SearXNG 等变量都是可选功能。基础 search、scrape、crawl
可在它们为空时工作。AI JSON 抽取或模型驱动能力需要额外配置 OpenAI-compatible endpoint
或 Ollama。

### Headless 报 `NO_ADAPTER: openai-codex`

这是 Headless 的默认 LLM provider 路由问题，与 Firecrawl MCP 注册无关。先单独修复
Headless 的模型和认证配置，不要把 `openai-codex` 加回共享 `settings.yaml`，否则会重现
TUI 的 provider 批量注册冲突。

### 安全边界

`USE_DB_AUTHENTICATION=false` 意味着 API 无认证。只监听本机或可信网络，不要直接把
`3002` 暴露到公网。远程使用时需要反向代理、TLS、认证和网络访问控制。

## 升级

升级前分别确认 Firecrawl release、Docker 镜像和 `firecrawl-mcp` 的兼容性：

```bash
cd ~/workspace/opensource/firecrawl
git fetch --tags
git tag --sort=-version:refname | head
npm view firecrawl-mcp version
```

升级后重新执行 REST API 冒烟测试和三份 DSH `--dump-config` 检查，再测试至少一次
`mcp__firecrawl__firecrawl_search` 实际调用；modsearch 侧重跑其 doctor 与一次
`search -e firecrawl`（其兼容性按 dsh 版本逐一验证，dsh 升级后同样要复查
`--dump-config` 中 `searchProvider: modsearch` 是否仍在）。
