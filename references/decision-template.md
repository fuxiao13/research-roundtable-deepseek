# Codex roundtable synthesis

- Roundtable status: `completed` / `partial` / `failed`
- Mode: `DocumentNormal` / `DocumentDeep` / `ExperimentNormal` / `ExperimentDeep`
- Review scope: complete supplied packet (focused packets are allowed)
- Coverage: `DeepSeek v4 Pro only`
- Initial-review manifest path:
- Codex-draft-check manifest path:
- Manifest path:
- Issue ledger path:
- Reviewer exclusions or degraded items:

## Codex independent findings

- `[C1]` Level; category; blocking effect; source anchor; evidence; action.

## Reviewer adjudication

| Source item | Anchor | Category | Blocking effect | Codex decision | Evidence and reason | Final action |
|---|---|---|---|---|---|---|

Categories: `engineering feasibility`, `scientific validity`, `statistical
validity`, `publication viability`, `execution risk`.

Blocking effect: `blocks execution`, `blocks publication`, `presentation only`,
or `non-blocking improvement`.

Decisions: `accept`, `partially accept`, `reject`, `defer`. Weight findings by
evidence and reviewer specialty, not votes. Lower the weight of unanchored
items until Codex verifies them. Never treat `UNPARSED_REVIEW_ITEM` as a
MUST_FIX without independent verification.

## DeepSeek check of Codex provisional recommendation

For each new item from the `CodexDraftCheck` stage: state whether Codex accepts,
partially accepts, rejects, or defers it, with evidence. DeepSeek may identify a
gap but cannot modify the recommendation or any project file.

## Research viability judgment

- Best-case publication level:
- Realistic publication level:
- Minimum viable thesis contribution:
- Downgrade path:
- Stop condition:
- Next experiment priority:

Tie judgments to hardware, data collection, controls, metrics, repeated trials,
novelty, and the minimum viable result. If evidence is insufficient, state
exactly what information is missing.

## Integrated final recommendation

- Outcome or direct-execution judgment:
- Accepted changes:
- Rejected/deferred changes:
- Expected benefit:
- Risks:
- Verification and success criteria:

# Pending Change Set

## Files to modify

Use exact paths. Write `none` when advice only.

## Exact modifications

## Verification commands

## Risks

## Rollback backup

Required for direct modification of important research files.

## User authorization status: pending

While pending, do not modify research plans, procedures, source files,
configuration, templates, scripts, or experiment parameters, and do not start
post-review verification.

For a focused packet, state: `This review is limited to the supplied focused
packet and does not claim coverage of omitted source material.` Read manifest +
normalized JSONL + ledger first; open raw only for the reasons recorded in the
manifest.
