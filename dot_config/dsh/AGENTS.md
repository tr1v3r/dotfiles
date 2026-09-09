# dsh/ — DeepSeek Harness 配置

本目录是 **DeepSeek Harness（dsh）** 的机器配置（`DSH_HOME=~/.config/dsh`），
属于 dotfiles 仓库（`tr1v3r/dotfiles`，主分支 `master`，活跃分支 `dev`）的一部分。
根目录 `AGENTS.md` 描述整个仓库；本文件描述 dsh 特有机制、坑与维护约定。

## 这是什么

`dsh` 是 DeepSeek Harness 的 CLI（npm 包 `@deepseek-ai/dsh`，本机 **0.1.2-rc.1**，全局安装在
fnm 的 node 版本目录下）。它不是单体应用，而是 **profile 启动器**：每个 profile 是
一组插件组合包（bundle）按顺序 patch 叠加出来的 Cordis 插件树。

```sh
dsh --profile dsh-tui                  # 交互式 TUI（本机主要入口）
dsh --profile headless "task"          # 一次性任务，打印答案退出
dsh --profile web                      # Web 界面（dsh web 别名）
dsh --profile <name> --dump-config     # 打印组合后的配置树（不启动）
dsh --profile <name> --dump-default-config
dsh plugin --profile <name> <pnpm args> # 管理 profile 的插件（pnpm 转发）
```

## 目录结构

```
dsh/
├── FIRECRAWL.md           # 本地部署、MCP 接入、使用与排障
├── settings.yaml          # 全局设置文档（热加载，见下）
├── cordis.patch.yml       # home 级 patch 层（本机当前为空）
├── .gitignore             # 秘密/运行时状态忽略规则（见「git 约定」）
├── profiles/
│   ├── dsh-tui/           # 交互式 TUI profile（@deepseek-harness-tui/dsh-tui）
│   ├── headless/          # 一次性任务 profile（官方 @deepseek-ai/dsh-headless）
│   └── web/               # Web profile（第三方 @linxin666/dsh-web-ui-all 等）
├── sessions/              # 会话日志（jsonl.zstd，已忽略）
├── storages/ memory/ task-board/ attachments/ …  # 运行时状态（已忽略）
├── dsh-auth/              # ⚠️ OAuth 令牌存储（已忽略，见下）
└── skills/                # 外部 skill（从上游仓库克隆，已忽略）
```

本地 Firecrawl 的部署、MCP 配置、验证与排障见 [`FIRECRAWL.md`](FIRECRAWL.md)。

## Profile 机制

- 每个 profile 目录有 `package.json`（含 `dsh.profile.bundles` 列表）、`cordis.yml`
  （空根，占位用，**不要编辑**）、`cordis.patch.yml`（用户的 patch 层，**编辑这个**；
  2026-09-08 起源文件是 `cordis.patch.yml.tmpl`——chezmoi 模板渲染 `{{ .chezmoi.homeDir }}`，
  目标部署为渲染后的真实文件**而非 symlink**：改源后要 `chezmoi apply`，直接改 live
  文件会与源漂移）。
- 配置树叠加顺序：`bundles` 各组合包的 patch → profile 的 `cordis.patch.yml` →
  home 级 `$DSH_HOME/cordis.patch.yml` → `--patch` 覆盖层。
- bundle 解析：先找 dsh 安装目录（`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-headless` 等），
  再找 profile 自身 `node_modules`。
- patch 按 `id` 定位行、**整体替换 `config`**（不做字段级合并）；后写的赢。
- dsh-tui profile 当前 bundles：`@deepseek-ai/dsh-base` + `@deepseek-harness-tui/dsh-tui`（0.10.0-beta.5）。
- `profiles/*/cordis.yml`、`pnpm-lock.yaml`、`node_modules/` 都被 gitignore（dsh/.gitignore），
  不要尝试提交。

## settings.yaml — 全局设置文档

由 `@deepseek-ai/dsh-settings-file` 插件读取（默认路径 `$DSH_HOME/settings.yaml`），
**watcher 热加载**，外部编辑即生效（多数 namespace 为 `applies: live`）。
文档按 namespace 分节；各消费方插件注册自己的 schema，组合 base（entry config）之上
叠加用户层。当前分节：

