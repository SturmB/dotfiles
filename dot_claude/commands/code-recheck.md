---
name: code-recheck
description: Triple-check recent work for bugs, performance issues, memory leaks, N+1 queries, and other problems
---

You are a ruthless, detail-oriented code reviewer. Your job is to triple-check the work that was just done in this conversation. ultrathink

## Step 1: Identify what changed

Look at the current conversation context to understand what code was just written or modified. Then gather all changes using these approaches:

1. **Uncommitted changes**: Run `git diff` and `git diff --cached` to see unstaged and staged changes.
2. **Committed changes on this branch**: Run `git log --oneline main..HEAD` to see commits on this branch not yet in main, then run `git diff main...HEAD` to see the full diff of all committed changes compared to main.

Review both uncommitted and committed changes — work that has already been committed still needs scrutiny.

## Step 2: Deep review with extended thinking

Think extremely deeply and carefully. Use your absolute maximum reasoning capabilities to analyze every change. For each file modified, read the full file (not just the diff) to understand the surrounding context.

Check for ALL of the following:

### Correctness
- Logic errors, off-by-one errors, wrong comparisons
- Missing null/undefined checks at system boundaries
- Race conditions or concurrency issues
- Incorrect error handling (swallowed errors, wrong error types)
- Edge cases that aren't handled
- **PHP loose truthiness traps** — `0 ? ...` treats a user's explicit `$0` value as falsy; use strict comparisons (`!== null`, `!== ''`) instead of `empty()` or bare truthiness when zero is a valid value
- **Strict equality type mismatches** — `1 === true` is always false in JavaScript; `(int) === (bool)` comparisons are a common source of silent failures
- **Mutable Carbon instances** — `addDays()`, `subDays()`, etc. mutate in-place; if the original date is reused later, both values are wrong. Use `->copy()->addDays()` or `CarbonImmutable`
- **Scope gaps** — records that fall between two query conditions and become invisible to all views (e.g., completed but not finalized, so neither the "open" nor "closed" tab shows them)
- **Checkbox stuck states** — a boolean that can be set `true` by one condition but the UI control to unset it only renders under a different condition, leaving it permanently stuck
- **Eloquent `select()` clobbering computed columns** — `$query->select('table.*', ...)` in sort scopes or other scopes replaces the entire SELECT clause, silently dropping any `selectRaw()` or `addSelect()` columns added earlier in the query chain (e.g., computed CASE expressions, subquery aliases). Use `addSelect()` in scopes that add sort columns to avoid wiping out existing selects
- **Derived flag/scope completeness** — when a new status or state is introduced (e.g., "voided"), trace ALL existing derived boolean flags, scopes, and UI disable-checks that reference related states. A flag like `is_canceled_or_tonu` that doesn't include the new "voided" state leaves 34+ UI disable-checks broken — fields appear editable on voided records. Search the codebase for every consumer of the related flags
- **`mergeWhen`/`whenLoaded` silently dropping API fields** — moving a field (e.g., `team_email`) inside a `mergeWhen($condition)` block means it's silently omitted from the API response when the condition is false. Trace all frontend consumers of the field — if ANY consumer reads it in a context where the condition is false, the field vanishes and the feature breaks without errors
- **Frontend/backend environment or config mismatches** — if a feature is gated by environment checks, verify both frontend (computed property, `import.meta.env`) and backend (controller, middleware) use the same environment list. A mismatch means the feature is accessible on environments where the UI hides it, or vice versa
- **Non-deterministic subquery results** — correlated subqueries that return a scalar (e.g., `resolved_at`, `resolution`) without `ORDER BY` + `LIMIT 1` can return values from different rows. Add explicit ordering and a tiebreaker (e.g., `id DESC`) to guarantee both values come from the same row

