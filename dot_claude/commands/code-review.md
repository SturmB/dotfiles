---
allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(gh pr comment:*), Bash(gh pr diff:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh api:*), Bash(git log:*), Bash(git blame:*), Bash(git diff:*), Bash(git show:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git -C:*), Bash(sed:*), Bash(grep:*), Bash(head:*), Bash(tail:*), Bash(awk:*), Bash(cat:*), Bash(wc:*), Bash(echo:*), Bash(mktemp:*), Bash(rm:*)
description: Code review a pull request
disable-model-invocation: false
---

Provide a code review for the given pull request.

CRITICAL TOOL USAGE RULES — Include these rules verbatim in every agent prompt:
- To read files, use the Read tool (with offset/limit for specific line ranges). NEVER use cat, head, tail, or sed to read files.
- To search file contents, use the Grep tool. NEVER use bash grep or rg.
- To find files by name, use the Glob tool. NEVER use bash find or ls.
- Only use Bash for: (1) `gh` commands to interact with GitHub, (2) `git` commands for blame/log/diff/show history.
- Do NOT use Bash with echo to write analysis summaries — just return your findings as text output.
- Do NOT use awk/sed/head/grep to post-process tool results — use Read with offset/limit or Grep with context lines instead.

PARALLELISM RULES — To run agents in parallel, you MUST make multiple Task tool calls in a SINGLE response message. If you call Task once, wait for the result, then call Task again, they run sequentially. Only calls made in the same response message run concurrently.

To do this, follow these steps precisely:

1. Launch 3 Haiku agents IN PARALLEL (all 3 Task calls in one response message):
   a. Eligibility check: Is the pull request (a) closed, (b) a draft, (c) not needing review (eg. automated PR or trivially obvious), or (d) already reviewed by you? If any apply, return "SKIP" with the reason.
   b. CLAUDE.md discovery: Return a list of file paths to relevant CLAUDE.md files — the root CLAUDE.md (if it exists) and any CLAUDE.md files in directories whose files the PR modified.
   c. PR summary: View the pull request and return a summary of the change.
2. If the eligibility check returned "SKIP", stop here — do not proceed.
3. Launch 5 Sonnet agents IN PARALLEL (all 5 Task calls in one response message) to independently code review the change. Include the CRITICAL TOOL USAGE RULES above in each agent's prompt. Each agent should return a list of issues with the reason each was flagged (eg. CLAUDE.md adherence, bug, historical git context, etc.):
   a. Agent #1: Audit the changes to make sure they comply with the CLAUDE.md. Note that CLAUDE.md is guidance for Claude as it writes code, so not all instructions will be applicable during code review.
   b. Agent #2: Read the file changes in the pull request (use `gh pr diff` then Read/Grep to analyze), then do a shallow scan for obvious bugs. Avoid reading extra context beyond the changes, focusing just on the changes themselves. Focus on large bugs, and avoid small issues and nitpicks. Ignore likely false positives.
   c. Agent #3: Use `git blame` and `git log` for history, then use Read tool to examine the actual file contents to identify any bugs in light of that historical context
   d. Agent #4: Use `gh pr list` and `gh api` to find previous pull requests that touched these files, and check for any comments on those pull requests that may also apply to the current pull request.
   e. Agent #5: Use Read tool to read the modified files, and make sure the changes in the pull request comply with any guidance in the code comments.

   **Structured output for each issue** — Include these rules verbatim in every agent prompt:
   For each issue found, return all of the following fields:
   - `description`: What the issue is and why it matters
   - `reason`: Why it was flagged (eg. CLAUDE.md adherence, bug, historical context)
   - `path`: File path relative to repo root
   - `start_line`: First line number in the file where the issue occurs
   - `end_line`: Last line number (same as start_line for single-line issues)
   - `original_code`: The exact original code being flagged, copied verbatim from the file preserving all indentation and whitespace
   - `suggested_code`: (OPTIONAL) A concrete replacement for the original code, preserving correct indentation. Only include this when:
     (a) A clear, localized fix exists that doesn't require changes elsewhere in the file or codebase
     (b) The fix is unambiguous — there is one obviously correct replacement, not a design choice
     (c) The replacement can fully stand on its own without additional context or surrounding changes
     Do NOT include `suggested_code` for architectural issues, missing functionality, design decisions, or fixes that require coordinated changes across multiple locations.
