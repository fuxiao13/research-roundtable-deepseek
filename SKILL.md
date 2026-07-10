---
name: research-roundtable-deepseek
description: Run a cost-controlled, traceable Codex-led research workflow for research documents and executed experiments using Codex plus DeepSeek v4 Pro only. DeepSeek can inspect a user-approved local project with read-only Read/Glob/Grep access and gives advice to Codex; Codex remains the sole executor, adjudicator, and editor, acting only after user authorization. Provides normal and deep modes, preflight blocking, exact review and isolation caches, JSONL findings, issue ledgers, manifests, and authorization gates.
---

# Research Roundtable

Keep Codex as sole executor, adjudicator, and potential editor. Treat DeepSeek
v4 Pro as a read-only assistant. It may inspect only a user-approved project
root through Read, Glob, and Grep; it must never run commands, access outside
that root, or apply changes.

## Select one workflow

- `Plan`: review research questions, novelty, falsifiability, baselines,
  leakage, ablations, statistics, validation, constraints, and publication
  viability. Do not execute or edit.
- `Procedure`: decide whether an experiment procedure is directly executable.
  Review ordering, frozen parameters, records, reproducibility, safety,
  leakage, stop conditions, and fallback paths. Do not execute or edit.
- `Experiment`: Codex executes and debugs an authorized experiment, then sends
  only its compact execution record and evidence to reviewers.

Use the matching packet template in `references/`. Add concise source anchors
such as `[S1]`, `[S2]`; keep each factual claim, constraint, metric, or decision
traceable. Reviewers may retain an unanchored finding, but Codex must give it
less weight until verified against the packet.

Every packet must contain exactly one top-level declaration: `type: plan`,
`type: procedure`, or `type: experiment`. The declaration must match the chosen
mode; the script does not infer type from a title.

## Default assistant workflow

1. Give Codex the research request or authorized experiment request. Build a
   self-contained review packet; add `-ReadOnlyProjectPath <project-root>` when
   DeepSeek needs to inspect the same local source, configuration, documents, or
   results that Codex can inspect. List up to six text files under
   `evidence_files:` in the packet; only those files are copied to a temporary
   read-only review view, capped at 25,000 total characters.
2. Run the script. DeepSeek reads only the supplied packet and the
   approved project root, then returns suggestions to Codex. It cannot run
   commands or modify any project content.
3. Codex independently evaluates the request and DeepSeek’s suggestions, then
   returns one integrated recommendation to you. Codex may accept, reject, or
   defer every DeepSeek finding; no vote is binding.
4. Wait for your explicit authorization. Only then may Codex modify a plan,
   source file, configuration, or experiment parameter, or execute a new
   experiment.

For an experiment, Codex may execute and debug only work you have authorized.
DeepSeek can inspect the approved project and Codex’s supplied execution record,
but never executes code or applies changes.

## Optional second check

Use `-Stage CodexDraftCheck -CodexDraftPath <path>` only when you explicitly
want DeepSeek to review Codex’s provisional recommendation before you see it.
It is not part of the default workflow.

## Reviewer role

- DeepSeek v4 Pro: causal gaps, leakage, statistics, metric mismatch,
  falsifiability, overstated novelty, controls, publication viability, plus
  engineering feasibility, procedure completeness, reproducibility, safety,
  cost, debugging path, and execution risk.

DeepSeek finding a logical flaw does not automatically establish engineering
infeasibility; Codex must adjudicate against the packet and evidence.
Classify each finding as `engineering feasibility`, `scientific validity`,
`statistical validity`, `publication viability`, or `execution risk`; state
whether a `MUST_FIX` blocks execution, blocks publication, or only affects
presentation.

## Simplified modes

Choose exactly one mode. The mode determines packet type, input budget, timeout,
and whether recommendations are included:

- `DocumentNormal`: read a Plan or Procedure document; report `MUST_FIX` only.
- `DocumentDeep`: read a Plan or Procedure document; report `MUST_FIX` plus
  material `RECOMMENDED` findings and cross-field risks.
- `ExperimentNormal`: read Codex's experiment execution record; report
  `MUST_FIX` only.
- `ExperimentDeep`: deeply audit the execution record and report `MUST_FIX` plus
  material `RECOMMENDED` findings.

The old Plan/Procedure/Experiment, BudgetLean/Lean/Standard, and Full/Diff
switches are no longer public options. For document modes, the script infers
Plan versus Procedure from the packet heading. For focused revisions, provide a
focused packet directly rather than selecting a Diff mode.