### Performance
- **N+1 queries** — loops that trigger individual DB/API calls instead of batching. Watch for `->relationship()` with parentheses (fires a fresh query) vs `->relationship` (uses eager-loaded collection). Also watch for `->exists()` on a relation that bypasses an already-eager-loaded collection
- Unnecessary re-renders or recomputations
- Missing indexes on queried fields — especially new columns used in `where`, `orderBy`, or correlated subqueries
- **Non-sargable expressions** — wrapping a column in a function (`REGEXP_REPLACE(col, ...)::BIGINT`, `LOWER(col)`, `CAST(col AS ...)`, `DATE(timestamp)`) inside `WHERE`/`MAX`/`ORDER BY` makes plain B-tree indexes unusable, forcing a sequential scan that worsens as the table grows. Either add a functional/expression index matching the exact expression, or store the derived value in a generated/indexed column. For monotonic counters specifically, prefer a `SEQUENCE` over `MAX()+1` (O(1), no lock required)
- O(n^2) or worse algorithms where O(n) or O(n log n) is possible
- Unbounded data fetching (missing LIMIT, pagination)
- Expensive operations inside hot loops
- **Orphaned eager loads** — `with('relation')` that loads data never consumed by the response, wasting a SQL query on every request
- **Computed fields on list views** — expensive per-row computations running unconditionally on index/list endpoints where the data isn't displayed; use `mergeWhen` or conditional loading

### Memory & Resources
- Memory leaks (event listeners not cleaned up, subscriptions not unsubscribed, timers not cleared)
- Growing caches or maps without eviction
- Large objects held in closures unnecessarily
- Missing cleanup in component unmount / object disposal
- File handles or connections not closed

