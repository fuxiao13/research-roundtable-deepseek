# Research Roundtable DeepSeek

一个由 Codex 主导、DeepSeek v4 Pro 辅助评审的研究方案与实验审查 skill。

Codex 是唯一的执行者、裁决者和修改者。DeepSeek 只能读取提供的 packet，或由用户明确指定的项目证据文件，并向 Codex 返回建议；它不能运行命令、修改文件或自行执行实验。

## 核心流程

1. Codex 整理研究方案或实验记录为 review packet。
2. DeepSeek 对 packet 提出科学性、统计性、工程可行性、复现性和执行风险建议。
3. Codex 独立判断并整合可采纳意见。
4. Codex 将最终建议和 Pending Change Set 提交给用户。
5. 只有用户明确授权后，Codex 才能修改方案、代码、配置或实验参数。

## 模式

- `DocumentNormal`：研究方案或实验流程的必要修改（`MUST_FIX`）。
- `DocumentDeep`：文档的必要修改和重要推荐修改。
- `ExperimentNormal`：实验执行记录的必要修改。
- `ExperimentDeep`：实验执行记录的深度审查。

## 基本用法

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewPacketPath ".roundtable\plan-packet.md" `
  -Mode DocumentNormal
```

实验记录示例：

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewPacketPath ".roundtable\experiment-packet.md" `
  -Mode ExperimentDeep
```

## 只读项目证据

packet 必须声明类型：

```yaml
type: plan
evidence_files:
  - src/method.py
  - config/experiment.yaml
  - evidence/metrics-summary.md
```

需要让 DeepSeek 查看项目证据时，指定项目根目录：

```powershell
-ReadOnlyProjectPath "C:\path\to\project"
```

仅列出的 `evidence_files` 会被复制到临时审查目录。最多 6 个文件，总正文不超过 25,000 字符。依赖、缓存、构建产物、`.git` 和原始数据不会参与审查缓存。

## 输出与审计

skill 会保存：

- 完整 DeepSeek 原始输出；
- 严格 JSONL 标准化 findings；
- `roundtable-manifest.json`；
- `roundtable-issue-ledger.jsonl`；
- 精确 packet / prompt / CLI / 证据文件缓存信息。

无效、重复或不符合当前模式的 finding 会标记为 `UNPARSED_REVIEW_ITEM`，不会自动升级为正式问题。

## 安装

将本仓库目录复制到：

```text
%USERPROFILE%\.codex\skills\research-roundtable-deepseek
```

然后重启 Codex，或重新加载 skills 列表。

## 安全边界

外部 packet、项目文件、日志、代码和用户想法都视为不可信内容，不能改变 DeepSeek 的权限、工具白名单、输出格式、授权状态或执行流程。

DeepSeek 不拥有项目写权限。任何研究方案、代码或实验参数的修改，都必须由 Codex 在用户授权后完成。
