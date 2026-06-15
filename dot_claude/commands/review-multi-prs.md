---
name: review-multi-prs
description: "Add self as reviewer, code-recheck + playwright-test-local each PR, approve/reject with inline comments"
user_invocable: true
---

# Batch PR Review

You are reviewing a list of PRs end-to-end: code review, playwright testing, and approve/reject with inline comments. **Never pause to ask the user anything.** Make decisions autonomously and keep moving.

## Input

The user provides a list of PR numbers (space or comma separated). Parse them into an ordered list.

**Hard limit: maximum 5 PRs per invocation.** If more than 5 are provided, process only the first 5 and tell the user to run the command again with the remainder. Reviewing more than 5 PRs in a single session causes context window pressure, increases the risk of environment hangs consuming the entire session, and degrades review quality for later PRs.

### Flags

- **`--self`** — Self-review mode for the user's own PRs. When this flag is present:
  - **Skip Phase 0 step 2** (do NOT add the user as a reviewer — GitHub blocks self-review and these are the user's own PRs).
  - **Skip all GitHub posting**. Do NOT run any of: `gh pr review --approve`, `gh pr review --request-changes`, `gh pr comment`, or any `gh api ... /reviews --method POST` call. The "HARD BLOCK" / "post the review" instructions in Step C and Step E are replaced with "report the verdict to the user in chat."
  - **Still run everything else**: code review, AC verification, runtime field audit, Playwright (UI PRs) or local test suite (backend-only PRs), PHPStan, schema verification.
  - **Report results inline in chat** with a per-PR verdict table and one-line "would PASS / would FAIL / would be UNVERIFIED in a normal review" summary. The Phase 4 summary table is still produced.
  - Treat any free-text user instruction like "no comment", "don't post", "just tell me", or "self review" as equivalent to `--self` if the flag wasn't explicitly typed.

Parse the flag out of the args before parsing PR numbers (e.g. `/review-multi-prs --self 6111 6114` → flag=self, PRs=[6111, 6114]).

## Phase 0: Setup

1. Get the GitHub username and repo info:
   ```bash
   gh api user --jq .login
   gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'
   ```
2. **Skip this step entirely if `--self` is set.** Otherwise: add the user as a reviewer to ALL PRs. **IMPORTANT: Never use `gh pr edit --add-reviewer`** — it fails on repos with classic projects enabled. Always use the REST API directly, **trimming the response** to avoid flooding context with full PR JSON:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{PR}/requested_reviewers --method POST -f 'reviewers[]={username}' --jq '.html_url // "added"' 2>&1 || true
   ```
   The `--jq` filter extracts only the PR URL (a single line) instead of the full PR object (~10KB of JSON per call). Without this, 10+ reviewer additions dump ~100KB of JSON into context before any review work begins.

   Run each addition as a **separate sequential** Bash call (not parallel — parallel calls cascade-cancel on any single failure). Append `|| true` so failures (already a reviewer, self-review blocked, etc.) don't halt the process. Log the outcome and move on.

## Phase 1: Gather & Classify All PRs (Parallel)

Gather info for ALL PRs simultaneously. For each PR, run the following API calls in **parallel Bash calls** (these are read-only and safe to parallelize):

### Step A: Gather PR info

```bash
gh pr view {PR} --json title,body,headRefName,baseRefName,files
```

Note the branch name, title, base branch, test steps, and changed files.

Also fetch existing comments on the PR to check for prior reviewer feedback and bot flags:
```bash
gh api repos/{owner}/{repo}/issues/{PR}/comments | jq -a '[.[] | {user: .user.login, body: .body}]'
gh api repos/{owner}/{repo}/pulls/{PR}/comments | jq -a '[.[] | {user: .user.login, path: .path, line: .line, body: .body}]'
```

If prior reviews flagged issues, note them — they may already cover something the code review would catch, or they may indicate unresolved problems that need verification.

**Classify the PR as UI or backend-only** using BOTH the changed files list AND the "How to test locally" steps. A PR is backend-only ONLY when both conditions are met:

- **UI PR** (needs local Playwright testing): Either condition triggers UI classification:
  1. **File-based**: Any changed file matches `.vue`, `.js`, `.ts`, `.css`, `.scss`, or Blade templates (`.blade.php`)
  2. **Test-step-based**: The "How to test locally" section contains ANY of these signals — **this takes precedence over file types**:
     - **UI navigation language**: "log in", "navigate to", "open", "click", "sign in", "visit", "go to", "verify in the UI", "refresh the page"
     - **Domain-action language**: "create a [entity]" (e.g., "create a load", "create an invoice"), "trigger a [action]", "submit", "update the [record]", "delete the [record]", "verify the [payload/response/result]". These imply interacting with the application through its UI — users create loads, trigger actions, and verify results in a browser.
     - **The default rule**: If the test steps describe procedural actions against the application (not just CLI commands), classify as UI. When in doubt, classify as UI — it's better to run Playwright against a backend-only PR than to skip browser verification on a PR with user-visible impact.

- **Backend-only PR** (local test suite only): ALL of these must be true:
  1. All changed files are `.php` (excluding Blade), migrations, config, or other non-UI files
  2. The "How to test locally" steps are **exclusively** CLI commands — every step is a literal terminal command (e.g., `php artisan test`, `pest`, `phpstan`, `sail artisan tinker`). If even one step describes a domain action ("create a load", "trigger an update", "verify the payload"), the PR is UI, not backend-only.
  3. Typical examples: test-only PRs that say "run `vendor/bin/sail artisan test --filter=FooTest`", CI config changes, refactoring internals with no test steps beyond running the suite

**Why this matters:** A PHP-only PR that fixes a bug visible in the UI (e.g., adding a missing field to an Eloquent Resource, changing a policy that gates a UI action, gating stop address resolution on customer config) needs browser verification to catch issues that unit tests can't — like stale frontend state, cross-component dependencies, or display-layer bugs. The PR author signals this by writing procedural test steps rather than just "run the tests."

This classification determines whether local Playwright testing (Step D) or local test suite execution (Step D-alt) is used.

### Step A.5: Fetch Jira Acceptance Criteria

A PR may reference multiple Jira tickets. Collect **all** unique ticket IDs:

1. Extract the **primary ticket** from the branch name or PR title (pattern: `PX-\d+`)
2. Scan the **PR body** for any additional `PX-\d+` references
3. Deduplicate the list

For **each** ticket ID found, fetch the Jira ticket:

```bash
jira issue view <TICKET-ID> --plain 2>&1
```

If the `jira` CLI fails, fall back to the REST API:
```bash
curl -s -u "$JIRA_USER:$JIRA_API_KEY" \
  "https://intxlog.atlassian.net/rest/api/3/issue/<TICKET-ID>?fields=summary,description,customfield_10016" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['fields'].get('description',''))"