### Security
- Injection vulnerabilities (SQL, command, XSS)
- Missing input validation/sanitization at boundaries
- Hardcoded secrets or credentials
- Insecure defaults
- **Authorization depth** — don't just check "is there a gate/policy check?"; verify all of these:
  - Server-side enforcement exists (not just frontend `v-if`/`v-show`) — any authenticated user can craft an HTTP request
  - Frontend and backend use the **same permission name** (e.g., `manage_roles` vs `manage_user_roles` mismatch)
  - New permissions have a **database migration** to create them, not just a seeder (seeders don't run in all environments)
  - Scoped list visibility matches detail access — if `index` uses a scope to filter records, `show`/`update`/`destroy` must enforce the same scope, not just check `Gate::authorize`
  - **Team/customer membership validation** — `team_id` or `customer_id` from user input must be verified against the user's actual memberships, not just `exists:teams,id`
  - Buttons/UI for gated actions are hidden when the user lacks permission (no visible button → 403 on click)
- **Frontend-only business rule enforcement** — if the UI gates an action behind a prerequisite check (e.g., "task X must be completed before dispatch"), verify the backend request handler/FormRequest has a corresponding validation rule. A direct HTTP request will bypass frontend guards entirely. Look for sibling guards in the same request class and ensure new prerequisites follow the same pattern
- **Unpinned third-party GitHub Actions** — use commit SHA pins, not mutable tags like `@v4` or `@latest`
- **PII/secrets in logs** — API tokens in URLs, full request bodies containing PII logged to monitoring systems
- **Path traversal** — external/user-supplied strings used in filenames without sanitization

### Reliability
- Missing or incorrect error handling
- Silent failures that should be logged or surfaced
- Broken error propagation
- Missing retries for transient failures where appropriate
- Inconsistent state after partial failures
- **Queue job retry patterns:**
  - `$this->fail()` permanently kills the job — if the error is transient, `throw` the exception instead and let `$tries` handle retries
  - `ShouldBeUnique` is bypassed by `dispatchSync` — concurrent sync dispatches can create duplicates
  - `Cache::remember` that stores an error/empty response caches the failure state for the entire TTL
  - `uniqueFor` value matching the batch/cron cadence exactly, creating a race window where duplicates slip through
- **External API calls inside DB transactions** — if the API call fails after the transaction commits partial state, or succeeds but the transaction rolls back, data is inconsistent. Move API calls outside the transaction or use a saga/outbox pattern
- **Idempotency guard ordering** — if a "sent" or "processed" timestamp is set BEFORE the external API call, failed first attempts set the guard, so retries short-circuit and the operation never actually completes. The idempotency flag must be set AFTER the operation succeeds, not before
- **Lock scope must cover the dependent write** — `pg_advisory_xact_lock()` (and any `_xact_` advisory lock) releases when the transaction commits. If the lock + `MAX()`/read run inside `DB::transaction(...)` but the `update()`/`insert()` that depends on that read happens AFTER the closure returns, two concurrent callers can read the same value, release, then both write the same derived value → unique constraint violation or duplicate sequence. The write must live inside the same transaction as the lock. Same pattern applies to `LOCK TABLE`, `SELECT ... FOR UPDATE`, and `Cache::lock()` blocks — verify the lock is still held when the write executes
- **Saloon/HTTP fake scope leakage** — `Saloon::fake()` activates global mock mode for ALL connectors, not just the one being tested. If model events fire side-effect jobs (e.g., `SyncCarrierToRelay` on `Carrier::saved`), those jobs hit `NoMockResponseFoundException` unless explicitly mocked or faked with `Bus::fake()`. The old Mockery approach didn't have this scope issue

### Soft-Delete Discipline
- **Raw SQL / `DB::table()` queries on soft-deletable models missing `WHERE deleted_at IS NULL`** — Eloquent's `SoftDeletes` global scope does NOT apply to raw queries, `DB::table()`, raw JOINs, or database views. Every raw reference to a soft-deletable table must include the filter explicitly
- **Raw JOIN clauses** — when joining to a soft-deletable table in a raw SQL string or `DB::raw()`, the `deleted_at IS NULL` must go in the ON clause or WHERE clause
- **Database views** — views referencing soft-deletable tables must include the filter in their definition
- **Migrations with UPDATE/DELETE** — bulk DML in migrations that touches soft-deletable tables without filtering `deleted_at IS NULL` will modify/return deleted records
- **Validation rules** — `exists:table,column` bypasses soft-delete scoping; a soft-deleted record's ID will pass validation then 404 on `findOrFail`

### i18n / Internationalization
- **All user-facing strings must be wrapped in translation helpers** — `$t()` or `t()` (from `useI18n()`) in Vue templates/scripts, `__()` in PHP/Blade
- Check labels, button text, toast messages, error messages, Swal/confirmation dialogs, column headers, tab names, placeholder text, and tooltip content
- Strings in `<script setup>` need `const { t } = useI18n()` and then `t('key')`, not just template-side `$t()`
- Don't forget fallback/error messages in catch blocks and validation failure paths

### Test Quality
If the diff includes test files, scrutinize them as carefully as the production code:

- **Vacuous tests** — would this test still pass if the code under test were deleted or broken? If yes, the assertion is too weak. Tests that only assert count/existence without verifying values, or that mock away the thing they claim to test
- **Changed behavior not covered by tests** — if production code was modified (e.g., switching from `props.document.file_name` to `form.file_name`), verify an existing or new test actually exercises and asserts on the specific changed behavior. Tests that pass for both the old and new code prove nothing about the change
- **Mock fidelity** — mocks that discard arguments (`return true` regardless of input), making it impossible to catch regressions. `assertSent`/`assertDispatched` callbacks that match too broadly
- **Global state leaks** — `global.route`, `globalThis.confirm`, `globalThis.useAuth` assigned in `beforeEach` but never restored in `afterEach`. `vi.clearAllMocks()` does NOT undo `globalThis.X = ...`
- **Time leaks** — `travelTo()` called without `travelBack()` in `afterEach`; frozen time leaks into subsequent tests and causes flaky failures near date boundaries
- **Shared mutable fixtures** — `reactive()` or plain objects defined at module scope and mutated in tests; mutations accumulate across test cases
- **Over-mocking** — mocking the interface/class under test instead of its dependencies; `vi.mock()` overriding global `setup.js` mocks and accidentally stripping other exports
- **Unnecessary global imports** — `describe`, `it`, `expect`, `beforeEach` are Vitest globals (via `globals: true`) and should not be imported; only `vi` needs importing
- **Event listener / observer cleanup** — `Model::creating` listeners or event subscribers registered in tests but never cleaned up, poisoning subsequent tests
- **Factory data that masks bugs** — test fixtures using identical values for `id` and `key`, or numeric values that happen to match, so a field-swap regression is invisible
- **Trivially-true ordering/filtering assertions** — tests that assert a collection has N items or that "sent" items exist, but don't verify WHICH items or in what ORDER. If the feature is "send the oldest 50", the test must assert the specific IDs match the expected oldest 50, not just that 50 were sent
- **Missing exception types in union catches** — `catch (ExceptionA | ExceptionB $e)` that omits a type thrown by a called method (e.g., `RuntimeException` from `throw_unless`). The uncaught exception bypasses the error handling entirely

### Accidentally Deleted Files
Automated tools (pre-commit hooks, linters, formatters) can silently delete files they incorrectly flag. Run this check:

```bash
git diff main...HEAD --diff-filter=D --name-only
```

For every deleted file, verify it was **intentionally** removed as part of this PR's purpose:
- **Vue components deleted by pre-commit hooks** — `find-unused-components.js` can't trace Inertia `render()` calls in PHP or imports in JS test files. If a `.vue` file in `Pages/` or `Partials/` was deleted but no commit message mentions removing it, it was likely a false positive
- **Test files deleted alongside components** — if a component was incorrectly deleted, its test file may also have been swept up in the same commit
- **Config/asset files removed by cleanup scripts** — verify against the base branch: `git show main:<path>` to confirm the file existed and wasn't already removed

If you find files that were deleted but shouldn't have been, flag them as **critical** severity.

### Refactoring Completeness
When changes involve refactoring, moving, or removing code:

- **Accidental feature deletion** — form fields, checkboxes, UI sections, or functionality silently removed during refactoring that were NOT part of the intended change. Read the full component before and after to verify no features disappeared
- **Orphaned call sites** — if a component, modal, mixin, or composable was moved/renamed, verify ALL call sites were updated. Check for modals removed from a global/layout collection but never re-mounted at their page-level usage points
- **Dead references** — computed properties, watchers, or event listeners referencing renamed/removed props, relationships, or variables. `whenLoaded('oldName')` after a relationship was renamed to `'newName'`
- **Stale factory/test helpers** — factory method names, test helper names, or permission names that were renamed in production code but not in test files

### Frontend Reactivity & State
For Vue/Inertia changes:

- **Stale props after Axios saves** — if a form uses `axios.patch()` instead of Inertia's `router.patch()`, Inertia page props are NOT refreshed; computed properties reading from `props.X` will be stale until the next full navigation
- **Stale URL params** — closing a panel/modal that was opened via URL query param (`?id=X`) without clearing the param; refreshing the page reopens a stale/empty panel
- **State carryover on SPA navigation** — reactive state (expanded rows, selected tabs, form data) that persists when navigating between records via Inertia, showing the previous record's state
- **Async race conditions** — rapid user actions (switching tabs, typing in search, clicking multiple loads) where a stale response from an earlier request overwrites a correct later response. Missing `AbortController` cancellation on superseded requests
- **Debounce timing in tests** — tests using `await nextTick()` to test debounced behavior; the debounce timer hasn't fired yet, so the test passes trivially
- **`finally` blocks clearing loading state** while a superseding request is still in-flight
- **IntersectionObserver / scroll listeners** disconnected on search/filter but never reconnected
- **Stale UI after mutations** — after a successful action (void, cancel, save, reset), verify the UI reflects the new state without a manual page refresh. Common misses: action menu still shows "Void" after voiding (should show "Unvoid" or disappear), completed request option still visible, linked count not updating. Check that `router.reload()` or prop updates cover ALL affected UI elements, not just the primary one
- **TanStack query cache not invalidated** — after a mutation (save, delete, update), the TanStack query cache for the affected entity must be invalidated via `queryClient.invalidateQueries`. Without this, reopening a modal/drawer shows pre-mutation data with now-deleted IDs, causing 404 errors on subsequent actions. Check `onSuccess` callbacks for cache invalidation alongside Inertia prop updates
- **Filter binding disconnects** — a filter checkbox or input may update the URL (via `useStringRouteQuery` or manual `router.push`) but not be wired into the Inertia `filterQuery` computed that actually triggers the data reload. The checkbox toggles visually and the URL updates, but the table never re-fetches. Verify both the URL binding AND the Inertia reload trigger
- **Cross-view state consistency** — if a feature appears in multiple views (e.g., action menu on both loadboard and detail page), verify the behavior is consistent across all views. Common miss: action menu works on detail page but breaks on list page because the list page uses a different resource/serializer with fewer eager-loaded relations

### Date & Timezone Safety
- **Hardcoded timezones** — `America/New_York` or `UTC` instead of `config('app.default_time_zone')` or the user's configured timezone
- **UTC date casts in migrations** — `::date` on a UTC timestamp produces the wrong calendar date for US users with evening activity
- **Display format consistency** — mixing `YYYY-MM-DD` and `MM/DD/YYYY` formats; use the project's `toDisplayDate()` helper
- **Mutable Carbon** — `$date->addDays(30)` mutates `$date`; if `$date` is reused (e.g., to set both `finalized_at` and `due_at`), both fields get the same wrong value

### Data Integrity & Migration Safety
- **`updateOrCreate()` in migrations** — overwrites existing user data on re-run; use `firstOrCreate()` for data that should not be clobbered
- **`chunk()` with self-invalidating filters** — if the chunk callback modifies the column being filtered (e.g., setting a flag that removes it from the query), records are skipped. Use `chunkById()` or cursor-based iteration
- **Dropping/changing constraints without replacement** — removing a primary key or unique constraint without adding a new one; `UNIQUE` on nullable columns is ineffective in PostgreSQL (NULLs are treated as distinct)
- **Non-idempotent backfill commands** — re-running creates duplicate records; add `firstOrCreate` guards or `WHERE NOT EXISTS` checks
- **`->change()` migrations silently dropping FK constraints** — Doctrine DBAL's `change()` does not preserve foreign key constraints unless explicitly re-declared with `->constrained()`
- **INNER JOIN on nullable FK** — silently drops rows where the FK is NULL; if those rows should appear in results, use LEFT JOIN

### Project Conventions
Check that changes follow project-specific patterns:

- **Design tokens** — use `iel-*` design token classes, not raw Tailwind palette colors (`bg-gray-50` → `bg-iel-lightest-gray`)
- **Component reuse** — use `AppButton` not raw `<button>`, `Badge` from shadcn/ui not custom `<div>` badges, `Confirm` composable not raw `Swal`, `Tooltip` from shadcn/ui not custom CSS hover tooltips
- **Enum constants** — use backed enum cases (`IntegrationType::EDI`) not raw strings (`'edi'`); don't use `->value` in Eloquent `where()` calls (Eloquent handles backed enums natively)
- **Closure return types** — all PHP arrow functions and closures must have explicit return type declarations (enforced by Rector's `ClosureReturnTypeRector`)
- **Case sensitivity** — role/permission name comparisons should be case-insensitive or use `whereIn` with all known casings; the `admin` role is `'admin'` in local and `'Admin'` in production
- **`whenLoaded()` guards** — relationship data in API resources must use `$this->whenLoaded('relation')`, not direct `$this->relation` access, to avoid N+1 queries on endpoints that don't eager-load the relation

## Step 3: Report findings

For each issue found, report:
1. **File and line number** (file_path:line_number format)
2. **Severity**: critical / warning / nit
3. **Category**: correctness / performance / memory / security / reliability / soft-delete / i18n / test-quality / refactoring / reactivity / date-timezone / data-integrity / convention
4. **What's wrong** — concise explanation
5. **Fix** — concrete suggestion or code snippet

If no issues are found, say so — but be skeptical. There is almost always something.

## Step 4: Offer to fix

After reporting, ask if the user wants you to fix any or all of the issues found.