| namespace | 消费方 | 说明 |
|---|---|---|
| `agent-default-model` | dsh-agent-default-model | 新会话默认模型 `{provider, model, reasoningEffort}` |
| `llm-pi-ai` | dsh-llm-pi-ai | 多提供方适配器的 providers 字典（核心！） |
| `llm-deepseek` | dsh-llm-deepseek | DeepSeek 官方适配器（本机未覆盖，走 entry 默认） |
| `dsh-tui` / `dsh-better-sidebar` / `dsh-ssh` / `pet` | TUI 相关 | 界面/宠物/终端字体 |

⚠️ 关键语义（踩过坑）：`llm-pi-ai.providers` 是**字典**，`models` 列表**整体替换**
该路由的 pi-ai 内置 catalog（不是追加）；分节 schema 校验失败时 settings seam 保留
上一份可用值并告警，不写盘。

## LLM 适配器体系与 ⚠️ 路由注册冲突（重要）

TUI 树里同时存在三个 LLM 适配器：

1. **`llm-deepseek`**（`@deepseek-ai/dsh-llm-deepseek`）— 原生 DeepSeek 适配器，
   独占路由 `deepseek-official`，key 走 `DEEPSEEK_API_KEY`。TUI bundle 把它设为
   默认（`thinking: enabled, reasoningEffort: max`）。
2. **`llm-pi-ai`**（`@deepseek-ai/dsh-llm-pi-ai`）— 多提供方适配器，**dormant 挂载**：
   零路由直到 settings 的 `llm-pi-ai:` 分节提供 providers。注册是**整批 all-or-nothing**：
   任一路由与已有注册冲突，整批被拒（记录日志并保留旧注册）。
3. **`dsh-tui-auth`**（`@deepseek-harness-tui/dsh-auth`，**第三方**，见下）— 启动时
   逐条单独注册 `openai-codex` / `anthropic` / `xai` 三条 OAuth 订阅路由（刻意单条
   注册：一条冲突不拖垮其余）。

### ⚠️ 已踩的坑（2026 修复，勿回退）

`settings.yaml` 的 `llm-pi-ai.providers` **绝不能声明 `openai-codex`（以及 anthropic/xai）**：
dsh-auth 先注册了这些路由，llm-pi-ai 批量注册 `[zai-coding-cn, openai-codex]` 时因
openai-codex 冲突而**整体失败** → `zai-coding-cn` 连带永不注册 → TUI 模型选择器
（只列 `ctx.llm.listProviders()` 的已注册路由）查不到 glm。
`agent-default-model` 仍会显示 zai-coding-cn，但发请求直接 `NO_ADAPTER` 失败。

修复：从 settings.yaml 删除 `openai-codex: {}` 行。验证：TUI 运行时 `zai-coding-cn`
注册成功，模型含 glm-5.3 / glm-5.3-flash；openai-codex 仍由 dsh-auth 服务（OAuth 订阅）。
**web profile 没有 dsh-auth**，需要 codex 时把 openai-codex 声明在
`dsh/profiles/web/cordis.patch.yml` 的 `llm-pi-ai` entry 配置里（settings seam 按
provider 合并，web 得到 openai-codex + zai-coding-cn 两条路由）——不要加回
settings.yaml，否则 TUI 冲突复发。

### dsh-auth 是谁的插件？

**不是 DeepSeek 官方（deepseek-ai）的**。`@deepseek-harness-tui/dsh-auth` v0.1.0 是
**dsh-TUI 作者 ccch1mneyyy** 的配套包（仓库 https://github.com/ccch1mneyyy/dsh-auth ），
随 `@deepseek-harness-tui/dsh-tui` 捆绑安装（profile node_modules 的嵌套依赖），
由 TUI bundle 的 `dsh-tui-auth` 条目挂载（`@deepseek-harness-tui/dsh-tui/oauth`）。
功能：ChatGPT/Codex、Claude Pro/Max、SuperGrok 订阅账号 OAuth 登录（`/auth` 命令），
登录后把订阅额度挂成 LLM 路由。它把 OAuth access/refresh token 存到
`$DSH_HOME/dsh-auth/credentials.json` —— **敏感文件，已被 gitignore**。
不用订阅登录可关：`dsh/profiles/dsh-tui/cordis.patch.yml` 里 `- id: dsh-tui-auth, disabled: true`。

