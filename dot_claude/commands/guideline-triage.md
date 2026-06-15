---
name: guideline-triage
description: Audit recent AI-config changes on main and relocate them to the correct tier (always-loaded guideline / situational skill / code comment), then propagate via boost:update
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

Audit the AI-config changes that landed on `main` since this command last ran, classify
each into the correct tier of the three-tier model, relocate the misplaced ones (with your
confirmation), and propagate the result through `boost:update`.

**Optional argument** (`$ARGUMENTS`): a base ref (`abc123`, `origin/main~20`) or `--since=<N>d`.
If provided, it overrides the watermark for this run **without** disturbing stored state.

---

## The three-tier model (the decision rule)

The load-bearing question, taken verbatim from the blade's own "Where New Rules and Lessons Go"
section: **"Is this true for _every_ session, or only _some_?"**

| Tier | Home | Belongs here only when… |
|------|------|--------------------------|
| **Always-loaded** | `.ai/guidelines/iel-coding-conventions.blade.php` | The rule is **universal** — and matches one of the four sanctioned categories: brand/design tokens, **i18n policy**, core PHP style, error-message discipline. Default answer is **no**. |
| **Situational** | a `.ai/skills/<name>/SKILL.md` | Tied to one workflow, integration, area, or component. The skill's `description` makes it load on demand. This is the default home for "lessons learned." |
| **Single-file gotcha** | a PHPDoc/comment at the code site | Applies to exactly one file/symbol. |

Special cases you must handle:
- **Split** (classically i18n): the universal *policy* core stays always-loaded; the *mechanics*
  (test patterns, blind-spots) move to a skill. Don't full-delete a split rule.
- **OVERRIDE vs COMPOSE**: never propose a destination that **shadows a Boost built-in** skill or
  guideline name/path — an override is a permanent fork that loses upstream updates. Always prefer a
  **new, distinctly-named** `.ai/skills/` skill that composes alongside the built-in.

---

## Phase 1 — Locate the watermark

```bash
REPO=$(git rev-parse --show-toplevel)
SLUG=$(printf '%s' "$REPO" | sed 's#[^A-Za-z0-9]#-#g; s#^-*##')
STATE_DIR="$HOME/.claude/state/guideline-triage"
STATE_FILE="$STATE_DIR/$SLUG.json"
mkdir -p "$STATE_DIR"
echo "State file: $STATE_FILE"
[ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "NO_WATERMARK"
```

- If `$ARGUMENTS` is set, use it as the base (skip stored watermark for this run; do not touch the file).
- Else if the state file exists, use its `lastProcessedSha` as the base.
- Else (first run): tell the user there's no watermark and ask for a starting ref, defaulting to
  **"last 14 days on `main`"** (`origin/main@{14.days.ago}`) if they have no preference.

## Phase 2 — Establish the scan window

```bash
git fetch origin main --quiet
HEAD_SHA=$(git rev-parse origin/main)
echo "HEAD origin/main = $HEAD_SHA"
# BASE = watermark sha, $ARGUMENTS ref, or the 14-day fallback resolved above.
git log --oneline "$BASE..origin/main" -- .ai/ .claude/ .agents/ CLAUDE.md AGENTS.md
```

- If that log is **empty**, report: `Nothing new since <BASE> (<date>).` and **exit** — do **not**
  advance the watermark.
- Otherwise capture the cumulative diff for the tiers that matter:

```bash
git diff "$BASE..origin/main" -- \
  .ai/guidelines/iel-coding-conventions.blade.php \
  .ai/skills/ .claude/skills/ .agents/skills/ \
  CLAUDE.md AGENTS.md
```

## Phase 3 — Bloat check (mechanism 2), before placement triage

Regenerating rewrites the whole guidelines block, so resolve the char-limit case first.

```bash
wc -m CLAUDE.md AGENTS.md 2>/dev/null
```

- Claude Code's limit is **40,000 chars** on the assembled `CLAUDE.md` (and `AGENTS.md` mirrors it).
- If either is **> 40k**, suspect the **enumeration-artifact** bug: a contributor regenerated docs
  under a **newer-than-pinned** Boost build, inlining the full ~40-skill list into `## Skills Activation`.
  Confirm by checking whether `## Skills Activation` contains a long per-skill enumeration rather than a
  one-line pointer. Remediation is mechanical — `boost:update` from the **pinned** Boost rewrites the block
  and strips the enumeration. This is folded into Phase 6's single `boost:update` run; just flag it now and
  re-measure afterward.

## Phase 4 — Placement triage (mechanism 1)

From the Phase 2 diff, build the list of things to evaluate:

1. **Net additions/changes to the always-loaded blade** (`.ai/guidelines/iel-coding-conventions.blade.php`)
   — especially new `## ` headings or appended bullets.
   > Use a **two-dot** `git diff "$BASE..origin/main" -- <file>` (already done). Beware three-dot diffs
   > (`gh pr diff`, GitHub's Files-changed tab) — they show `merge-base...branch` and render content that's
   > *already on main* as a fresh `+`, faking a situational rule that isn't really being added.
2. **Hand-edits to GENERATED or BUNDLED skills** — any change under `.claude/skills/**` or `.agents/skills/**`,
   or to a bundled/package/remote skill. These are wipe-fragile: `boost:update` reverts them. The *content*
   of such an edit is a lesson that escaped into the wrong file — treat it as something to relocate back into
   the correct `.ai/` source.

For each item, classify into a tier using the model above. Identify which skills are wipe-fragile so you
never propose one as a destination:

```bash
# package-shipped skills (e.g. medialibrary-development) — reverted by boost:update:
find vendor -path '*resources/boost/skills*' -name SKILL.md 2>/dev/null
# IEL-owned skill sources (the ONLY safe destinations) — these symlink into .claude/.agents:
ls .ai/skills/
```
- A skill in `boost.json`'s `skills[]` but absent from the `find` output above **and** absent from
  `vendor/laravel/boost/.ai/**` is **Boost-remote-managed** — also wipe-fragile, also never a destination.
- For a situational rule, grep the existing `.ai/skills/` for the best-fit home and propose anchoring it
  next to a related bullet. Propose a **new** `.ai/skills/<name>/` only when none fit.

## Phase 5 — Confirm (the guided gate)

Present a table and **wait for approval. Write nothing before the user approves.**

| # | Item (1-line summary) | Current location | Detected tier | Proposed destination | Rationale |
|---|------------------------|------------------|---------------|----------------------|-----------|

- For each row, give the one-sentence "every session vs. some sessions" reasoning.
- Flag any **split** rows (policy stays / mechanics move) and any **OVERRIDE risk** explicitly.
- Let the user override any classification or drop any row before you proceed.

## Phase 6 — Apply, propagate, verify

After approval:

1. **Edit `.ai/` sources only.** Apply each approved relocation:
   - move situational content into the chosen `.ai/skills/<name>/SKILL.md` (or create a new one),
   - trim the always-loaded blade for full relocations / splits,
   - add code-site PHPDoc for single-file gotchas,
   - for a detected generated/bundled hand-edit, add the content to the right `.ai/` source and let
     `boost:update` revert the generated copy.
   **Never** edit `CLAUDE.md`, `AGENTS.md`, `.claude/skills/**`, `.agents/skills/**`, or a bundled/package/remote
   skill as a destination — those are generated.
2. **Propagate** with a single full update:
   ```bash
   vendor/bin/sail artisan boost:update
   ```
   Never pass `--ignore-skills`.
3. **Accept boost:update's output verbatim — including EOF-newline changes (added OR removed).** The generator
   owns its output files; the IEL "always end files with a newline" convention applies only to hand-authored
   `.ai/` sources, not to generated files. Do **not** re-add a newline `boost:update` strips, or you'll
   ping-pong against it every run.
4. **Verify:**
   ```bash
   git diff --stat
   wc -m CLAUDE.md AGENTS.md
   ```
   Confirm the regen propagated (CLAUDE.md/AGENTS.md changed as expected) and re-measure char counts to close
   the Phase 3 bloat loop (both should be < 40k).
5. **Stop and report.** Summarize what moved where and show the diff. **Do not stage or commit** — leave that
   to the user.
6. **Advance the watermark only now** (on success):
   ```bash
   printf '{\n  "repo": "%s",\n  "lastProcessedSha": "%s",\n  "lastRunAt": "%s"\n}\n' \
     "$REPO" "$HEAD_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
   cat "$STATE_FILE"
   ```
   If the run was interrupted or the user declined all rows, leave the watermark untouched so the same window
   re-scans next time.

---

## Guardrails (do not violate)

- **`.ai/` is the only source of truth.** Generated/bundled files are never relocation destinations.
- **Generator owns its output.** Accept `boost:update`'s EOF-newline changes verbatim on generated files.
- **Sail for `boost:update`.** Host PHP lacks `ext-sodium`; run inside the container via `vendor/bin/sail`.
- **Prefer ADD over OVERRIDE.** A new non-shadowing `.ai/skills/` skill, never a fork of a Boost built-in.
- **Two-dot diffs only** when judging net block changes; three-dot diffs fake additions already on main.
- **Watermark advances only on a completed run.**