4. Collect all issues from the 5 agents. For each issue, launch a Haiku agent to score it — launch ALL scoring agents IN PARALLEL (all Task calls in one response message). Each agent takes the PR, issue description, and list of CLAUDE.md files (from step 1b), and returns a confidence score. For issues flagged due to CLAUDE.md instructions, the agent should double check that the CLAUDE.md actually calls out that issue specifically. The scale is (give this rubric to the agent verbatim):
   a. 0: Not confident at all. This is a false positive that doesn't stand up to light scrutiny, or is a pre-existing issue.
   b. 25: Somewhat confident. This might be a real issue, but may also be a false positive. The agent wasn't able to verify that it's a real issue. If the issue is stylistic, it is one that was not explicitly called out in the relevant CLAUDE.md.
   c. 50: Moderately confident. The agent was able to verify this is a real issue, but it might be a nitpick or not happen very often in practice. Relative to the rest of the PR, it's not very important.
   d. 75: Highly confident. The agent double checked the issue, and verified that it is very likely it is a real issue that will be hit in practice. The existing approach in the PR is insufficient. The issue is very important and will directly impact the code's functionality, or it is an issue that is directly mentioned in the relevant CLAUDE.md.
   e. 100: Absolutely certain. The agent double checked the issue, and confirmed that it is definitely a real issue, that will happen frequently in practice. The evidence directly confirms this.