## 模型目录（pi-ai）

- pi-ai（`@earendil-works/pi-ai`）**0.82.1**：全局 dsh 安装与 TUI profile 各有一份。
- 内置 catalog 提供方列表可用 `node -e` 读 `dist/providers/all.js` 的
  `getBuiltinProviders()` / `getBuiltinModels('<route>')` 查看。
- `zai-coding-cn` 是 catalog 路由（`https://open.bigmodel.cn/api/coding/paas/v4`，
  openai-completions，thinkingFormat zai），0.82.1 目录只到 **glm-5v-turbo**；
  glm-5.3 / glm-5.3-flash 在 settings.yaml 手工声明（1M context、maxTokens 131072
  必须显式声明否则落兜底 32768、reasoningEfforts low/high/max、
  `compat.supportsReasoningEffort: true` 覆盖路由级 false）。
- 模型选择器/`/provider` 向导的数据来自 `ctx.llm` 注册表 + settings seam，不联网。

## 调试技巧

- 组合树：`dsh --profile dsh-tui --dump-config`。
- **运行时 probe**（settings seam 生效与否只能运行时看）：用 `@deepseek-ai/dsh-app-boot`
  的 `boot()` 手动 boot profile（patches 用 `loadProfile` + bundle layers 拼），
  需伪造 `process.stdout.isTTY = true`（TUI 要求 TTY）、provide
  `DSH_LAUNCH_ENVIRONMENT_KEY` 与 `provideCmdline`。可查
  `ctx.llm.listProviders()` / `listModels(provider)` / `ctx.agentDefaultModel.currentSelection()`
  / `ctx.settings.describe()`。
- 想看是谁注册/拒绝路由：用 `--experimental-loader` 包装 `dsh-llm-pi-ai/lib/index.js`
  源码，在 `registerAdapter` 处打日志 + 堆栈（dsh-auth 就是这么定位的）。
- 会话日志在 `sessions/<workspace-hash>/session.jsonl.zstd`（zstd 压缩，
  用 `/opt/homebrew/bin/zstdcat` 解压），可查实际请求的 provider/model。

## git 约定

- 活跃分支 `dev`；提交遵循 Conventional Commits（`chore(dsh/…)`、`fix(dsh)` 等）。
- `dsh/.gitignore`：秘密与运行时状态一律忽略（`.credentials.yaml`、`sessions/`、
  `storages/`、`memory/`、`task-board/`、`attachments/`、`dsh-builtin-browser-host/`、
  `llm-deepseek/`、`dsh-auth/`、`skills/`、`profiles/*/cordis.yml`、lockfile、node_modules）。
- ⚠️ gitignore 行内不支持 `#` 尾注释（会导致模式不匹配），要注释就单独一行。
- 新增的 dsh 运行时目录出现为 `??` 时，先判断是不是状态目录 → 补进 dsh/.gitignore，
  **不要**随手 `git add`。

## 维护备忘

- **⚠️ cordis.patch.yml 顶层 `- id:` ≠ 新增条目（2026-09-08 踩坑，勿回退）**：顶层
  `- id:` 是按 id 定位**组合树里已有条目**的 patch，id 不存在时整条被静默丢弃，
  `--dump-config` 只在输出头部留一行 `patch: entry "xxx" not found` 警告。新增插件
  实例（如 `mcp-zai-*` GLM MCP server）必须写进 `- insert:` 列表——它们曾以
  顶层 `- id:` 形式存在，dsh TUI/web 从未加载过 GLM MCP（`--dump-config | head`
  必查 not found 警告）。同批修复：stdio `command` 一律用 fnm 绝对路径
  （`~/.local/share/fnm/aliases/default/bin/npx`，源 `.tmpl` 由 chezmoi 渲染
  homeDir——**绝对路径不得写死 macOS 用户名**，2026-09-08 隐私审查：用户名即
  雇主名，公开仓库会坐实身份关联）——launchd 拉起的
  `com.dsh.doctor` PATH 无 fnm，裸 `npx` spawn 失败。GUI/launchd 进程读不到
  `~/.zshenv` 导出的 `ZAI_CODING_CN_API_KEY`，bigmodel MCP 会在 `tools/list`
  拿应用层 401（传输层 initialize 不鉴权，健康检查到 tools/list 才炸）；曾以
  LaunchAgent `local.env-secrets`（`launchctl setenv` 注入 GUI 域）解决，
  2026-09-08 移除，替代方案待定。
