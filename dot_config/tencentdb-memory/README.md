# TencentDB Agent Memory — 本机 Docker Gateway

使用上游 `main` 官方 `docker/opensource/Dockerfile.hermes` 的本地副本，来源提交 `a65576e376466ffba239a98ab59b8abd1ff799e2`。上游默认分支目前不是 main，勿直接用 HEAD 替换。官方配方内部仍下载 npm `latest` 和 Hermes 安装器，并非完全可复现的依赖锁定。

**本地修正**：2026-11-06 原版构建失败，Hermes 安装器实际克隆到 `/root/.hermes/hermes-agent`，Dockerfile 却链接到不存在的 `/usr/local/lib/hermes-agent`。副本只修正这一链接步骤（检查真实安装目录、创建 memory 父目录后链接），镜像标签为 `a65576e-pathfix`。此部署只验证 Gateway，不承诺新版 Hermes provider 可用。

## 运行方式与边界

- 对外 HTTP：`http://127.0.0.1:8420`，只发布到宿主机回环地址。
- 以官方镜像运行 Gateway；覆盖默认 CMD，避免生成含密钥的 Hermes 配置。镜像内仍包含 Hermes，但不启动、不配置它；不改宿主机 Hermes。
- DeepSeek 官方 API `https://api.deepseek.com`，模型 `deepseek-flash`；复用 DSH Key，关闭思考以执行记忆提取。调用会消耗 API 额度。
- 本地 SQLite + 文件存储；Embedding 和上下文 offload 暂关，使用关键词召回。
- `/health` 无鉴权，其余业务请求使用独立 Bearer token；关闭跨域允许列表。
- DSH / Codex 尚未接入。HTTP Gateway 不是 MCP，自动采集/召回仍需宿主适配。
- 当前适合单用户可信客户端共用，不将 session_key 或单个共享 token 视为多租户安全边界。

## 文件与数据

| 内容 | 位置 |
| --- | --- |
| Git 源配置 | `$(chezmoi source-path)/dot_config/tencentdb-memory/` |
| 部署后的配置 | `~/.config/tencentdb-memory/` |
| 本机私密文件（不在 Git） | `~/.local/share/tencentdb-memory/secrets/` |
| 持久化数据 | Docker 命名卷 `tencentdb-memory-data` → 容器 `/opt/data` |
| 实际记忆目录 | 容器 `/opt/data/tdai-memory` |
| 运行日志 | Docker json-file，最多 3 × 10 MB |

Compose secrets 是本机 0600 文件的只读挂载，不是加密保险箱；Docker 管理员仍能读取。只复制 DeepSeek Key，不挂载整个 DSH 凭据库。容器重建不会丢数据，但重建不会自动刷新已复制的 Key。

配置属于工作站工具，不要求 `machineRole=home-server`。不在该目录存放 runtime、密钥、依赖或备份，避免被 chezmoi 管理。

## 首次安装

前提：Docker Engine / OrbStack、Compose、chezmoi、Python 3；首次构建包含 Hermes 和系统依赖，体积较大。

```bash
# 仅部署本组件，不运行全仓 apply scripts
chezmoi apply --exclude=scripts ~/.config/tencentdb-memory
cd ~/.config/tencentdb-memory

# 优先读 DEEPSEEK_API_KEY 环境变量，否则读取 DSH_HOME/.credentials.yaml
# 默认 DSH_HOME=~/.config/dsh；不输出密钥，不覆盖已有不同值
python3 prepare-secrets.py

docker compose config --quiet
docker compose --project-directory "$(chezmoi source-path)/dot_config/tencentdb-memory" build gateway
docker compose up -d --wait --wait-timeout 120
curl -fsS http://127.0.0.1:8420/health
```

新机器没有 DSH Key 时，可在可信 shell 通过安全输入提供 `DEEPSEEK_API_KEY`，勿将真实密钥写进命令历史。初始化脚本生成独立 Gateway token，重复执行保留原值。

## 日常管理

以下命令在 `~/.config/tencentdb-memory` 执行：

```bash
docker compose ps
docker compose logs --tail=100 gateway
docker compose stop                  # 暂停，保留容器和数据
docker compose start                 # 恢复
docker compose restart gateway
docker compose down                  # 卸载运行实例，保留记忆卷
```

修改环境变量或 secret 后用 `docker compose up -d --force-recreate --wait`，仅 restart 不会应用新的 Compose 环境配置。`unless-stopped` 依赖 Docker 引擎启动，不额外安装 LaunchAgent。

## 调用接口

不要把 DeepSeek Key 当 Gateway token，也不要将 token 放入 URL。