Never impose a finding-count cap or shorten raw reviewer output. Use a Deep mode
as the final gate before execution, submission, or publication.

## Cost controls

- Run local preflight first. `PRECHECK_BLOCKED` means no reviewer call.
- Cache passed isolation tests for 24 hours using CLI, prompt, permissions,
  sandbox strategy, script version, and user fingerprint.
- Reuse reviews only on exact hash-key matches; never use similarity matching.
- For Plan/Procedure, have Codex create one anchor-preserving deduplicated
  packet. Preserve constraints, hardware, metrics, baselines, labels,
  statistics, leakage controls, failures, and unresolved `MUST_FIX`.
- Normal modes may pass an anchor-preserving focused packet with
  `-DeepSeekPacketPath`. The script applies the same input limit to that packet,
  includes supplied user ideas in its cache key, and never truncates it. Use the
  complete packet for cross-domain questions and Deep mode when focus would omit
  decisive evidence.
- With `-ReadOnlyProjectPath`, DeepSeek can read only `evidence_files`; it cannot
  scan the project or access additional paths. Add a needed file in the next
  packet after Codex decides it is relevant.
- Read manifest, normalized JSONL, and issue ledger by default. Read raw only
  for invalid/partial/inconsistent output, tool failure, overlong output, user
  request, or Deep-mode verification of a decisive `MUST_FIX`.
- Never retry formatting automatically in Normal modes.
- Reviewer findings are strict JSONL with fixed category and blocking-effect
  enums. Normal modes accept `MUST_FIX` only; malformed or disallowed items are
  preserved as `UNPARSED_REVIEW_ITEM`, never promoted to findings.

## Isolation and traceability

The invocation script:

- runs or safely reuses a fingerprinted isolation smoke test;
- uses a new empty sandbox for isolation; project review runs in the approved
  read-only project root only when `-ReadOnlyProjectPath` is supplied;
- passes DeepSeek text through stdin;
- saves complete `*.raw.md` and parsed `*.normalized.jsonl` files;
- validates item IDs, severity, anchor/location, evidence, and action;
- maintains `roundtable-issue-ledger.jsonl` so unresolved `MUST_FIX` survives
  focused review rounds and fixed/rejected issues remain traceable;
- records every cache, compression, focused-packet, skipped-call, and raw-read
  decision in `roundtable-manifest.json`.
- terminates stalled reviewer processes after 300 seconds in Normal modes or
  600 seconds in Deep modes, and records the timeout.

Do not use a reviewer whose isolation test failed. A raw file is evidence, not
automatically admissible advice.

## Long packets

Never silently truncate. If input exceeds the mode limit, create a compressed
packet that preserves objectives, source anchors, decisive evidence,
constraints, contradictions, and acceptance criteria. Pass both
`-CompressedReviewPacketPath` and `-CompressionStrategy`. The manifest retains
the original and effective hashes.

## Invocation

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewPacketPath ".roundtable\procedure-packet.md" `
  -Mode DocumentNormal `
  -ReadOnlyProjectPath "C:\research\my-project"
```

Document mode infers Plan versus Procedure from the packet heading; Experiment
mode reads an execution record automatically.

Omit `-ReadOnlyProjectPath` for packet-only review. The optional second check is
available only when you explicitly request it:

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" `
  -ReviewPacketPath ".roundtable\procedure-packet.md" `
  -Mode DocumentNormal `
  -Stage CodexDraftCheck `
  -CodexDraftPath ".roundtable\codex-provisional-recommendation.md"
```

Run local diagnostics without model calls:

```powershell
& "<skill-dir>\scripts\Invoke-ResearchRoundtable.ps1" -SelfTest
```

## Authorization gate

Review and execution requests do not authorize post-review changes. Always
produce a concrete `Pending Change Set` with exact paths, modifications,
verification commands, risks, and status `pending`. Do not modify a plan,
procedure, code, configuration, template, or parameter until the user explicitly
approves that set.

Only after user approval may Codex transition ledger items from `open` to
`resolved`, `rejected`, or `deferred`. Supply an authorization record and a
lifecycle-update JSONL with handling evidence, change-set hash, responsibility,
and rollback information; closed items remain auditable but do not count as
unresolved `MUST_FIX` items.

If the user explicitly requests direct modification of an important research
file, preserve a reversible backup before editing and report its path. Approval
covers only the presented scope; ask again for materially different work.