```

Extract the **Acceptance Criteria** section from each ticket. If AC is absent from a Jira ticket, note the gap for that ticket. If no ticket IDs are found at all, use the PR description as the source of truth and note it.

### Step A.6: Map AC items to test coverage

After gathering both the Jira AC (Step A.5) and the "How to test locally" steps from the PR body (Step A), build a coverage map:

**Expand compound steps first.** Before mapping, split any "How to test" step that says "verify [multiple things] work" into individual sub-steps. For example, "Verify clicking actions (Create Note, Release to Billing, etc.) still work correctly" becomes one sub-step per action in the menu — not a single check. If the step lists examples with "etc.", enumerate ALL items from the component (read the code or inspect the UI), not just the named examples. Each sub-step gets its own row in the Playwright results table and its own PASS/FAIL/UNVERIFIED verdict.

For each AC item, determine:
- **Covered by test step**: Which "How to test" step(s) will verify this AC item? Note the mapping.
- **Covered by code review only**: The AC item is about implementation logic (e.g., "uses database transactions") that can be verified by reading code but has no UI-visible behavior.
- **No coverage**: The AC item has no corresponding test step AND cannot be fully verified by code review alone. These are **gaps**.

This mapping drives decisions in Steps B, D, and E:
- **Step B (code review)**: The agent receives all AC items and evaluates whether the code addresses each one.
- **Step D (playwright)**: After running the "How to test" steps, check the coverage map for AC items with no test coverage. For any gap that has a UI-verifiable behavior, attempt to verify it via additional Playwright actions (navigate to the relevant page, check the state, take a screenshot). This is best-effort — don't invent test steps that aren't feasible.
- **Step E (reporting)**: Each AC item in the table must cite its evidence source: the specific test step number (e.g., "Step 3 — PASS"), code review finding, additional Playwright verification, or "No coverage" if it couldn't be verified by any means.

## Phase 2: Parallel Code Reviews

Before spawning code review agents, the **main agent** must pre-fetch the diff and changed file contents for each PR. This eliminates the need for worktree agents to run git commands (which has proven unreliable — agents frequently fail to checkout the PR branch and review main instead).

### Step B.0: Pre-fetch PR diffs and changed files

For each PR, fetch the diff and the full contents of every changed file from the PR branch. Run these in **parallel Bash calls** since they are read-only:

```bash
# Fetch the full diff
gh pr diff {PR}

# For each changed file, fetch its contents from the PR branch
git show origin/{branch}:{file_path}
```

Store the diff output and file contents — these will be passed directly into the code review agent prompt.

**Important:** Use `git show origin/{branch}:{file_path}` (not `git show HEAD:{file_path}`) to ensure you're reading from the PR branch, not the current branch.

### Step B: Code review (in worktree, with pre-fetched diff)

Spawn an agent with `isolation: "worktree"`, `subagent_type: "superpowers:code-reviewer"`, and `run_in_background: true` for each PR.

The agent prompt must include:
- PR number, title, branch, base branch
- PR description
- **The full PR diff** (from Step B.0) — this is the **source of truth** for what changed. Even if the worktree checkout fails, the agent has the actual diff and changed file contents to review.
- **The full contents of each changed file** (from Step B.0) — so the agent can see complete file context, not just diff hunks
- **Jira Acceptance Criteria** (if fetched in Step A.5) — the agent must verify each AC item is addressed by the code changes. **Deep AC analysis is required — surface-level matching is not enough:**
  - For each AC item, identify the **business intent** — what behavior is the stakeholder asking for, and what behavior are they asking to prevent? Read the AC as a user, not as a developer scanning for keywords.
  - When an AC says "block", "prevent", or "don't allow" a behavior: enumerate ALL the ways that behavior can occur in the UI/code, then verify the implementation blocks EVERY variant — not just the most obvious one. A fix that blocks one trigger path but leaves others open is **NOT MET**.
  - When an AC describes fixing a behavior: trace every entry point and edge case for that behavior. A partial fix that works in the common case but fails in a less-common variant is **NOT MET**.
  - **Adversarial test**: For each AC item, ask: "Can I construct a scenario where the undesired behavior still occurs despite this change?" If yes, the AC is NOT MET — classify as CRITICAL.
  - Do not mark an AC item as MET just because the code does something related to the AC. The implementation must cover the AC's full intent. A hedge like "matches stated intent, however..." is a NOT MET — don't equivocate.
- **Checkout instructions** — the agent should attempt to checkout the PR branch for reading additional context files (parent classes, imports, usages):
  ```bash
  git fetch origin {branch}
  git checkout -b {branch} origin/{branch} 2>/dev/null || git checkout {branch} && git reset --hard origin/{branch}
  ```
  If checkout fails, the agent can still complete the review using the pre-fetched diff and file contents — it just won't have access to unchanged files for broader context.
- **Read project conventions before reviewing.** The agent must read `CLAUDE.md` and all files in `.claude/rules/` in the worktree before starting the review. These contain project-specific conventions (test patterns, PHP style rules, migration rules, etc.) that the code must follow. In particular, verify test files against the Pest test conventions (time-dependent tests must use `travelTo()`/`travelBack()`, `Storage::fake()` cleanup, factory states) and the test-review-discipline rules (false-positive detection, async patterns).
- Full checklist: bugs, N+1 queries, memory leaks, security, race conditions, test quality, convention adherence
- Classify every issue as CRITICAL, WARNING, or NIT
- For each AC item, report whether the code addresses it: MET, NOT MET, or UNABLE TO DETERMINE
- Return a verdict: PASS (no critical/warning) or FAIL (has critical/warning), with all issues listed and AC verification results

### Step B.5: Runtime field audit (conditional)

Check the PR's changed files list (from Step A) for any Eloquent Resource or Transformer files (files matching `*Resource.php` or `*Transformer.php`).

**If Resource/Transformer files were changed:** Spawn an agent to run the `/runtime-field-audit` skill against the changed resources. Use the local API. The agent must:
- Cross-reference every field in the resource against the actual database schema
- Hit the local API endpoint and verify non-null values come back for fields that should have data
- Check that Vue templates reading the API response use matching field names
- Audit feature tests for value-level assertions (not just `assertJsonStructure`)
- Return findings classified as CRITICAL (column mismatch / null at runtime), WARNING (test gap), or NIT

Merge the findings into the code review results. A CRITICAL field audit finding counts the same as a CRITICAL code review issue — it blocks approval.

**If no Resource/Transformer files were changed:** Skip this step.

### Phase 2.5: Pre-test Preparation (while code reviews run in background)

While code review agents run, prepare for testing:

Create screenshot directories for all UI PRs:
```bash
mkdir -p tests/playwright/{PR}
```

**Ensure dev environment is running** (needed for both UI and backend-only PRs):

Verify `make cdev` is running. Check if the Sail containers are up:
```bash
docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | head -20
```
If no containers are running (or the output is empty), start the dev environment in the background using `run_in_background: true`:
```bash
make cdev
```
Then poll for readiness with short checks (output a status line each time so the stream stays active):
```bash
docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | head -20
```
Do not start any PR testing until the dev environment is confirmed up.

## Phase 3: Process Code Review Results & Testing

As code review agents complete (you'll be notified since they ran in background), process their results and proceed to testing.

### Step B.9: Clean up worktrees before testing

After ALL code review agents have completed, **remove their worktrees** before starting any backend-only PR testing. Git does not allow the same branch to be checked out in multiple worktrees — if a code review worktree has a PR branch checked out, the main repo cannot checkout that branch for testing.

```bash
# List all agent worktrees
git worktree list | grep '\.claude/worktrees/agent-' | awk '{print $1}'