```bash
python3 - <<'PY'
import json, urllib.request
from pathlib import Path
token = (Path.home()/'.local/share/tencentdb-memory/secrets/gateway-api-key').read_text().strip()
body = json.dumps({'query':'部署配置','session_key':'personal:demo'}).encode()
req = urllib.request.Request('http://127.0.0.1:8420/recall', data=body,
    headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
with urllib.request.urlopen(req, timeout=30) as response:
    print(response.read().decode())
PY
```

官方接口：`POST /capture`、`/recall`、`/search/memories`、`/search/conversations`、`/session/end`、`/seed`。`/capture` 需要 `user_content`、`assistant_content`、`session_key`；不要发送真实数据来做无必要的测试。健康检查不证明 LLM 可用，需要额外检查提取结果。

## 升级与备份

升级前停服务备份整个卷（含 SQLite、Markdown 和 JSONL），保留旧镜像 ID；确认数据迁移兼容后再换版本。不要仅复制运行中的 SQLite 主文件，也不要全局 `docker system prune`。

```bash
docker compose images
docker image inspect local/tencentdb-memory:a65576e-pathfix --format '{{.Id}}'
# 更新 compose.yaml 中的官方提交和镜像标签后：
docker compose --project-directory "$(chezmoi source-path)/dot_config/tencentdb-memory" build --pull gateway
docker compose up -d --force-recreate --wait
```

同一个固定配方的缓存构建不会刷新 npm latest；`--no-cache` 会刷新依赖，也可能引入不兼容，不能视为安全升级。需要严格回滚时保留并使用已验证的镜像 ID。

## 卸载与密钥轮换

1. 先移除客户端适配（若后续安装过），执行 `docker compose down`。
2. 若只是停用，到此即可；配置、secret、记忆卷保留。
3. 完全清除记忆需明确确认并备份后执行 `docker volume rm tencentdb-memory-data`，不可恢复。
4. 本机 secret 目录和镜像可分别清理；不要删除 DSH 原始 Key 或其它服务的缓存/镜像。若删除受 chezmoi 管理的配置，应同时从 source 移除，否则下一次 apply 会恢复。
5. 轮换 Key 时更新本机 secret 文件、保持 0600，再重建容器；DSH Key 更换不会自动同步本地副本。

## 2026-11-06 实测与限制

- macOS arm64 / OrbStack 构建成功；镜像 ID：`sha256:61dbb144a6b30847e9790074d0f6e87bdb81aff343b8cee5412b26563ea4f485`。实际 npm 插件 **1.0.3**、Node **22.23.4**；注意 `/health` 报的 `version=0.1.0` 是 Gateway 内部版本，不是 npm 版本。
- DeepSeek `deepseek-flash` 实际调用成功；Gateway 健康检查、无 token 返回 401、有 token 召回返回 200 均通过。
- 隔离临时实例验证了 L0 采集与中文检索、达到轮次阈值后经 DeepSeek 提取 L1、FTS 检索到 PostgreSQL 偏好。测试数据写在临时容器 `/tmp/tdai-smoke`，不写入正式记忆目录。
- **上游缺陷，未修改核心**：一次新 session 首轮 `/capture` 返回 `l0_recorded=0`，日志显示默认消息时间戳与初始 cursor 同毫秒，被 `> cursor` 增量过滤；正式适配必须验证实际写入，不能只看 HTTP 200。另观察 `/session/end` 返回 `flushed=true` 后未立即提取，阈值触发才完成；不把 flush 响应当作持久化提取完成凭据。
- 未验证 L2/L3 质量、长期运行、多用户隔离、Embedding 和 offload。此部署是可用的本地试用后端，不代表上述上游问题已解决。
- 官方 npm 构建报告 25 个依赖漏洞（23 moderate、2 high），未做全面漏洞审计或强制升级。启动有私有 observability/integrations 缺失后退回 standalone、sqlite-vec loader 回退告警；本轮 SQLite 与检索可用。不对外网开放。
- 构建从 chezmoi source 目录运行：BuildKit 默认拒绝部署目录中的 Dockerfile 外部软链接。Dockerfile 专用 ignore 文件限制构建上下文。

## 上游参考

- [官方说明](https://github.com/TencentCloud/tencentdb-agent-memory/blob/main/README.md)
- [固定版官方 Dockerfile](https://github.com/TencentCloud/tencentdb-agent-memory/blob/a65576e376466ffba239a98ab59b8abd1ff799e2/docker/opensource/Dockerfile.hermes)
- [Gateway 接口实现](https://github.com/TencentCloud/tencentdb-agent-memory/blob/main/src/gateway/server.ts)
