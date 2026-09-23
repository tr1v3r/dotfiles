#!/usr/bin/env bash
# =============================================================================
# refresh-pi-ai.sh — 升级 dsh 后重做 pi-ai 模型目录「物理换装」
#
# 用途一句话：
#   把全局 dsh 安装树里的 @earendil-works/pi-ai 整目录替换成指定版本（默认
#   0.87.1），使 TUI / headless / web 各 profile 的模型选择器拿到新版模型目录
#   （catalog，静态快照，不联网刷新）。
#
# ── 为什么需要这个脚本（背景机制）────────────────────────────────────────────
# 1. dsh TUI 的 openai-codex / anthropic / xai 三条 OAuth 订阅路由由第三方插件
#    dsh-auth 挂载，但模型列表不是它自带的：dsh-auth 在 boot 时按
#    「dsh-llm-pi-ai 所解析的那份 pi-ai」的解析链找到 pi-ai 包，并原样挂载其
#    dist/providers/all.js 里的静态目录快照（生成时间可用
#    getBuiltinModelDataGeneratedAt() 查看）。
# 2. 该目录随包发布、**不联网刷新**：OpenAI 发了新模型，必须等到 pi-ai 上游
#    更新目录、且本机那份被换上去，TUI 里才看得到。
# 3. 官方升级路径走不通（2026-09-23 全量核实）：
#      · dsh-llm-pi-ai 所有已发布版本（0.1.5-rc.1/rc.2/rc.3、0.1.6-alpha.x、
#        0.1.7-alpha.1）都依赖 pi-ai ^0.85.1 —— 0.x 的 caret 不跨 minor，
#        `npm i -g @deepseek-ai/dsh@next/alpha` 解析到的仍是 0.85.x；
#      · dsh-auth 的 config.modelOverrides 只能改目录里**已有**模型的字段，
#        目录中不存在的 id 会直接 boot 抛错（不能用来「加」新模型）；
#      · settings.yaml 的 llm-pi-ai.providers **绝不能**声明 openai-codex
#        （与 dsh-auth 的注册冲突，pi-ai 批量注册 all-or-nothing，会连带拖垮
#        zai-coding-cn，见 dsh/AGENTS.md「路由注册冲突」一节）。
#    所以唯一能立即生效的手段，就是本脚本做的目录物理替换。
#
# ── 为什么不用 `npm i --no-save @earendil-works/pi-ai@<ver>`（实测无效）──────
# 在全局 dsh 包目录里跑 npm i，arborist 会发现 ^0.85.1 不匹配新版本，于是把
# 0.85.1 嵌套装进 dsh-llm-pi-ai/node_modules/ 保其依赖满足；Node 从
# dsh-llm-pi-ai 解析 pi-ai 时先命中这个嵌套旧副本——换了个寂寞。必须物理替换
# hoisted 位置上的整个目录（本脚本做法）。同理，裸 `npm i -g` 装到全局根的
# 副本也不在解析路径上，同样是无效操作。
#
# ── 会被什么覆盖 / 什么不影响 / 如何还原 ────────────────────────────────────
# * `npm i -g @deepseek-ai/dsh@<任意版本>`（含同版本重装）会整树重建，把换装
#   还原成 0.85.x，并连带删掉旁边的 .bak 备份 —— **升级 dsh 后重跑本脚本**；
# * TUI 的 /update、`dsh plugin …` 只动 profile 目录，不影响换装；
# * 还原：rm -rf 换装目录，再把同目录的 pi-ai.bak-<旧版本> 改回名 pi-ai；
# * 脚本只保留「上一版」的 .bak（重复执行会先清掉旧备份再留新的）。
#
# ── 用法 ────────────────────────────────────────────────────────────────────
#   refresh-pi-ai.sh [version] [-f|--force]
#     version    目标 pi-ai 版本（默认 0.87.1；上游发新版后可换更新版本号）
#     -f         当前已是目标版本时仍强制重装
#     -h         打印本说明
#   换完**必须重启 TUI / 各 profile 会话**：模型注册表在 boot 时构建，
#   settings.yaml 的热加载不会重新解析目录。
#
# ── 换装记录 ────────────────────────────────────────────────────────────────
# 2026-09-23 首次：0.85.1（catalog 2026-09-05）→ 0.87.1（catalog 2026-09-22）。
#   openai-codex 路由：+gpt-6-luna +gpt-6-sol −gpt-5.4 −gpt-5.4-mini；
#   openai 路由：      +gpt-6-luna +gpt-6-sol；
#   zai-coding-cn 目录自此自带 glm-5.3 / glm-5.3-flash / glm-5.3-highspeed
#   （settings.yaml 的 zai 手写 models 列表可精简回纯 id 列表；不改也无害，
#   settings 覆盖优先，models 整体替换语义见 dsh/AGENTS.md）。
# =============================================================================

set -euo pipefail

# -h/--help：打印文件头部的完整说明（到 set -euo 为止）
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  awk '/^set -euo/{exit} /^# =+$/{f=1} f{print}' "$0"
  exit 0
fi

