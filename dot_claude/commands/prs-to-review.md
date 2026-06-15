---
name: prs-to-review
description: Show PRs needing my review attention — re-reviews first, then 0/1-review PRs I haven't touched
model: sonnet
allowed-tools: Bash
---

## Step 1 — Bulk fetch open PRs (no `commits` field, to stay under GraphQL's 500k-node limit)

```bash
ME=$(gh api user --jq .login)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

gh pr list --repo "$REPO" --state open --limit 100 --json number,title,author,url,createdAt,reviewRequests,reviews,isDraft --jq "
  [.[] | select(.isDraft | not) | select(.author.login != \"$ME\")] |
  [.[] | . as \$pr | {
    number,
    title,
    url,
    author: \$pr.author.login,
    requested_reviewers: (
      [.reviewRequests[] | select(.login != null) | select(.login | ascii_downcase | test(\"^claude\") | not) | .login] | unique | join(\", \")
    ),
    my_reviews_count: ([.reviews[] | select(.author.login == \"$ME\") | select(.body != \"No issues found. Checked for bugs and CLAUDE.md compliance.\")] | length),
    my_last_review_at: ([.reviews[] | select(.author.login == \"$ME\") | select(.body != \"No issues found. Checked for bugs and CLAUDE.md compliance.\") | .submittedAt] | sort | last),
    i_am_requested: ([.reviewRequests[] | select(.login == \"$ME\")] | length > 0),
    review_count: (
      \$pr.author.login as \$author |
      [.reviews[] | select(.author.login != null) | select(.body != \"No issues found. Checked for bugs and CLAUDE.md compliance.\") | select(.author.login | ascii_downcase | test(\"^claude\") | not) | select(.author.login != \$author)] |
      group_by(.author.login) | length
    ),
    review_status: (
      \$pr.author.login as \$author |
      [.reviews[] | select(.author.login != null) | select(.body != \"No issues found. Checked for bugs and CLAUDE.md compliance.\") | select(.author.login | ascii_downcase | test(\"^claude\") | not) | select(.author.login != \$author) | {author: .author.login, state, submittedAt}] |
      group_by(.author) |
      [.[] | {author: .[0].author, state: (sort_by(.submittedAt) | .[-1].state)}] |
      map(
        if .state == \"APPROVED\" then \"\(.author):approved\"
        elif .state == \"CHANGES_REQUESTED\" then \"\(.author):changes requested\"
        elif .state == \"COMMENTED\" then \"\(.author):commented\"
        else \"\(.author):\(.state)\"
        end
      ) | join(\", \")
    ),
    days: (((now - (.createdAt | fromdateiso8601)) / 86400) | floor)
  }]
"
```

Save this JSON. Each item has `my_reviews_count`, `my_last_review_at`, `i_am_requested`, `review_count`.

## Step 2 — For PRs where I've already reviewed, fetch the latest commit date

For every PR with `my_reviews_count > 0`, fetch its latest commit timestamp individually. Run one command per such PR (or chain them with `;`):

```bash
gh pr view <number> --repo "$REPO" --json commits --jq '[.commits[] | .committedDate // .authoredDate] | sort | last'
```

If there are no PRs where I've reviewed, skip this step entirely.

## Step 3 — Compute filters in your head (or in jq, your choice)

For each PR, derive:
- `i_reviewed` = `my_reviews_count > 0`
- `new_commits_since_my_review` = `i_reviewed` is true AND `my_last_review_at` is set AND latest_commit_at (from Step 2) > `my_last_review_at`
- `needs_rereview` = `new_commits_since_my_review` OR (`i_am_requested` AND `i_reviewed`)
- `needs_first_review` = `review_count <= 1` AND NOT `i_reviewed`

Keep only PRs where `needs_rereview` OR `needs_first_review` is true. Sort by `days` descending (oldest first).

## Step 4 — Resolve display names

Load `~/.claude/github-to-teams.json`. Replace **all** GitHub usernames with display names in the output (authors, requested reviewers, review_status names). Fall back to the GitHub username when not in the mapping.

## Output format

Split results into two buckets:
1. **Re-reviews** — PRs where `needs_rereview` is true.
2. **Needs first review** — PRs where `needs_first_review` is true AND `needs_rereview` is false.

### Section 1: Dashboard view

Heading `--- Needs Re-Review ---`. For each re-review PR (oldest first by `days`):

- `#<number> <title> (<author display name>, created <days> days ago) | <review_status>`
- If `requested_reviewers` is non-empty, append ` [assigned: <reviewer display names>]`.
- If `new_commits_since_my_review`, append ` [new commits since my review]`.
- If `i_am_requested`, append ` [re-requested]`.

Heading `--- Needs First Review (0–1 reviews, not reviewed by me) ---`. Group by `review_count` with subheaders `--- 0 reviews ---` and `--- 1 review ---`. Within each group, sort oldest first:

- `#<number> <title> (<author display name>, created <days> days ago)`
- For the 1-review group, append ` | <review_status>`.
- If `requested_reviewers` is non-empty, append ` [assigned: <reviewer display names>]`.

If a bucket is empty, print its heading with `(none)` underneath.

### Section 2: Comma-separated PR numbers

Heading `--- PR Numbers ---` followed by a single line of comma-separated PR numbers (no `#` prefix). Re-reviews first (oldest first), then needs-first-review PRs (0-review group before 1-review group, oldest first within each).

Example:
```
1234, 1198, 1402, 1455
```

Do not output a markdown table. Do not output anything other than the headings and the listed items.