5. Filter out any issues with a score less than 50. If there are no issues that meet this criteria, do not proceed.
6. Use a Haiku agent to repeat the eligibility check from step 1a, to make sure that the pull request is still eligible for code review.
7. Finally, post the result as a **PR review with inline comments** using `gh api`. Each issue becomes an inline comment on the specific file and line, creating a resolvable conversation thread.
   - Determine the review event type:
     - If ANY issue scored **80 or higher**, use `event=REQUEST_CHANGES`
     - Otherwise, use `event=COMMENT`
   - For each issue, determine the exact `path` (relative to repo root) and `line` number (on the diff's new-file side) where the issue occurs. The line MUST be within the diff hunk for that file — if the issue is on a line not in the diff, use the nearest changed line instead.
   - Build the review JSON payload and post using `gh api`. Write the JSON to a temp file first to avoid shell escaping issues:
     ```
     TMPFILE=$(mktemp /tmp/review-XXXXXX.json)
     cat > "$TMPFILE" << 'REVIEW_JSON'
     { "event": "<EVENT>", "body": "<SUMMARY>", "comments": [<COMMENTS>] }
     REVIEW_JSON
     gh api repos/{owner}/{repo}/pulls/{number}/reviews --method POST --input "$TMPFILE"
     rm -f "$TMPFILE"
     ```
   - Each comment object in the `comments` array uses this schema:
     - **Without suggestion** (no `suggested_code`, or score below 75):
       ```json
       {"path": "relative/file/path", "line": <line_number>, "body": "<issue description>"}
       ```
     - **With suggestion on a single line** (`suggested_code` exists, `start_line == end_line`, score >= 75):
       ```json
       {"path": "relative/file/path", "line": <line_number>, "body": "<issue description>\n\n```suggestion\n<suggested_code>\n```"}
       ```
     - **With suggestion spanning multiple lines** (`suggested_code` exists, `start_line != end_line`, score >= 75):
       ```json
       {"path": "relative/file/path", "start_line": <start_line>, "line": <end_line>, "body": "<issue description>\n\n```suggestion\n<suggested_code>\n```"}
       ```
     IMPORTANT constraints for suggestions:
     - `line` and `start_line` MUST reference lines on the new-file side of the diff and MUST fall within a diff hunk. If they don't, drop the suggestion and post as a plain comment instead.
     - The `suggested_code` completely replaces all lines from `start_line` through `line` (inclusive). It must include every replaced line's content — not just the changed parts.
     - Preserve exact indentation in `suggested_code`. A single wrong space will produce a broken suggestion.
     - Verify the `original_code` from the agent matches what's actually in the diff. If it doesn't match, drop the suggestion and post as a plain comment instead.
   - The review `body` should be a brief summary (e.g., "### Code review\n\nFound 3 issues — see inline comments.")
   - When writing each inline comment body, keep in mind to:
     a. Keep your output brief
     b. Avoid emojis
     c. Include the confidence score as a bold prefix, e.g., **[75]**
     d. Cite relevant CLAUDE.md rules or code context
     e. Place the suggestion block (if any) AFTER the explanation, as the last element of the comment body

Examples of false positives, for steps 3 and 4:

- Pre-existing issues
- Something that looks like a bug but is not actually a bug
- Pedantic nitpicks that a senior engineer wouldn't call out
- Issues that a linter, typechecker, or compiler would catch (eg. missing or incorrect imports, type errors, broken tests, formatting issues, pedantic style issues like newlines). No need to run these build steps yourself -- it is safe to assume that they will be run separately as part of CI.
- General code quality issues (eg. lack of test coverage, general security issues, poor documentation), unless explicitly required in CLAUDE.md
- Issues that are called out in CLAUDE.md, but explicitly silenced in the code (eg. due to a lint ignore comment)
- Changes in functionality that are likely intentional or are directly related to the broader change
- Real issues, but on lines that the user did not modify in their pull request
- Issues from git-workflow rules (eg. PR title format, Jira ticket format, commit message conventions). The code review focuses on code, not PR metadata.

Notes:

- Do not check build signal or attempt to build or typecheck the app. These will run separately, and are not relevant to your code review.
- Use `gh` to interact with Github (eg. to fetch a pull request, or to create inline comments), rather than web fetch
- Make a todo list first
- You must cite and link each bug (eg. if referring to a CLAUDE.md, you must link it)
- The review body (top-level summary) should follow this format:

---

### Code review

Found 3 issues — see inline comments.

🤖 Generated with [Claude Code](https://claude.ai/code)

<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>

---

- Or, if you found no issues:

---

### Code review

No issues found. Checked for bugs and CLAUDE.md compliance.

🤖 Generated with [Claude Code](https://claude.ai/code)

---

- Each inline comment should follow this format:

**[75]** <brief description of bug> (CLAUDE.md says "<...>")

<explanation of the issue and why it matters>

```suggestion
$correctedCode = $this->properFix();
```

- The suggestion block is OPTIONAL — only include it when the agent provided `suggested_code` AND the issue scored >= 75. For issues without a concrete fix, or scores below 75, use just the description and explanation (no suggestion block).
- When a suggestion is included, it MUST be the last element in the comment body, after the explanation.

- When linking to code, follow the following format precisely, otherwise the Markdown preview won't render correctly: https://github.com/anthropics/claude-cli-internal/blob/c21d3c10bc8e898b7ac1a2d745bdc9bc4e423afe/package.json#L10-L15
  - Requires full git sha
  - You must provide the full sha. Commands like `https://github.com/owner/repo/blob/$(git rev-parse HEAD)/foo/bar` will not work, since your comment will be directly rendered in Markdown.
  - Repo name must match the repo you're code reviewing
  - # sign after the file name
  - Line range format is L[start]-L[end]
  - Provide at least 1 line of context before and after, centered on the line you are commenting about (eg. if you are commenting about lines 5-6, you should link to `L4-7`)