- **dsh-quote-followup 插件**（2026-09-07，独立仓库 `~/workspace/dsh-quote-followup`
  （github.com/tr1v3r/dsh-quote-followup，master 分支），仅 Web profile 依赖 npm 版
  `^0.2.5`，要求 DSH `>=0.1.2-rc.1`）：「选中对话内容→针对性追问」。0.2.1 起
  Web-only，TUI profile 已移除。0.2.3 通过 `inputTriggers` 注册 codec-only source，复用
  composer 已注册的 `ReferenceChipNode`，以原生对话 chip 展示引用；发送时 codec 再展开为
  模型可读 Markdown，旧 host 缺少 chip 能力时降级到纯文本。0.2.4 同时注入 `locale`，按钮、
  序列化引用框架随 DSH 中英文切换；chip 视觉标签只保留摘录正文，去掉冗余角色前缀。
  ⚠️ 四个运行时坑：① 不可直接
  改 contenteditable DOM；② Firefox 的合成 `ClipboardEvent` 可能丢 `clipboardData`，文本
  后备必须从 `__lexicalEditor._commands` 解析 `PASTE_COMMAND`；③ 旧页/hot swap 会残留
  mounted 锁和共用按钮，新 client 要用 versioned state + button ownership 接管；④ Web
  服务在 boot 时缓存 client bundle，更新包后必须同时**重启服务并刷新/重开旧页面**。
  回归：`npm test`；真实验证同时查 chip/DOM 与 `__lexicalEditor.getEditorState()`，并覆盖
  系统 Firefox。发布后改 profile 版本号，再在**实际 runtime target** 跑 `dsh plugin
  --profile web clean --lockfile && dsh plugin --profile web install --no-frozen-lockfile`；不要只在
  chezmoi source profile 跑 pnpm（两边 ignored node_modules 是两套目录）。
  pnpm-workspace.yaml 的 `minimumReleaseAgeExclude` 同步换新版本号。
- ⚠️ **dsh CLI 升级必须真实 boot 三个 profile**（2026-09-06 教训）：`--dump-config`
  只验证**配置组合**、不 import 插件模块——官方包（dsh-settings/dsh-llm 等）的
  导出面在 0.1.2-rc.1 变了，dump 全绿但 `dsh web` 起不来（插件 import 即炸）。
  验证法：web 直接 `dsh web` 看监听 URL；TUI 用伪 TTY
  `timeout 15 script -q /dev/null dsh --profile dsh-tui`（渲染出横幅即通过）；
  headless 跑一句话。已知未适配：`dsh-at-file`（≤0.6.3，import
  `settingsNamespace`）与 `dsh-fetch-file`（≤0.1.2，import `CallId`），已在
  `profiles/web/cordis.patch.yml` 里 `disabled: true` 顶住，**上游发适配版后
  删那两行解禁**。
- ⚠️ **升级 TUI 时必须重做 vimKeys 补丁**：改 `profiles/dsh-tui/package.json` 版本后跑
  `dsh plugin --profile dsh-tui install`（pnpm），并检查新版 bundle 是否新增
  路由/namespace（dsh-auth 这类第三方插件可能再次引入冲突）；然后把
  `patches/@deepseek-harness-tui__dsh-tui@<旧版>.patch` 对新基线重生成（文件名、
  `pnpm-workspace.yaml` 的 `patchedDependencies` 键同步改版本），`pnpm install` 验证
  三件事：补丁标记在、`vendor/` 仍为 ~1.1M、`node --check` 过。
  - ⚠️ **`/update` 会因旧补丁键整批失败**（2026-09-09 实测）：键按精确版本锁定，
    `/update` 换版本后旧键匹配不到任何依赖，pnpm 11 抛 `ERR_PNPM_UNUSED_PATCH` 中止
    **整个安装**（manifest/node_modules 保持原样，只有 `minimumReleaseAgeExclude` 被
    TUI 预置成新版本）→ 打印 resume 命令后退出。`updateTui()` 只预置
    allowBuilds/release-age，不会改写 patch 键。已给 profile 的 `pnpm-workspace.yaml`
    加 `allowUnusedPatches: true`：这类升级先装上去（仅 `[WARN] patches were not used`，
    期间 TUI 跑原版），补丁按上面的流程事后移植；也可用
    `--config.allowUnusedPatches=true` 临时绕过一次。
