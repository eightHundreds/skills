---
name: worktree-setup
description: >
  Worktree setup: one-time Git-only provisioning so later `git worktree add`
  copies a gitignored whitelist and runs bootstrap. Use when the user wants
  worktree 初始化, 配置 worktree 环境, 新 worktree 自动复制 .env,
  post-checkout bootstrap, refresh `.worktree/copy` / `.worktree/bootstrap.sh`,
  or /worktree-setup. Not for installing wt/Worktrunk/wtp, wrapping
  `git worktree add`, or a one-off worktree with no repo-wide setup.
---

# Worktree setup

本 skill 是安装器。生成 `.worktree/copy`、`.worktree/bootstrap.sh`，并把 dispatcher 装进 `GIT_COMMON_DIR/hooks/post-checkout`。之后只依赖原生 `git worktree add`。

禁止：安装 wt/Worktrunk/wtp；改 `git worktree add` 包装器；把 `core.hooksPath` 指到仓库内相对路径。

## 步骤

### 1. 审计仓库

在当前 git 仓库里自己找证据，不要先问用户能从文件读到的事实。

完成：写出三份清单，每项带证据路径。

- **copy 候选**：主 worktree 里真实存在、且被 ignore 的本地文件（`.env`、`.env.local`、`.mcp.json`、未跟踪的 `config/local.*`）。不把 `node_modules`、`.venv`、`dist`、`.next`、`target`、缓存目录放进 copy。
- **bootstrap 候选**：lockfile / `package.json#packageManager` / `prisma` / `.gitmodules` / Makefile 的 `setup|bootstrap` 目标。只收「新 worktree 不能跑起来就会缺」的命令。不要起 dev server、不要 migrate 数据库、不要 `docker compose up`。
- **hook 现状**：`git config --get core.hooksPath`、`$(git rev-parse --git-common-dir)/hooks/post-checkout` 是否已存在、是否 Husky。

### 2. 先交草案

把推荐的 copy 列表和 bootstrap 命令摊开。只问审计无法决定的判断（例如某个本地 DB 目录要不要 copy）。用户已经指定 Git-only 架构时，不要再推销外部 worktree CLI。

完成：用户能对照草案说「按这个写」，或你已按用户事先给定的架构执行。

### 3. 写入配置

在**主 worktree**根目录写入（不要写进 linked worktree）：

`.worktree/copy`：一行一个仓库相对路径。读入时先 trim；trim 后空行和 `#` 开头的行忽略。禁止绝对路径；按路径分量拒绝 `..`（`foo..bar` 合法）。目标已存在则 skip。解析后不在主树内的条目 skip（含中间分量 symlink、多层 symlink、指向主树外的 symlink）。目录条目不把主树外 symlink 带进新 worktree。dest 解析后必须落在新 worktree 内（含已存在的 dest 中间 symlink），否则 skip。

`.worktree/bootstrap.sh`：`set -eu`；cwd 是新 worktree；可用 `$WORKTREE_SETUP_MAIN` 与 `$WORKTREE_SETUP_NEW`（主树 / 新 worktree 的物理绝对路径）。幂等；缺文件就跳过；不要打印密钥文件内容。若要对主 worktree 跑 git：`unset $(git rev-parse --local-env-vars)`。

完成：这两个文件已在磁盘上，路径都合法。

### 4. 安装 dispatcher

在仓库根执行本 skill 的 `scripts/install-hook.sh`。不要改 `core.hooksPath`。

脚本会：