# Remove each one
git worktree remove --force {worktree_path}
```

Run each removal as a **separate sequential** Bash call. This must happen before any `git checkout` in the main repo.

**All backend-only PR testing must run from the main repo directory** — never from a worktree. Sail containers are bound to the main repo's docker-compose context; running Sail from a worktree spins up conflicting containers.

### Step C: Handle code review failures

**`--self` mode:** Do NOT post to GitHub. Capture the issues (with file:line references and severity) into an in-memory finding list for that PR. Continue to testing (Step D / D-alt) so the user gets a full picture — code review issues alone do not halt testing in self mode, since the user is iterating before requesting outside review. Surface the findings in the final summary as part of the PR's verdict.

**Default (non-`--self`) mode below:**

**If FAIL (critical or warning issues found):**

1. **Validate line numbers against the PR diff before posting.** The GitHub Reviews API only accepts `line` values that appear in the diff — using an absolute file line number that isn't part of the changed hunks returns a 422 "Line could not be resolved" error.

   First, fetch the diff to find valid line numbers:
   ```bash
   gh pr diff {PR}
   ```
   To filter for a specific file, pipe through grep — **do not** pass file paths as extra args to `gh pr diff` (it only accepts the PR number):
   ```bash
   gh pr diff {PR} | grep -A 200 '^diff --git a/{path}' | head -300
   ```
   Parse the `@@` hunk headers to determine which line numbers are in the diff. A hunk header like `@@ -10,5 +12,8 @@` means lines 12–19 in the new file are valid for inline comments.

   For each issue from the code review:
   - If the issue's line number falls within a diff hunk → use it as an inline comment with `"line": {N}`
   - If the issue's line number is NOT in any diff hunk → **move it into the review body text** with a `file:line` reference. Do NOT use `"subject_type": "file"` in the `comments` array — the REST `pulls/{PR}/reviews` endpoint does not accept it and returns 422 (`Field is not defined on DraftPullRequestReviewComment`). Every entry in `comments` MUST have a `"line"` that falls inside a diff hunk.

   Then post the review:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{PR}/reviews --method POST \
     --input - <<EOF
   {
     "event": "REQUEST_CHANGES",
     "body": "## QA Review — CHANGES REQUESTED\n\n### Acceptance Criteria Verification\n\n{For each ticket, render: #### [TICKET-ID](https://intxlog.atlassian.net/browse/TICKET-ID) followed by an AC table. If no tickets found: 'No Jira tickets found — AC verified against PR description.'}\n\n### Code Review Issues\n\n{summary of issues}\n\n### Out-of-diff issues\n\n{Each issue whose line is not in the diff goes here as a bullet: '- **{SEVERITY}** {path}:{line} — {description}. Fix: {suggestion}'}\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)",
     "comments": [
       {
         "path": "relative/path/to/file.php",
         "line": {line_number_verified_in_diff},
         "body": "**{SEVERITY}**: {description}\n\n**Fix:** {suggestion}"
       }
     ]
   }
   EOF
   ```
   - Each critical/warning issue whose line IS in the diff gets its own inline comment
   - Each critical/warning issue whose line is NOT in the diff goes in the body under "Out-of-diff issues" with a `path:line` reference
   - NITs go in the body, not as inline comments
   - Skip testing — this PR is done

**If PASS (no critical/warning issues):**

2. Check the PR classification from Phase 1:
   - **UI PR** → Proceed to Step D (local Playwright testing)
   - **Backend-only PR** → Proceed to Step D-alt (local test suite verification)

### Step D: Playwright testing (UI PRs — local worktree)

All UI PR testing runs locally against `http://localhost`. The main agent sets up the worktree and dev environment, then spawns a Sonnet subagent for the actual browser testing.

#### Step D.0: Set up local worktree

1. **Create a worktree with the PR branch:**
   ```bash
   git fetch origin {branch}
   git worktree add .claude/worktrees/local-test-{PR} origin/{branch}
   ```

2. **Start the local dev environment from the worktree.** Run each command as a **separate sequential Bash call** from the worktree directory with `timeout: 300000`:

   First check if Sail containers are already running:
   ```bash
   cd .claude/worktrees/local-test-{PR} && docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | head -20
   ```

   If not running, start the environment:
   ```bash
   cd .claude/worktrees/local-test-{PR} && make cdev
   ```

   Then run setup commands (each as a separate call):
   ```bash
   cd .claude/worktrees/local-test-{PR} && sail composer install 2>&1
   ```
   ```bash
   cd .claude/worktrees/local-test-{PR} && sail npm i 2>&1
   ```
   ```bash
   cd .claude/worktrees/local-test-{PR} && sail php artisan migrate:fresh 2>&1
   ```
   ```bash
   cd .claude/worktrees/local-test-{PR} && sail php artisan db:seed 2>&1
   ```

   Verify the app is accessible:
   ```bash
   curl -sL -o /dev/null -w "%{http_code}" http://localhost/login --max-time 15
   ```

   If the server doesn't come up after 3 retries (30s apart), log the failure, clean up the worktree, mark all steps UNVERIFIED, and move to the next PR. If `migrate:fresh` or `db:seed` times out (5 min), same — skip this PR's testing.

#### Step D.1: Spawn Sonnet subagent for Playwright testing

