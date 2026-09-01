# skills

个人设计的 agent skills，收录经常用的流程。

给 Agent 的仓库约定见 [AGENTS.md](AGENTS.md)。

## 技能

- [worktree-setup](skills/worktree-setup/SKILL.md) — 一次性 Git-only 配置：之后 `git worktree add` 会复制白名单（如 `.env`）并跑 bootstrap。不依赖 wt/Worktrunk。

## 布局

```
skills/<name>/
  SKILL.md
```

`skills/` 下的目录就是清单。

## 新增

在 `skills/<name>/` 写入 `SKILL.md`。