- 把 dispatcher 装进 `GIT_COMMON_DIR/hooks/post-checkout`。
- 已有 `post-checkout`（含不可执行的 sample）则移到 `post-checkout.pre-worktree-setup` 再链；不要直接覆盖。
- `core.hooksPath` 像 `.husky/_`（含 `./.husky/_`）时：不改 hooksPath；按 hooksPath 原值定位（相对路径相对主树、绝对路径须仍在主树内；已存在祖先解析后若逃出主树则拒绝，不要先 `mkdir` 再分辨）。幂等写入/合并该 Husky 目录下的 `post-checkout`（不跟随 symlink 写；dispatcher 非零不得被后续 `true` 盖掉；`.husky/_` 在无 `h` 时仍跑 dispatcher）。用户侧 hook 与 `hooksPath` 下的 `post-checkout` stub 都合并（不覆盖已有内容；已跟踪但尚无 bridge 标记的 stub 不得跳过），并 `git add -f`。脚本不 commit：新 worktree 只 checkout 已提交文件，Husky 仓要把桥接路径提交后 Git 才能在新树执行到它。Husky 桥接由脚本完成，不要手写一份。

完成：`$(git rev-parse --git-common-dir)/hooks/post-checkout` 可执行且含 `worktree-setup: dispatcher`。Husky 仓还要指出新 worktree checkout 后实际会跑到的 hook 路径（须已提交）。

### 5. 验收

1. copy 列表里每个源文件在主 worktree 上存在；`sh -n .worktree/bootstrap.sh` 通过。
2. 跑本 skill 的 `sh scripts/check.sh`（临时仓库：`git worktree add` 复制 `.env`、bootstrap 跑完且 `$WORKTREE_SETUP_MAIN` / `$WORKTREE_SETUP_NEW` 与主树 / 新树物理路径一致（`pwd -P`）、主树不误跑、不安全路径跳过——含 `..`、绝对路径、主树外 symlink / 多层链 / 中间分量 / 目录内跳出的 symlink / dest 中间 symlink 逃出新树，新 worktree 不得出现 `outside-secret` 或 `/etc/passwd`；可执行旧 hook 被链；Husky stub 不盖掉 dispatcher 非零；安装不跟随 symlink 写 hook）。
3. 用户允许时：在本仓库 `git worktree add` 一个临时目录，确认白名单已复制且 bootstrap 退出 0，然后 `git worktree remove`。

完成：向用户报告安装了哪些文件、以后的命令就是 `git worktree add <path> -b <branch>`、新 clone 需要再跑一次步骤 4。

## 扫描

| 信号 | 推断 |
|---|---|
| `.env` / `.env.*`（存在且 ignored） | copy |
| `.env.example` | 只作线索，不 copy example 本身除非用户要 |
| `pnpm-lock.yaml` | `pnpm install` |
| `yarn.lock` | `yarn install` |
| `bun.lock` / `bun.lockb` | `bun install` |
| `package-lock.json` | `npm ci` |
| `package.json#packageManager` | 覆盖上面的包管理器选择 |
| `uv.lock` | `uv sync` |
| `prisma/schema.prisma` | 用当前包管理器 `exec prisma generate` |
| `.gitmodules` | `git submodule update --init --recursive` |
| `Makefile` 含 setup/bootstrap | 写进草案，默认不自动 `make` |

展开审计：README / CONTRIBUTING 的 Local setup、CI install 步骤、未出现在表里的顶层 ignored 文件。

## Dispatcher 契约

Git 在 `git worktree add`（非 `--no-checkout`）后跑 `post-checkout`，参数为 null OID、新 HEAD、flag=`1`。cwd 是新 worktree。flag 不是 `1` 时不工作（文件 checkout 不跑 copy/bootstrap）。

dispatcher（`scripts/post-checkout`）只在 **linked worktree 且 old HEAD 为 null OID 且 flag=1** 时工作；clone/主 worktree/普通切分支不跑 bootstrap。白名单和脚本**始终读自主 worktree**，这样旧分支没有 `.worktree/` 也能初始化。

环境变量：`$WORKTREE_SETUP_MAIN`（主树物理路径）、`$WORKTREE_SETUP_NEW`（新 worktree 物理路径）。copy 单项失败只记录并继续（仍跑剩余 copy、bootstrap、链式旧 hook）。目标已存在则 skip copy。