- ⚠️ **绝不对这个包跑 `pnpm patch-commit`**：tarball 里的 vendored 嵌套 node_modules
  （`vendor/dsh-std/**`，运行时 `plugin-spec/registry.js` 真的加载）在重新打包时会被
  整体丢掉（补丁记为 deleted、装出来 `vendor/` 0B，TUI 变砖）。正确做法：
  `pnpm patch` 拿到编辑目录 → 手工 `git diff --no-index` 生成单文件 diff（修掉
  `a/a/` 双层前缀）→ 放进 `patches/` + 挂 `patchedDependencies`。
- ⚠️ **settings.yaml 目标是真实文件不是 symlink**（settings seam 会运行时改写它，
  `ui-onboarding`/`pet`/`skin-*` 等分节即其持久化状态）。改 dsh 设置直接改
  `~/.config/dsh/settings.yaml`（热加载立即生效）；chezmoi 源里的副本只是新机器
  引导快照，`chezmoi apply` 会覆盖运行时状态——漂移是常态，别盲目 apply。
- vimKeys 机制：本地 pnpm patch 给 `/vim` NORMAL 态加了逐动作改键（settings
  `dsh-tui.vimKeys` 分节，colemak 键位见 settings.yaml；补丁只含机制零键位）。
  上游提案 https://github.com/ccch1mneyyy/dsh-TUI/discussions/777 ，认可后提 PR
  （fork 分支 `tr1v3r/dsh-TUI:feat/vim-normal-keys`）；合入后可撤本地补丁改用
  官方设置。（#777 正文 2026-09-06 已修复——首次发帖时 `--body-file` 误存了
  字面量占位符，勿再犯：GraphQL 传正文用 `-F body=@file`。）
- **行中 skill 手势补全/高亮**（2026-09-06，同一个 patch 文件里叠加）：
  内核 dsh-tool-skill 的 pre-step 钩子本来就注入用户消息里**所有**空白边界的
  `/name` token（SKILL_GESTURE，`matchAll`），所以 `/a /b 一句话` 或
  `请用 /a 和 /b …` 天然多 skill 同调；缺的只是输入侧 UX。patch 给
  PromptInput.js 加了 `skillGestureAtCaret`（镜像 @mention 的 caret-token 机制，
  offset-0 除外——那是命令浮层领地）+ 行中浮层（**只列 skill**，Enter/Tab 只替换
  该 token 不发送）+ 已知 skill 名的 accent 高亮（`rowHighlightPieces` 三段式，
  选区/caret 反显优先）。CommandSuggestions.js/.d.ts 加了可选 `title` prop
  （浮层标题显示「技能」）。上游提案 https://github.com/ccch1mneyyy/dsh-TUI/discussions/780 。
  升级 TUI 重生成
  patch 时**两个特性都要重做**（vimKeys + 本特性，改 5 个文件：
  PromptInput.js、CommandSuggestions.js/.d.ts、dsh-adapter/plugin.js、
  utils/keymap.js）。
- pi-ai 升级后：核对 `zai-coding-cn` 目录是否已含 glm-5.3+，若含则 settings.yaml 的
  models 列表可精简回纯 id 列表（仍是整体替换语义）。
- settings.yaml 是热加载的，但 TUI 模型选择器建议重启后查看；`/model` 手动切模型。
- 官方文档在安装包内：`@deepseek-ai/dsh/README.zh.md`、各插件包 `README.zh.md`
  （`dsh-llm-pi-ai`、`dsh-settings-file`、`dsh-agent-default-model` 等）；
  上游仓库：https://github.com/deepseek-ai/deepseek-harness 、https://github.com/ccch1mneyyy/dsh-TUI 。