# ── 参数解析 ─────────────────────────────────────────────────────────────────
TARGET_VERSION="0.87.1"   # 默认换装目标；上游出 0.88+ 后可显式传参跟上
FORCE=0
for a in "$@"; do
  case "$a" in
    -f|--force) FORCE=1 ;;
    *) TARGET_VERSION="$a" ;;
  esac
done

# ── 定位全局 dsh 树 ──────────────────────────────────────────────────────────
GLOBAL_ROOT="$(npm root -g)"                       # fnm 的 node 版本目录
DSH_NM="$GLOBAL_ROOT/@deepseek-ai/dsh/node_modules"
TARGET="$DSH_NM/@earendil-works/pi-ai"

[[ -d "$GLOBAL_ROOT/@deepseek-ai/dsh" ]] || {
  echo "✗ 未找到全局 dsh 安装：$GLOBAL_ROOT/@deepseek-ai/dsh" >&2; exit 1; }
[[ -d "$TARGET" ]] || {
  echo "✗ 未找到 pi-ai 目录（dsh 安装结构有变？）：$TARGET" >&2; exit 1; }

CURRENT_VERSION="$(node -p "require('$TARGET/package.json').version")"

# 同版本且未强制 → 幂等退出
if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" && "$FORCE" -eq 0 ]]; then
  echo "✓ 当前已是 pi-ai ${CURRENT_VERSION}，无需换装（强制重装请加 -f）"
  exit 0
fi

echo "→ pi-ai $CURRENT_VERSION → $TARGET_VERSION"

# ── 第 1 步：下载 + 解包 + 预验（全部发生在临时目录，失败不影响线上目录）──────
# --cache 指到脚本自己的临时目录：不依赖用户默认 ~/.npm（若被 sudo npm 写入
# root-owned 文件会 EPERM，见 https://npm.im 说明的 chown 修复），代价是每次
# 冷下载几 MB，换确定性。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

( cd "$TMP" && npm pack --silent --cache "$TMP/npm-cache" \
    "@earendil-works/pi-ai@$TARGET_VERSION" >/dev/null )
TGZ="$TMP/earendil-works-pi-ai-$TARGET_VERSION.tgz"
[[ -f "$TGZ" ]] || { echo "✗ npm pack 产物未找到（版本号存在吗？）" >&2; exit 1; }

mkdir -p "$TMP/pkg"
# npm 包 tarball 顶层是 package/ 目录，剥掉前缀让内容直接落在 pkg/ 下
tar -xzf "$TGZ" -C "$TMP/pkg" --strip-components 1

PACKED="$(node -p "require('$TMP/pkg/package.json').version")"
[[ "$PACKED" == "$TARGET_VERSION" ]] || {
  echo "✗ 解包版本 $PACKED 与目标 $TARGET_VERSION 不符" >&2; exit 1; }
node -e "require('$TMP/pkg/dist/providers/all.js')"   # catalog 可加载性预检

# ── 第 2 步：备份并替换（此刻才动线上目录；任何失败立即回滚）────────────────
BAK="$TARGET.bak-$CURRENT_VERSION"
rm -rf "$BAK"                       # 只保留最近一版备份
mv "$TARGET" "$BAK"
if ! mkdir -p "$TARGET" || ! cp -R "$TMP/pkg/." "$TARGET/"; then
  echo "✗ 替换失败，回滚到 $BAK" >&2
  rm -rf "$TARGET"
  mv "$BAK" "$TARGET"
  exit 1
fi

# ── 第 3 步：落位校验 + 各关键路由的模型增删报告 ─────────────────────────────
NEW_CATALOG_DATE="$(node -p "
  const a = require('$TARGET/dist/providers/all.js');
  new Date(a.getBuiltinModelDataGeneratedAt()).toISOString().slice(0, 10)
")"
echo "✓ 落位完成，新 catalog 生成时间：$NEW_CATALOG_DATE"

node -e "
const load = (d) => require(d + '/dist/providers/all.js');
const old = load('$BAK'), neu = load('$TARGET');
const ids = (m, r) => { try { return m.getBuiltinModels(r).map(x => x.id); } catch { return []; } };
// 关注 OAuth 订阅三路由 + API key 的 openai + 本机在用的 zai
for (const r of ['openai-codex', 'anthropic', 'xai', 'openai', 'zai-coding-cn']) {
  const a = ids(old, r), b = ids(neu, r);
  const add = b.filter(x => !a.includes(x)), rem = a.filter(x => !b.includes(x));
  if (add.length || rem.length)
    console.log('  ' + r + ' 路由: 新增 ' + JSON.stringify(add) + '  移除 ' + JSON.stringify(rem));
  else
    console.log('  ' + r + ' 路由: 无变化');
}
"

# ── 收尾提示 ─────────────────────────────────────────────────────────────────
echo
echo "✓ 换装完成：pi-ai $CURRENT_VERSION → $TARGET_VERSION"
echo "  · 重启 TUI / 会话后生效（模型注册表在 boot 时构建，热加载不重解析目录）"
echo "  · 还原：rm -rf '$TARGET' && mv '$BAK' '$TARGET'"
echo "  · 提醒：npm i -g @deepseek-ai/dsh 会把换装还原成 0.85.x，升级后重跑本脚本"