**Run Playwright testing as a Sonnet subagent.** Spawn a foreground agent with `model: "sonnet"` and `run_in_background: false` (you need results before proceeding to Step E). Do NOT use `isolation: "worktree"`.

The subagent prompt must include `ultrathink` and the following context:
- PR number, title, branch
- Base URL: `http://localhost`
- The "How to test locally" steps (parsed and expanded from Step A.6)
- The AC coverage map from Step A.6
- Auth credentials (`test@intxlog.com` for intxlog/nexus)
- Screenshot directory: `tests/playwright/{PR}/`
- **All testing instructions below** (sections 1–4.5, including 3.5, 3.6, 3.7, 3.8, 3.9)
- Instruction to return results as a structured table with columns: Step | Result | Description | Evidence | Screenshot(s)
- Any test data gaps encountered during testing

The subagent executes the following instructions:

---

Test against `http://localhost` (the local dev environment running from the PR's worktree).

1. Fetch the "How to test locally" section from the PR body.
   - If no test section exists, mark all steps as UNVERIFIED and note it.

2. Navigate to `http://localhost/login` and authenticate:
   - Login as admin (`test@intxlog.com` for intxlog/nexus)
   - If the login page doesn't load, retry once after 30 seconds. If still down, mark all steps UNVERIFIED with "local dev environment not responding."

3. For each test step, drive Playwright MCP:
   - Use `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_take_screenshot`, `browser_run_code` etc.
   - Navigate using `http://localhost` as the base URL for all page URLs
   - Take a screenshot for every step: `tests/playwright/{PR}/step-{NN}-{slug}.png`
   - Record each step as PASS, FAIL, or UNVERIFIED
   - If a step requires precondition data, create it via `database-query` (laravel-boost MCP), tinker, the UI, or factories. You have full local DB access — use it.
   - **Track test data gaps.** Whenever you (a) use tinker/DB queries to create preconditions that the "How to test locally" steps don't mention, or (b) cannot test a step because the environment lacks the required data and you have no way to create it, record the gap. These get surfaced in the review comment (see Test Data Gaps section in the comment templates below).
   - **Never skip steps.** Attempt every single one. Use `browser_run_code` for complex multi-action sequences.
   - **Never consolidate steps.** Each PR test step (and each sub-step from compound expansion in A.6) gets its own numbered row in the results table. If the PR lists 5 steps, your results table has at least 5 rows. Merging "Navigate to page" and "Click button" into one row hides partial failures.
   - **"Verify it works" = interact, not look.** When a test step uses "verify," "confirm," or "check" alongside an action verb (works, functions, opens, submits), you MUST perform the action (click, submit, toggle) and observe the result. An element being visible or rendered is NOT verification that it works. A button that renders but opens a modal that immediately closes is a **FAIL**, not a PASS.
   - If autocomplete fields reject seeded fake data (e.g. fake city names), clear the field and enter real data instead.
   - For form validation errors, fix the input and retry — don't give up.

3.5. **Action menu / dropdown / multi-item deep testing**: When the PR adds or modifies a component that presents multiple interactive items (action menus, dropdown menus, context menus, tab bars with actions):
   - Open the menu and screenshot it.
   - Click **EVERY item** in the menu, one at a time:
     - **Opens a modal/drawer**: Verify it opens AND remains open (not immediately closing). Take a screenshot of the opened modal/drawer. Close it, reopen the menu, continue to the next item.
     - **Navigates**: Verify the target page loads. Navigate back to the original page.
     - **Triggers a state change** (void, cancel, toggle): Verify the UI updates to reflect the new state (e.g., "Void" becomes "Unvoid"). If the action is destructive/irreversible, verify it's appropriately gated (confirmation dialog).
     - **Disabled**: Verify it cannot be clicked. If possible, compare the disabled/enabled state against the same menu on the source/detail page — mismatches are a FAIL.
   - Report each menu item as its own row in the test results table (e.g., "Step 5a — Create Checkcall", "Step 5b — Create Note", etc.).
   - **This applies automatically.** If the PR adds an action menu, each item in that menu must be individually click-tested even if the PR's test steps don't explicitly enumerate them. The test steps saying "verify actions work" is the trigger — but even without that step, a new action menu implies per-item verification.

3.6. **Error and edge-case path testing**: After completing the happy-path test steps, perform negative testing on any form, modal, or input the PR introduces or modifies:
   - **Submit empty/incomplete forms**: Click submit/save with required fields empty or partially filled. Verify:
     - Validation messages are user-friendly (not raw framework errors like "The field is required")
     - Error message layout/spacing is consistent with other forms in the app (no irregular margins, no overlapping elements)
     - The form remains usable after validation errors (fields aren't cleared, user can fix and resubmit)
   - **Accidental submissions**: Press Enter in text inputs to check whether premature form submission is handled gracefully (either prevented or shows clean validation).
   - **Boundary inputs**: For numeric, date, or length-constrained fields, test minimum, maximum, and invalid values.
   - Report each negative test as its own row in the results table (e.g., "Step N+1 — Empty form submission", "Step N+2 — Enter key in text field").
   - This is not optional. Happy-path-only testing is insufficient — validation states are a frequent source of UI bugs (unfriendly messages, broken layout, lost form state). Real users trigger these by accident.

3.7. **Verify all instances, not just the first**: When a PR locks, disables, hides, or changes the behavior of a class of UI elements, test ALL visible instances on the page — not just the first or most obvious one:
   - If carrier pay line items should be locked, test that ALL pay lines are locked — including secondary, duplicated, or dynamically-added lines. Scroll the full section.
   - If a tooltip is added, check it on every element that has one — not just the first row.
   - If fields are conditionally disabled, verify the condition applies uniformly across all instances of those fields.
   - A behavior that works on the primary instance but fails on secondary/edge-case instances is a **FAIL**.

3.8. **Post-action UI state verification**: After EVERY mutation action (save, void, cancel, delete, reset, submit, toggle), verify the UI updates to reflect the new state WITHOUT a manual page refresh. A successful action that leaves stale UI is a **FAIL**.
   - **Action menus**: After voiding, the "Void" option should disappear or change to "Unvoid". After completing a request, the option should no longer show as available. Screenshot the action menu AFTER the action.
   - **Counts and labels**: If an action changes a count (e.g., "4 of 6 linked"), verify it updates immediately. If a status label should change, verify it changes.
   - **Form/modal state**: After a save, reopen the form/modal — it should show saved values, not pre-save state. If opened from a cached list, the list entry should also reflect the change.
   - **Stale prop flash**: Navigate away and back (or switch tabs) after the action — verify old state doesn't flash briefly before the new state renders.

3.9. **Cross-view consistency**: If the PR changes a feature that appears in multiple views (e.g., action menu on both loadboard and detail page, or a status on both index table and detail header):
   - Test the feature on ALL views where it appears, not just the one the test steps mention.
   - Common failures: action menu works on detail page but breaks on list page (different resource/serializer with fewer eager-loaded relations), sort order differs between views, disabled states inconsistent between views.
   - Mismatched behavior between views is a **FAIL** — report which views are inconsistent.

4. **AC gap verification**: After completing all "How to test" steps, consult the coverage map from Step A.6. For any AC item marked "No coverage" that has a UI-verifiable behavior:
   - Navigate to the relevant page and check the expected state
   - Take a screenshot: `tests/playwright/{PR}/ac-{NN}-{slug}.png`
   - Record result as PASS, FAIL, or UNVERIFIED
   - This is best-effort — if the AC item genuinely can't be tested via browser (e.g., "uses database transactions"), rely on the code review verdict from Step B

4.5. **Adversarial AC testing**: After the "How to test" steps AND the AC gap verification, go back to each AC item and ask: "Is there another path or scenario that would violate this AC item that the test steps didn't cover?" This catches partial implementations that pass the obvious test but fail on a less-obvious variant.

   For each AC item:
   - **"Block/prevent" AC items**: Try to trigger the blocked behavior through EVERY possible path in the UI, not just the one the test steps covered. If the AC says "block date edits that affect adjacent segments", test ALL types of edits that could affect adjacent segments (start date changes, end date changes, cascading adjustments) — not just the one that shows an error. If ANY path still allows the blocked behavior, that's a **FAIL**.
   - **"Fix/update" AC items**: Verify the fix applies in ALL contexts where the behavior occurs (different pages, different record states, different data configurations), not just the single scenario demonstrated in the test steps.
   - **Inversion test**: If a test step passed by showing the desired behavior (e.g., "overlap warning appears"), deliberately try the opposite scenario — a related action that should ALSO be blocked but might use a different code path. If the old/undesired behavior still occurs on this alternate path, that's a **FAIL**.
   - Report adversarial test results as additional rows in the results table (e.g., "Step N+1 — AC adversarial: end-date cascade path", "Step N+2 — AC adversarial: different record state").
   - Take screenshots for every adversarial test: `tests/playwright/{PR}/ac-adversarial-{NN}-{slug}.png`

---

**End of Sonnet subagent scope.** The subagent returns the complete test results table (Step | Result | Description | Evidence | Screenshot paths) and any test data gaps. The main agent (Opus) uses these results in Step E to make the approve/reject/unverified decision and compose the review comment.

#### Step D.2: Clean up worktree

After the Sonnet subagent returns results, clean up the worktree:
```bash
git worktree remove --force .claude/worktrees/local-test-{PR}
```

Proceed to Step E with the results.

### Step D-alt: Test suite verification (backend-only PRs)

For PRs with no UI changes, skip Playwright and verify via the local test suite instead. These run sequentially since they share the local environment.

1. Clean the working tree and checkout the PR branch — **never use `--detach`**, always check out a proper branch to avoid detached HEAD. Reset any leftover changes, fetch the latest code, and ensure the local branch matches the remote exactly:
   ```bash
   git reset --hard HEAD && git clean -fd
   git fetch origin
   git checkout {branch} && git reset --hard origin/{branch}
   ```
   `git fetch origin` (no branch filter) ensures all refs are up to date. `git reset --hard origin/{branch}` guarantees the local branch is at the latest remote commit — never work on stale code.

2. After switching branches, rebuild the environment. **Run each command as a separate sequential Bash call** — do NOT chain them with `&&`. Long-running chained commands produce no output for minutes and cause stream idle timeouts. Use `timeout: 300000` (5 min) on each call:
   ```bash
   # Call 1
   sail composer install 2>&1
   # Call 2
   sail npm i 2>&1
   # Call 3 — migrate:fresh (timeout: 300000)
   sail php artisan migrate:fresh 2>&1
   # Call 4 — db:seed (timeout: 300000)
   sail php artisan db:seed 2>&1
   # Call 5
   sail php vendor/bin/phpstan clear-result-cache 2>&1
   ```
   **Output a short status line** between each call so the stream stays active.

   **Seed timeout protection:** If `migrate:fresh` or `db:seed` times out or hangs (exit code non-zero after 5 minutes), **do not retry**. Log the failure, skip testing for this PR, and mark all steps as UNVERIFIED with "environment setup failed — seed timed out" as the reason. A single hung seeder must not block the remaining PRs.

   **Skip redundant rebuilds:** Before running `migrate:fresh --seed`, check whether the PR adds or modifies migration files (files in `database/migrations/`). If the PR has no migration changes AND the previous backend-only PR also had no migration changes, you may skip `migrate:fresh --seed` and reuse the existing database state. This saves ~2 minutes per backend-only PR that only changes PHP logic. If in doubt, run the full rebuild.

3. Run the relevant test suite. Determine which tests to run based on the changed files. Use `timeout: 600000` (10 min) since test suites can be slow:
   ```bash
   vendor/bin/sail php artisan test --compact --filter={relevant test class or module} 2>&1
   ```
   If the PR description specifies test commands in "How to test locally", run those instead. **Output a status line before running** (e.g., "Running test suite for {module}...") to keep the stream active.

4. If the PR has "How to test locally" steps that involve API calls, tinker commands, or artisan commands (not browser steps), execute them individually as **separate Bash calls** and capture the output as evidence.

5. Run PHPStan against the changed files (use `timeout: 300000`):
   ```bash
   vendor/bin/sail php vendor/bin/phpstan analyse {changed PHP files} --memory-limit=512M 2>&1
   ```

6. Record results:
   - **Test suite**: PASS (all tests green), FAIL (any test failure), or UNVERIFIED (couldn't determine relevant tests)
   - **PHPStan**: PASS (no errors) or FAIL (errors found)
   - **Manual steps**: PASS/FAIL/UNVERIFIED per step
   - **Track test data gaps** — if you had to use tinker/DB to create preconditions not mentioned in the test steps, or couldn't verify a step due to missing data, record it for the review comment.

7. **AC gap verification**: Consult the coverage map from Step A.6. For AC items with no test coverage, attempt verification via tinker, database queries, or code path tracing. Use `database-query` from laravel-boost or artisan tinker to confirm state changes described in AC items.

8. Clean the working tree and return to main after testing:
   ```bash
   git reset --hard HEAD && git clean -fd && git checkout main
   ```

### Step E: Decide based on test results

**`--self` mode:** Do NOT run any `gh pr review` or `gh pr comment` command. Instead, for each PR, compose an in-chat verdict block with:

- One-line headline: **WOULD PASS**, **WOULD FAIL**, or **WOULD BE UNVERIFIED** in a normal review.
- Per-check table (ACs met, tests passed, PHPStan, schema verified, etc.) — same content as the table that would normally go in the review body.
- Any code review findings from Step C captured in self mode.
- For UI PRs: the Playwright results table. Screenshots stay on disk at `tests/playwright/{PR}/` for the user to inspect.

Then continue to Phase 4. The user can act on the findings themselves; you must never post to GitHub in this mode.

**Default (non-`--self`) mode below.**

**Checklist logic:** Every review comment (approve, reject, or unverified) must include the PR Review Checklist below. For each item, evaluate whether you can honestly check it based on the work you did during this review. Use `[x]` only when you have concrete evidence from your review steps — never check a box speculatively. Here is the guidance for each item:

| Checklist item | Check `[x]` when… |
|---|---|
| Reviewed acceptance criteria | You fetched Jira AC (or used PR description), mapped every item to evidence (test step, code review, or additional verification), and all items are MET with no gaps |
| Validated the behavior | **UI PRs**: All playwright test steps PASS. **Backend-only PRs**: Test suite passes and manual verification steps confirm expected behavior. If any FAIL or are UNVERIFIED, leave unchecked |
| Documented how the change was tested | **UI PRs**: Included the playwright test results table. **Backend-only PRs**: Included test suite output and manual verification results |
| Provided evidence of testing | **UI PRs**: Screenshots, DB queries, logs. **Backend-only PRs**: Test suite output, tinker results, API responses, PHPStan output |
| Implementation makes sense and follows project standards | Code review passed with no critical/warning issues |
| Considered edge cases and potential regressions | Code review explicitly checked for regressions and edge cases |
| No obvious performance, data integrity, or deployment risks | Code review found no performance/data/deployment concerns |

**All steps PASS:**
```bash
gh pr review {PR} --approve --body "$(cat <<'EOF'
## QA Review — APPROVED

### Acceptance Criteria Verification

{For each ticket found, render a section like this. If only one ticket, render one. If multiple, repeat for each:}

#### [<TICKET-ID>](https://intxlog.atlassian.net/browse/<TICKET-ID>)

| AC Item | Status | Evidence |
|---------|--------|----------|
| {AC item 1} | ✅ MET | Playwright Step 3 — PASS |
| {AC item 2} | ✅ MET | Code review — uses DB transaction |
| {AC item 3} | ✅ MET | Additional Playwright verification — screenshot 04 |

{If no Jira tickets were found, replace the entire section above with: "No Jira tickets found — AC verified against PR description."}

### Code Review
{1-2 sentence summary}

{For UI PRs, include the Playwright section:}

### Playwright Test Results

| Step | Result | Description |
|------|--------|-------------|
| 1 | PASS | {step description} |
| ... | ... | ... |

{If any test data gaps were recorded during testing, include this section. Omit entirely if no gaps.}

### Test Data Gaps

> ⚠️ **Test Data Gap** — {Step N} required {specific state/data} but it was not available in the environment. {What was done: "Used tinker to create..." / "Could not create because..." }. Consider adding a setup step to "How to test locally" so other reviewers can reproduce without workarounds.

{Repeat the blockquote for each gap. If tinker/DB was used, note the exact command. If data couldn't be created, explain why.}

### Screenshots
<details>
<summary>View screenshots</summary>

_Screenshots to be added by reviewer._

</details>

{For backend-only PRs, include the Test Suite section instead:}

### Test Suite Results

| Check | Result | Details |
|-------|--------|---------|
| Test suite ({module/filter}) | PASS | {N} tests, {N} assertions |
| PHPStan | PASS | No errors |
| {Manual step from "How to test"} | PASS | {output/evidence} |
| ... | ... | ... |

<details>
<summary>View test output</summary>

```
{paste test suite output here}
```

</details>

## PR Review Checklist

Before approving this PR, confirm the following:

- {[x] or [ ]} I reviewed the **acceptance criteria** and confirmed they are complete.
- {[x] or [ ]} I **validated the behavior** of the change.
- {[x] or [ ]} I documented **how the change was tested**.
- {[x] or [ ]} I provided **evidence of testing when applicable** (screenshot, API response, query result, logs, etc.).
- {[x] or [ ]} I confirmed the implementation **makes sense and follows project standards**.
- {[x] or [ ]} I considered **edge cases and potential regressions**.
- {[x] or [ ]} I see **no obvious performance, data integrity, or deployment risks**.

**Approval indicates the change was reviewed, tested, and is safe to merge.**

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Any step FAIL:**
```bash
gh pr review {PR} --request-changes --body "$(cat <<'EOF'
## QA Review — CHANGES REQUESTED

### Acceptance Criteria Verification

{For each ticket found, render a section. If multiple tickets, repeat for each:}

#### [<TICKET-ID>](https://intxlog.atlassian.net/browse/<TICKET-ID>)

| AC Item | Status | Evidence |
|---------|--------|----------|
| {AC item 1} | ✅ MET | Playwright Step 1 — PASS |
| {AC item 2} | 🔴 NOT MET | Playwright Step 2 — FAIL: {what went wrong} |
| {AC item 3} | ⚠️ NO COVERAGE | No test step covers this; code review inconclusive |

{If no Jira tickets were found, replace the entire section above with: "No Jira tickets found — AC verified against PR description."}

### Code Review: PASS

{For UI PRs:}

### Playwright Test: FAIL

| Step | Result | Description |
|------|--------|-------------|
| 1 | PASS | {step} |
| 2 | FAIL | {step} — {what went wrong} |
| ... | ... | ... |

{If any test data gaps were recorded during testing, include this section. Omit entirely if no gaps.}

### Test Data Gaps

> ⚠️ **Test Data Gap** — {Step N} required {specific state/data} but it was not available in the environment. {What was done: "Used tinker to create..." / "Could not create because..." }. Consider adding a setup step to "How to test locally" so other reviewers can reproduce without workarounds.

### Screenshots
<details>
<summary>View screenshots</summary>

_Screenshots to be added by reviewer._

</details>

{For backend-only PRs:}

### Test Verification: FAIL

| Check | Result | Details |
|-------|--------|---------|
| Test suite ({module/filter}) | PASS / FAIL | {details} |
| PHPStan | PASS / FAIL | {details} |
| {Manual step} | FAIL | {what went wrong} |
| ... | ... | ... |

<details>
<summary>View test output</summary>

```
{paste test suite output here}
```

</details>

## PR Review Checklist

Before approving this PR, confirm the following:

- {[x] or [ ]} I reviewed the **acceptance criteria** and confirmed they are complete.
- {[x] or [ ]} I **validated the behavior** of the change.
- {[x] or [ ]} I documented **how the change was tested**.
- {[x] or [ ]} I provided **evidence of testing when applicable** (screenshot, API response, query result, logs, etc.).
- {[x] or [ ]} I confirmed the implementation **makes sense and follows project standards**.
- {[x] or [ ]} I considered **edge cases and potential regressions**.
- {[x] or [ ]} I see **no obvious performance, data integrity, or deployment risks**.

**Approval indicates the change was reviewed, tested, and is safe to merge.**

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Any steps UNVERIFIED (and none FAIL):**

**HARD BLOCK: You must NOT approve a PR with UNVERIFIED steps. Do NOT use `gh pr review --approve`. Do NOT use `gh api` to submit an approving review.** UNVERIFIED means you failed to verify — that is not approval-worthy. Before reaching this state, go back and try harder: create test data via the UI, query the database, check logs, trace code paths. Only if you have genuinely exhausted every approach should you post a comment (NOT an approval). For each UNVERIFIED step, explain: (1) what you tried, (2) why it couldn't be verified, and (3) what the user or developer needs to do to make it verifiable:

```bash
gh pr comment {PR} --body "$(cat <<'EOF'
## QA Review — UNVERIFIED

### Acceptance Criteria Verification

{For each ticket found, render a section. If multiple tickets, repeat for each:}

#### [<TICKET-ID>](https://intxlog.atlassian.net/browse/<TICKET-ID>)

| AC Item | Status | Evidence |
|---------|--------|----------|
| {AC item 1} | ✅ MET | Playwright Step 1 — PASS |
| {AC item 2} | ⚠️ UNABLE TO DETERMINE | Playwright Step 2 — UNVERIFIED: {what was tried} |
| {AC item 3} | ⚠️ NO COVERAGE | No test step covers this; could not verify via code review |

{If no Jira tickets were found, replace the entire section above with: "No Jira tickets found — AC verified against PR description."}

### Code Review: PASS

{For UI PRs:}

### Playwright Test: PARTIALLY VERIFIED

| Step | Result | Description |
|------|--------|-------------|
| ... | ... | ... |

{Explain what couldn't be verified, what you tried, and why it was impossible}

{If any test data gaps were recorded during testing, include this section. Omit entirely if no gaps.}

### Test Data Gaps

> ⚠️ **Test Data Gap** — {Step N} required {specific state/data} but it was not available in the environment. {What was done: "Used tinker to create..." / "Could not create because..." }. Consider adding a setup step to "How to test locally" so other reviewers can reproduce without workarounds.

### Screenshots
<details>
<summary>View screenshots</summary>

_Screenshots to be added by reviewer._

</details>

{For backend-only PRs:}

### Test Verification: PARTIALLY VERIFIED

| Check | Result | Details |
|-------|--------|---------|
| Test suite ({module/filter}) | PASS / UNVERIFIED | {details} |
| PHPStan | PASS / UNVERIFIED | {details} |
| {Manual step} | UNVERIFIED | {what was tried and why it couldn't be verified} |
| ... | ... | ... |

{Explain what couldn't be verified, what you tried, and why it was impossible}

<details>
<summary>View test output</summary>

```
{paste test suite output here}
```

</details>

## PR Review Checklist

Before approving this PR, confirm the following:

- {[x] or [ ]} I reviewed the **acceptance criteria** and confirmed they are complete.
- {[x] or [ ]} I **validated the behavior** of the change.
- {[x] or [ ]} I documented **how the change was tested**.
- {[x] or [ ]} I provided **evidence of testing when applicable** (screenshot, API response, query result, logs, etc.).
- {[x] or [ ]} I confirmed the implementation **makes sense and follows project standards**.
- {[x] or [ ]} I considered **edge cases and potential regressions**.
- {[x] or [ ]} I see **no obvious performance, data integrity, or deployment risks**.

**Approval indicates the change was reviewed, tested, and is safe to merge.**

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Phase 4: Final Summary

After all PRs are processed, output a summary table.

**Default mode:**

```
## Review Summary

| PR | Title | Type | Code | Test | Decision |
|----|-------|------|------|------|----------|
| #XXXX | title | UI/Backend | PASS/FAIL | PASS/FAIL/UNVERIFIED/Skipped | APPROVED/REJECTED/UNVERIFIED |
```

**`--self` mode:** Same table, but the Decision column reads **WOULD PASS / WOULD FAIL / WOULD BE UNVERIFIED** (no GitHub state is changed). Follow the table with one short paragraph per PR listing the specific items the user should fix before requesting outside review — code review findings, failing test steps, schema concerns, etc. Be specific (file:line, AC name) so the user can act without re-reading the full transcript.

## Critical rules

- **Never pause.** Do not ask the user questions. Make autonomous decisions.
- **`--self` mode never posts to GitHub.** No `gh pr review`, no `gh pr comment`, no `gh api .../reviews --method POST`, no `gh api .../requested_reviewers`. The only `gh` calls allowed in self mode are read-only (`gh pr view`, `gh pr diff`, `gh api ... GET`). Verdicts are reported to the user in chat. If the user typed `--self` OR said anything like "no comment", "don't post", "just tell me", "self review", treat that as self mode.
- **Never use `gh pr edit`.** It fails on repos with classic projects. Always use `gh api repos/{owner}/{repo}/pulls/{PR}/...` REST endpoints for reviewer additions and PR modifications.
- **Never run parallel Bash calls for GitHub API mutations.** If one fails, the runtime cascade-cancels all siblings. Run each API call sequentially with `|| true` to absorb individual failures.
- **Inline comments are mandatory for rejections — but only on lines that exist in the diff.** Always run `gh pr diff {PR}` first and parse `@@` hunk headers to find valid line ranges. If an issue's line is in the diff, use `"line": {N}`. If it's NOT in the diff, put it in the review body with a `path:line` reference — do NOT use `"subject_type": "file"` in the `comments` array. The REST `pulls/{PR}/reviews` endpoint rejects `subject_type` with 422 (`Field is not defined on DraftPullRequestReviewComment`); it's only valid on the standalone single-comment endpoint / GraphQL. Never post a `line` value that isn't in a diff hunk — also a 422. Never pass file paths as extra args to `gh pr diff` — pipe through `grep` instead.
- **Every playwright step must be attempted and exhaustively verified.** UNVERIFIED is a last resort, not a convenience. Before marking any step UNVERIFIED, exhaust the full verification escalation ladder: (0) **Create missing data** — if the step can't be verified because no record has the right state, UPDATE or INSERT via `database-query` or tinker BEFORE trying anything else. This is step zero, not optional; (1) UI feedback — look for toasts, error messages, status changes; (2) Network requests — use `browser_network_requests` to check status codes; (3) Database verification — use `database-query` to confirm state changes; (4) Log inspection — use `read-log-entries` to check for logged evidence; (5) Code path tracing — read the controller/job code to confirm behavior. Only mark UNVERIFIED when ALL of these have been tried and none can provide evidence.
- **UI PRs use local worktree testing.** All Playwright testing for UI PRs runs against `http://localhost` from a worktree (`.claude/worktrees/local-test-{PR}`). The main agent sets up the worktree, starts the dev environment, and runs migrate/seed. Then a Sonnet subagent drives the browser. After testing, the worktree is cleaned up. Do not checkout the PR branch in the main repo for UI PRs — always use a worktree.
- **Backend-only PRs use the local environment.** Only backend-only PRs require local checkout, rebuild, and test suite execution. All backend testing must run from the main repo directory — never from a worktree. Sail containers are bound to the main repo's docker-compose context.
- **Clean up worktrees before backend testing.** After all code review agents complete, remove their worktrees (`git worktree remove --force`) before checking out any PR branch in the main repo. Git blocks checking out a branch that's already checked out in a worktree.
- **Code reviews run in parallel with pre-fetched diffs.** The main agent fetches `gh pr diff` and `git show origin/{branch}:{file}` for each PR, then spawns worktree code review agents with the diff and file contents embedded in the prompt. The pre-fetched diff is the source of truth — even if the worktree checkout fails, the agent has the actual changed code to review.
- **Playwright tests run sequentially.** While code reviews are parallel, Playwright tests share one browser instance and must run one PR at a time.
- **Never checkout in detached HEAD.** Always `git checkout {branch}`, never `git checkout origin/{branch} --detach`. (Backend-only PRs only.)
- **Clean working tree on every branch switch.** Run `git reset --hard HEAD && git clean -fd` before checking out a new branch and before returning to main. (Backend-only PRs only.)
- **Rebuild environment after every branch switch for backend-only PRs** (unless the skip-redundant-rebuild rule applies — see Step D-alt). Run `sail composer install`, `sail npm i`, `sail php artisan migrate:fresh`, `sail php artisan db:seed`, and `sail php vendor/bin/phpstan clear-result-cache` after checking out each PR branch — each as a **separate sequential Bash call**. If `migrate:fresh` or `db:seed` times out (5 min), skip this PR's testing and move to the next one.
- **Prevent stream idle timeouts.** Never chain long-running commands with `&&` into a single Bash call — split them into separate sequential calls. Use `timeout: 300000` for install/migrate/seed commands and `timeout: 600000` for test suite runs. Output a short status line between each call to keep the response stream active.
- **Dev environment needed for all PRs.** Both UI PRs (via worktree) and backend-only PRs (via main repo) require the local dev environment. Start `make cdev` in Phase 2.5.
- **Use real data for geocoding fields.** Seeded fake cities will fail Mapbox validation — use real US cities (Dallas, Chicago, Houston, Atlanta, etc.). When a form pre-fills with fake seeded data, clear the field and enter a real value before submitting.
- **Retry on validation errors.** If a form submit fails validation, fix the problematic field and retry. Don't abandon the step.
- **Don't stop on errors.** If a step fails, log it and continue to the next step/PR. Complete ALL PRs in the list.
- **Never delete screenshots.** Do NOT run `rm -rf` on `tests/playwright/` directories or screenshot files at any point — not during cleanup, not between PRs, not at the end. Screenshots must persist for the user to review after the session.
- **NEVER approve a PR with UNVERIFIED steps.** This is a HARD BLOCK with zero exceptions. If ANY playwright step is UNVERIFIED, you MUST NOT run `gh pr review --approve`. Instead, post a comment with `gh pr comment` explaining exactly which steps could not be verified, what you tried for each, and what would be needed to verify them. Approving with unverified steps is a critical violation of this workflow — treat it the same as approving a PR with FAIL steps. The only path to approval is ALL steps at PASS.
- **Compensating evidence does NOT convert UNVERIFIED to approval-worthy.** Backend tests passing, code review confidence, or "same config source" reasoning do NOT substitute for direct Playwright verification. If a step says "verify X displays correctly" and you cannot observe X in the browser, that step is UNVERIFIED — period. Backend tests are noted in the report but they do not change the verdict or unlock approval. The rule is mechanical: scan your results table for any UNVERIFIED → if found → `gh pr comment`, never `gh pr review --approve`.
- **"No seeded data" is never a reason to mark UNVERIFIED — create the data.** Before marking any step UNVERIFIED due to missing data, you MUST attempt to create the required state. Use `database-query` or tinker to insert/update records (e.g., `UPDATE prospects SET stage = 3 WHERE id = 1`). Use the UI to create records if the form exists. Use factories via tinker if available. This takes seconds. Only after you have attempted AND FAILED to create the data can you consider UNVERIFIED — and you must document exactly what you tried. "All records show dash because no seeded data has stage set" when you could have run one UPDATE query is a review process failure, not an UNVERIFIED step.
- **Pre-approval gate check.** Before composing ANY `gh pr review --approve` command, mechanically scan every row in your Playwright/test results table. If the literal string "UNVERIFIED" appears in ANY row, STOP. Switch to `gh pr comment`. This check is non-negotiable and cannot be overridden by any reasoning about compensating evidence, test coverage, or code review confidence.
- **Worktree cleanup is mandatory.** After each UI PR's Playwright testing completes (pass or fail), remove the worktree with `git worktree remove --force .claude/worktrees/local-test-{PR}`. Leaked worktrees block subsequent PRs from checking out the same branch.
- **Rendered ≠ functional — never PASS based on visual presence alone.** Seeing an element (button visible, menu item listed, text correct) is necessary but NOT sufficient for PASS. Functional steps require interaction: clicking a button must open its target, submitting a form must process, state changes must reflect in the UI. A dropdown that lists all the right items but whose items don't work when clicked is a **FAIL**. If you cannot click through and observe the result, the step is UNVERIFIED — not PASS.
- **Action menus require per-item click-testing.** When a PR adds or modifies an action menu, dropdown, or any multi-item interactive component, click EVERY item individually and verify its behavior. This is mandatory regardless of whether the PR's test steps enumerate each item. Report each item as a separate row in the test results table. A menu that renders correctly but has items that open modals which immediately close, trigger errors, or fail to update state is a FAIL for each broken item.
