# Issue tracker: GitHub

Issues 和 specs 存放在 `Nanaloveyuki/vellum` 的 GitHub Issues，使用 `gh` CLI。在仓库内由 remote 推断目标；仓库外指定 `--repo Nanaloveyuki/vellum`。

## 操作

- 发布到 tracker：`gh issue create --title "..." --body "..."`；多行正文用带引号分隔符的 heredoc 经 `--body-file -` 输入。
- 读取 ticket：`gh issue view <number> --json number,title,body,labels,comments`。
- 列出 issues：`gh issue list --state open --json number,title,body,labels,comments`；按需添加 `--label`、`--state`。
- 评论：`gh issue comment <number> --body "..."`。
- 标签：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`；triage 名称见 [triage-labels.md](triage-labels.md)。
- 关闭：`gh issue close <number> --comment "..."`。

## 父子 tickets 与依赖

适用于 `to-tickets`、`wayfinder` 等工作流：

- Sub-issue：`gh issue create --parent <parent> ...`，或 `gh issue edit <parent> --add-sub-issue <child>`（`gh` 2.94+）。旧版 CLI 可用 `gh api --method POST repos/Nanaloveyuki/vellum/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`。
- Blocking：使用原生 issue dependencies：`gh api --method POST repos/Nanaloveyuki/vellum/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`。
- 上述 API 使用数字数据库 id：`gh api repos/Nanaloveyuki/vellum/issues/<n> --jq .id`，不是 issue number 或 `node_id`。
- `issue_dependencies_summary.blocked_by` 统计未关闭的 blockers；所有 blockers 关闭后才解除阻塞。
- 原生 sub-issues 不可用时，父 issue 用任务列表列出 children，子 issue 正文首行写 `Part of #<parent>`。原生依赖不可用时，子 issue 写 `Blocked by: #<n>, #<n>`，逐个检查引用 issue 是否关闭。

## Pull requests as a triage surface

**PRs as a request surface: no.**
