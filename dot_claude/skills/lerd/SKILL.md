---
name: lerd
description: Manage the lerd local PHP development environment — run framework console commands (artisan, bin/console, etc.), manage services, start/stop queue workers, run composer, manage Node.js versions, and inspect site status via MCP tools.
---
# Lerd — Laravel Local Dev Environment

This project runs on **lerd**, a Podman-based Laravel development environment for Linux (similar to Laravel Herd). The `lerd` MCP server exposes tools to manage it directly from your AI assistant.

## Path resolution

Tools that accept a `path` argument (`artisan`, `composer`, `env_setup`, `env_check`, `db_set`, `site_link`, `site_unlink`, `site_domain`, `db_export`, `db_import`, `db_create`, etc.) resolve it in this order:
1. Explicit `path` argument
2. `LERD_SITE_PATH` env var (set when using project-scoped `mcp:inject`)
3. **Current working directory** — the directory Claude was opened in

In practice, you can almost always omit `path` — just open Claude in the project directory.

## Architecture

- PHP runs inside Podman containers named `lerd-php<version>-fpm` (e.g. `lerd-php84-fpm`)
- Each PHP-FPM container includes **composer** and **node/npm** so you can run all tooling without leaving the container
- Nginx routes `*.test` domains to the appropriate FPM container
- Services (MySQL, Redis, PostgreSQL, etc.) run as Podman containers via systemd quadlets
- Custom services (MongoDB, RabbitMQ, …) can be added with `service_add` and managed identically to built-in ones
- Node.js versions are managed by **fnm** (Fast Node Manager); pin per-project with a `.node-version` file
- Framework workers (queue, schedule, reverb, messenger, vite, etc.) run as systemd user services named `lerd-<worker>-<sitename>` (e.g. `lerd-queue-myapp`, `lerd-messenger-myapp`). Workers with `per_worktree: true` get an extra `-<branch>` suffix when started on a worktree (e.g. `lerd-vite-myapp-feat-x`) so each branch runs its own instance with its own auto-incremented ports
- Worker commands are defined per-framework in YAML definitions; Laravel ships with queue/schedule/reverb/horizon and a `vite` host worker (runs `npm run dev` on the host via fnm for HMR); custom frameworks can add any workers; workers and setup commands support an optional `check` field (`file` or `composer`) to conditionally show them based on project dependencies. Per-worker flags: `host: true` runs on the host via fnm instead of inside FPM (used for HMR-sensitive Node tools); `per_worktree: true` lets the worker run independently per worktree; `replaces_build: true` declares the worker provides the asset manifest, so `lerd worktree add` skips the static `npm run build` step when this worker is opted into
- Framework definitions can include `setup` commands (one-off bootstrap steps like migrations, storage links) shown in `lerd setup`; Laravel has built-in storage:link/migrate/db:seed
- **Custom containers**: non-PHP sites (Node.js, Python, Go, etc.) can define a `Containerfile.lerd` and a `container:` section in `.lerd.yaml` with a port. Lerd builds a per-project image (`lerd-custom-<sitename>:local`), runs it as `lerd-custom-<sitename>`, and nginx reverse-proxies to it. Workers exec into the custom container. Services are accessible by name (`lerd-mysql`, `lerd-redis`, etc.) on the shared `lerd` Podman network.
- Git worktrees automatically get a `<branch>.<site>.test` subdomain (with deep `*.<branch>.<site>.test` wildcard cert + nginx `server_name` on secured sites); `vendor/`, `node_modules/`, and `.env` are populated from the main checkout. `.lerd.yaml` `env_overrides` declares templated env vars (placeholders `{{domain}}`, `{{scheme}}`, `{{site}}`, plus plain strings) layered on top of the default `APP_URL` rewrite — useful for multi-tenant apps with per-branch session cookies, signed-URL hosts, or tenant routing
- DNS resolves `*.test` to `127.0.0.1` via the lerd-dns dnsmasq container

## DNS modes

Lerd supports two DNS modes set at install time and recorded in `~/.config/lerd/config.yaml` under the `dns` key:

- **Managed (default)**: `dns.enabled: true`, `dns.tld: test`. The lerd-dns container runs, mkcert installs a trusted CA, sites use `*.test` and HTTPS via `site_tls` is available.
- **Disabled**: `dns.enabled: false`, `dns.tld: localhost`. No dnsmasq, no mkcert CA, no system resolver tweak. Sites use `*.localhost` (RFC 6761 hardwired to `127.0.0.1`). HTTPS is unavailable, `site_tls` returns an error.

Always read `status()` before assuming a TLD. The response carries `dns.tld` (the active TLD) and `dns.enabled` (false in disabled mode). Construct site URLs from `dns.tld` rather than hardcoding `.test`, and skip suggesting `site_tls` when `dns.enabled` is false.

## Available MCP Tools

### `sites`
List all registered lerd sites with domains, paths, PHP versions, Node versions, and queue status. **Call this first** to find site names and paths needed by other tools.

### `runtime_versions`
List all installed PHP and Node.js versions and the configured defaults. Call this to check what runtimes are available before running commands.

### `php_list`
List all PHP versions installed by lerd as JSON, with each version's `default` flag. Use this to confirm which versions are available before calling `site_php`, `php_ext`, or `xdebug`.

### `php_ext`
Manage custom PHP extensions for a PHP version. Extensions are added on top of the bundled lerd FPM image. Adding or removing an extension rebuilds the image and restarts the FPM container (may take a minute).

`add` verifies the extension loaded (`php -m`); a failed PECL build is reported as an error and the config entry removed. Pass `apk_deps` for extensions that need extra Alpine build packages (lerd already knows `imap`'s).

Arguments:
- `action` (required): `"list"`, `"add"`, or `"remove"`
- `version` (optional): defaults to the project or global PHP version
- `extension` (required for `add` and `remove`)
- `apk_deps` (optional, `add` only): space-separated extra Alpine packages

Examples:
```
php_ext(action: "list")
php_ext(action: "add", extension: "imagick")
php_ext(action: "add", extension: "redis", version: "8.3")
php_ext(action: "add", extension: "ssh2", apk_deps: "libssh2-dev")
php_ext(action: "remove", extension: "imagick")
```

### `artisan` (Laravel only)
Run `php artisan` inside the PHP-FPM container for the project. Only available when the site is detected as Laravel. Arguments:
- `path` (optional): absolute path to the Laravel project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)
- `args` (required): artisan arguments as an array

Examples:
```
artisan(args: ["migrate"])
artisan(args: ["make:model", "Post", "-m"])
artisan(args: ["db:seed", "--class=UserSeeder"])
artisan(args: ["cache:clear"])
artisan(args: ["tinker", "--execute=echo App\\Models\\User::count();"])
```

> **Note:** `tinker` requires `--execute=<code>` for non-interactive use.

### `console` (non-Laravel frameworks)
Run the framework's console command (e.g. `php bin/console` for Symfony) inside the PHP-FPM container. Only available for non-Laravel frameworks that define a `console` field in their YAML definition. Arguments:
- `path` (optional): absolute path to the project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)
- `args` (required): console arguments as an array

Example — Symfony:
```
console(args: ["cache:clear"])
console(args: ["doctrine:migrations:migrate"])
console(args: ["messenger:consume", "async", "--time-limit=60"])
```

### `composer`
Run `composer` inside the PHP-FPM container for the project. Arguments:
- `path` (optional): absolute path to the Laravel project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)
- `args` (required): composer arguments as an array

Examples:
```
composer(args: ["install"])
composer(args: ["require", "laravel/sanctum"])
composer(args: ["dump-autoload"])
composer(args: ["update", "laravel/framework"])
```

### `vendor_bins` / `vendor_run`
Discover and execute composer-installed binaries from the project's `vendor/bin` directory inside the PHP-FPM container. Use `vendor_bins` first to see what tooling is available (pest, phpunit, pint, phpstan, rector, paratest, psalm, etc.), then `vendor_run` to invoke one. Both accept an optional `path` argument that defaults to the current site.

Arguments:
- `vendor_bins(path?)` — returns the sorted list of executables in `vendor/bin`
- `vendor_run(path?, bin, args?)` — runs `php vendor/bin/<bin> [args]` inside the FPM container; `bin` must be a plain filename, not a path

Examples:
```
vendor_bins()                                      // list available tools
vendor_run(bin: "pest")                            // run the full pest suite
vendor_run(bin: "pest", args: ["--filter", "UserTest"])
vendor_run(bin: "phpunit", args: ["--testsuite", "Feature"])
vendor_run(bin: "pint", args: ["--test"])          // dry-run pint
vendor_run(bin: "phpstan", args: ["analyse", "--memory-limit=2G"])
vendor_run(bin: "rector", args: ["process", "--dry-run"])
```

Prefer `vendor_run` over `composer(args: ["exec", ...])` — it's faster, doesn't go through composer's plugin pipeline, and the same shortcut is available on the CLI as `lerd <bin>` (e.g. `lerd pest`, `lerd pint`).

### `node`
Install or uninstall a Node.js version via fnm. Accepts a version number or alias.

Arguments:
- `action` (required): `"install"` or `"uninstall"`
- `version` (required)

```
node(action: "install", version: "20")
node(action: "install", version: "20.11.0")
node(action: "install", version: "lts")
node(action: "uninstall", version: "18.20.0")
```

After installing a version you can pin it to a project by writing a `.node-version` file in the project root (or run `lerd isolate:node <version>` from a terminal).

### `service_control`
Start, stop, pin, or unpin any service — built-in or custom.

Arguments:
- `action` (required): `"start"`, `"stop"`, `"pin"`, or `"unpin"`
- `name` (required): service name

`service_control(action: "stop", ...)` marks the service as **paused** — `lerd start` and autostart on login will skip it until you explicitly start it again.

`service_control(action: "pin", ...)` marks a service so it is **never auto-stopped**, even when no active sites reference it in their `.env`. Starts the service if it isn't already running. Use this for services you want always available regardless of which site is active (e.g. a shared Redis or MySQL). `service_control(action: "unpin", ...)` removes the pin so the service can be auto-stopped when no sites use it.

**Dependency cascade:** if a custom service has `depends_on` set, starting its dependency also starts it; stopping the dependency stops it first. Starting the custom service directly ensures its dependencies start first.

Built-in names: `mysql`, `redis`, `postgres`, `meilisearch`, `rustfs`, `mailpit`. Custom service names (registered with `service_add`) are also accepted — just pass the same name used in `service_add`.

**.env values for built-in lerd services:**

| Service | Host | Key vars |
|---------|------|----------|
| mysql | `lerd-mysql` | `DB_CONNECTION=mysql`, `DB_PASSWORD=lerd` |
| postgres | `lerd-postgres` | `DB_CONNECTION=pgsql`, `DB_PASSWORD=lerd` |
| redis | `lerd-redis` | `REDIS_PASSWORD=null` |
| mailpit | `lerd-mailpit:1025` | web UI: http://localhost:8025 |
| meilisearch | `lerd-meilisearch:7700` | |
| rustfs | `lerd-rustfs:9000` | `AWS_USE_PATH_STYLE_ENDPOINT=true` |

### `service_expose`
Add or remove an extra published port on a built-in service. The mapping is persisted in `~/.config/lerd/config.yaml` and applied on every start. The service is restarted automatically if running.

Arguments:
- `name` (required): built-in service name (`mysql`, `redis`, `postgres`, `meilisearch`, `rustfs`, `mailpit`)
- `port` (required): mapping as `"host:container"`, e.g. `"13306:3306"`
- `remove` (optional): set to `true` to remove the mapping instead of adding it

Examples:
```
service_expose(name: "mysql", port: "13306:3306")
service_expose(name: "mysql", port: "13306:3306", remove: true)
```

### `service_add` / `service_remove`
Register or remove a custom OCI-based service. Arguments for `service_add`:
- `name` (required): slug, e.g. `"mongodb"`
- `image` (required): OCI image, e.g. `"docker.io/library/mongo:7"`
- `ports` (optional): array of `"host:container"` mappings
- `environment` (optional): array of `"KEY=VALUE"` strings for the container
- `env_vars` (optional): array of `"KEY=VALUE"` strings shown in `lerd env` suggestions
- `data_dir` (optional): mount path inside container for persistent data
- `description` (optional): human-readable description
- `dashboard` (optional): URL for the service's web UI
- `depends_on` (optional): array of service names that must be running before this service starts, e.g. `["mysql"]`

When `depends_on` is set:
- Starting this service automatically starts its dependencies first
- Starting a dependency automatically starts this service afterwards
- Stopping a dependency automatically stops this service first (cascade stop)

Example — add MongoDB:
```
service_add(
  name: "mongodb",
  image: "docker.io/library/mongo:7",
  ports: ["27017:27017"],
  data_dir: "/data/db",
  env_vars: ["MONGODB_URL=mongodb://lerd-mongodb:27017"]
)
service_control(action: "start", name: "mongodb")
```

Example — add phpMyAdmin depending on MySQL:
```
service_add(
  name: "phpmyadmin",
  image: "docker.io/phpmyadmin:latest",
  ports: ["8080:80"],
  depends_on: ["mysql"],
  dashboard: "http://localhost:8080"
)
service_control(action: "start", name: "phpmyadmin")   // starts mysql first, then phpmyadmin
```

`service_remove` stops and deregisters a custom service. Persistent data is NOT deleted.

### `service_preset_list` / `service_preset_install`
Lerd ships a small catalogue of opt-in **service presets** — bundled YAML definitions for common dev services that become normal custom services once installed. Use `service_preset_list` to see what's available and `service_preset_install` to install one. Prefer this over hand-rolling `service_add` for anything in the catalogue: presets ship sane defaults, dependency wiring, dashboard URLs, and (where relevant) rendered config files.

Current catalogue: `phpmyadmin` (depends on built-in mysql), `pgadmin` (depends on built-in postgres, ships a pre-loaded servers.json + pgpass), `mongo`, `mongo-express` (depends on the `mongo` preset), `selenium` (Chromium for browser testing — Dusk, Panther, etc.), `stripe-mock`. Some presets (e.g. `mysql`, `mariadb`) declare multiple versions in a single family — pass `version` to pick one, otherwise lerd installs the family default.

Arguments:
- `service_preset_list()` — returns each preset with its image, declared versions, dependencies, dashboard URL, and an `installed` flag
- `service_preset_install(name, version?)` — installs a preset by name; `version` is required only for multi-version families when you want a specific tag

Examples:
```
service_preset_list()
service_preset_install(name: "phpmyadmin")           // adds phpmyadmin, mysql is built-in
service_preset_install(name: "mongo")                // install mongo first…
service_preset_install(name: "mongo-express")        // …then mongo-express (gated otherwise)
service_preset_install(name: "mysql", version: "8.4")
service_control(action: "start", name: "phpmyadmin") // mysql is started automatically
```

**Dependency gating:** installing a preset whose dependency is another *custom* service (e.g. `mongo-express` on `mongo`) is rejected with a clear error until the dependency is installed first. Built-in deps (mysql, postgres) are auto-satisfied.

Once installed, presets are normal custom services — manage them with `service_control`, `service_remove`, and `service_expose`.

### `service_env`
Return the recommended Laravel `.env` connection variables for a service — built-in or custom — as a key/value map. Use this when you need to inspect or manually apply connection settings without running `env_setup`.

### `env_setup`
Configure the project's `.env` for lerd in one call:
- Creates `.env` from `.env.example` if it doesn't exist
- Detects which services (MySQL, Redis, …) the project uses and sets lerd connection values
- Starts any referenced services that aren't running
- Creates the project database (and `<name>_testing` database)
- Generates `APP_KEY` if missing
- Sets `APP_URL` (or the framework's URL key) using the precedence chain: `.lerd.yaml` `app_url` → `sites.yaml` `app_url` → default `<scheme>://<primary-domain>` — see "Custom APP_URL" below

Arguments:
- `path` (optional): absolute path to the Laravel project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)

> Run this right after `site_link` when setting up a fresh project.
>
> **Database default:** on a fresh Laravel clone where `.env` still says `DB_CONNECTION=sqlite`, `env_setup` leaves the database choice alone. Call `db_set` first to pick `sqlite`, a built-in (`mysql` / `postgres`), or an installed family alternate (`mariadb`, `postgres-pgvector`, …) deliberately, then `env_setup` (or just `db_set` alone — it already runs the env step).

### `db_set`
Pick the database for a Laravel project. Persists the choice to `.lerd.yaml` (replacing any prior DB entry), rewrites `DB_` keys in `.env`, and provisions storage. Accepts `sqlite`, the built-in `mysql` / `postgres`, or any installed family alternate (`mariadb`, `mysql-5-7`, `postgres-pgvector`, `postgres-17`, …). Alternates must be installed first with `lerd service preset <name>`.

Arguments:
- `path` (optional): project root, defaults to `LERD_SITE_PATH` / cwd
- `database` (required): see above

Examples:
```
db_set(database: "mysql")
db_set(database: "postgres-pgvector")
db_set(database: "sqlite")
```

> Use this **before** `env_setup` on a fresh Laravel project so the database lands in `.env` deliberately. Switching databases later via `db_set` removes the previous database entry from `.lerd.yaml` automatically.

### `db_snapshot` / `db_snapshots` / `db_restore` / `db_snapshot_delete`
Named, restorable point-in-time copies of the project database — take one before a risky migration or a destructive experiment, then roll back in a single call. SQL engines only (MySQL, MariaDB, PostgreSQL); snapshots are stored under lerd's data dir, keyed by service and database.

- `db_snapshot` — create a snapshot. `name` is optional (auto-timestamped); `all_databases` snapshots every database in the service.
- `db_snapshots` — list snapshots as JSON. `all` spans every database on the service.
- `db_restore` — restore a snapshot by `name`. Destructive: a per-database restore drops and recreates the database.
- `db_snapshot_delete` — delete a stored snapshot.

All four resolve the database from the project `.env`; pass `service` and `database` to override.

Example:
```
db_snapshot(name: "pre-migration")
db_restore(name: "pre-migration")
```

### Custom `APP_URL`
By default `env_setup` writes `APP_URL=<scheme>://<primary-domain>` (e.g. `http://myapp.test`) on every run. Three-tier override chain when you need a different value:

1. `.lerd.yaml` `app_url` field — committed to the repo, applies to every machine. Use for path prefixes, ports, or unrelated hostnames the whole team should share.
2. `~/.local/share/lerd/sites.yaml` `app_url` field on the site entry — per-machine override, not committed.
3. The default `<scheme>://<primary-domain>` generator — used when neither override is set.

There is no MCP tool to set `app_url` programmatically; the user (or you) edit `.lerd.yaml` directly and re-run `env_setup` (or any command that runs `lerd env` internally) to apply it.

Example `.lerd.yaml`:
```yaml
domains:
  - myapp
app_url: http://myapp.test/api
```

If the configured `app_url` happens to point at a domain that the conflict filter dropped, lerd silently falls through to the next precedence level so `.env` doesn't end up writing a hostname owned by another site.

### `env_check`
Compare all `.env` files (`.env`, `.env.testing`, `.env.local`, …) against `.env.example` and return structured JSON with missing or extra keys. Useful for catching "works on my machine" bugs caused by env drift after pulling new code.

Returns: `{"in_sync": bool, "keys": [{key, in_example, files: {filename: bool}}], "out_of_sync_count": N}`

Arguments:
- `path` (optional): absolute path to the project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)

### `site_link` / `site_unlink`
Register or unregister a directory as a lerd site. Arguments for `site_link`:
- `path` (optional): absolute path to the project directory — defaults to `LERD_SITE_PATH` set by `mcp:inject`
- `name` (optional): domain name without TLD (e.g. `"myapp"` becomes `myapp.test`; defaults to directory name, cleaned up)

> **Non-PHP projects (Node.js, Python, Go, etc.):** a Containerfile and `.lerd.yaml` with a `container: {port: <N>}` section must exist **before** calling `site_link`. The Containerfile can be named anything (`Containerfile.lerd` is the default; set `container.containerfile` to point at a different name like `Dockerfile`). Write `.lerd.yaml` directly (there is no MCP tool for this — see the custom container setup workflow in the Workflows section below), or ask the user to run `lerd init` which runs an interactive wizard and writes the file. Calling `site_link` without this config registers the site as a PHP-FPM site, which is wrong. If that happened, call `site_unlink` first, set up the files, then `site_link` again.

`site_unlink` takes `path` (optional, same resolution as `site_link`). Removes the site and all its domains. Project files are NOT deleted.

### `site_domain`
Add or remove additional domains for a site. Each site can have multiple domains (all served by the same nginx vhost).
- `action` (required): `"add"` or `"remove"`
- `path` (optional): project directory
- `domain` (required): domain name without TLD (e.g. `"api"` becomes `api.test`)

Cannot remove the last domain. When a site is secured, the TLS certificate is automatically reissued to cover all domains.

### `park` / `unpark`
`park` registers a parent directory: it scans every immediate subdirectory and auto-registers any PHP projects found as lerd sites. Use this when you keep many projects under one folder.

`unpark` removes the registration and unlinks all sites whose paths are under that directory. Project files are NOT deleted.

Both take `path` (optional, defaults to LERD_SITE_PATH or cwd).

### `site_tls`
Enable or disable HTTPS for a site using a locally-trusted mkcert certificate. `APP_URL` in `.env` is updated automatically.

Arguments:
- `action` (required): `"enable"` or `"disable"`
- `site` (required): site name

### `xdebug`
Toggle Xdebug for a PHP version (restarts the FPM container) or report its state. Xdebug listens on port `9003` at `host.containers.internal`.

Arguments:
- `action` (required): `"on"`, `"off"`, or `"status"`
- `version` (optional): defaults to the project or global PHP version
- `mode` (optional, only for `on`): default `debug`. Valid values: `debug`, `coverage`, `develop`, `profile`, `trace`, `gcstats`, or a comma-separated combo such as `debug,coverage`

Use `coverage` for `phpunit --coverage` / `pest --coverage` when PCOV isn't available or is disabled. Calling `xdebug(action: "on", ...)` with a different mode on an already-enabled version swaps modes without needing `action: "off"` first.

`xdebug(action: "status")` returns the enabled/disabled state and the active `mode` for all installed PHP versions.

### `dumps_recent` / `dumps_status` / `dumps_clear` / `dumps_toggle`
Capture and inspect `dump()` / `dd()` output via the lerd dump bridge. Off by default — enable globally with `dumps_toggle(enable: true)`, then call `dumps_recent` to read what your last request produced.

- `dumps_recent({ site?, ctx?, since?, limit? })` returns the buffered events as JSON (most-recent at the tail). Use `site` to scope to one site (matches `ctx.site`), `ctx` (`"fpm"` or `"cli"`) to filter by source, `since` (event id) to skip events you've already seen, and `limit` to cap the result.
- `dumps_status()` reports whether the bridge is enabled, whether the receiver is listening, the listener address, the buffered event count, and the timestamp of the most recent event.
- `dumps_clear()` wipes the in-memory ring without disabling the bridge — handy before triggering a focused repro.
- `dumps_toggle({ enable: true | false })` flips the global on/off via a sentinel file inside the always-mounted bridge directory. `enable: true` touches the sentinel, `enable: false` removes it. No FPM container is restarted by either path.

Events ship as JSON with `ts` (RFC3339Nano), `ctx` (type, site, request, pid), `src` (file:line of the dump call), `label` (the keyword arg name when present), and `text` (Symfony VarDumper's CliDumper output). Capacity is 500 events; older entries roll off.

### `profiler_toggle` / `profiler_status` / `profiler_clear`
Turn the SPX profiler on or off globally. While on, every HTTP request to every PHP-FPM site is profiled into a flame graph.

- `profiler_toggle({ enable })` turns profiling on (`enable: true`) or off. It rewrites every FPM site's nginx vhost to inject an SPX cookie and reloads nginx, with no FPM restart.
- `profiler_status()` reports whether profiling is on and the SPX web UI URL where the flame graphs are viewable.
- `profiler_clear()` deletes every captured SPX report and returns how many were removed.

After turning it on, reload a site in the browser, then open the dashboard Profiler view or the SPX web UI to read the flame graphs.

### `queue`
Start or stop a queue worker for a site. Available for any framework that defines a `queue` worker (Laravel has it built-in). Runs the framework-defined command in the FPM container as a systemd service.

> **Redis queues:** if the project's `.env` has `QUEUE_CONNECTION=redis`, lerd will refuse to start the worker unless `lerd-redis` is running. Call `service_control(action: "start", name: "redis")` first.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool
- `queue` (optional, `start` only): queue name, default `"default"`
- `tries` (optional, `start` only): max job attempts, default `3`
- `timeout` (optional, `start` only): job timeout in seconds, default `60`

### `horizon`
Start or stop Laravel Horizon for a site. Horizon is a queue manager that replaces `queue:work` — use `horizon` instead of `queue` for projects that have `laravel/horizon` in `composer.json`. Returns an error on `action: "start"` if `laravel/horizon` is not installed.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool

> **Horizon vs queue worker:** The `sites` tool returns `has_horizon: true` when a site has Horizon installed. In that case prefer `horizon` over `queue`.

### `reverb`
Start or stop the Reverb WebSocket server for a site. Available for any framework that defines a `reverb` worker.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool

### `schedule`
Start or stop the task scheduler for a site. Available for any framework that defines a `schedule` worker.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool

### `worker`
Start or stop any named framework worker for a site. Use this for workers that don't have a dedicated shortcut (e.g. `messenger` for Symfony, `pulse` for Laravel, `vite` for Laravel HMR). The worker command is taken from the framework definition.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool
- `worker` (required): worker name as defined in the framework (e.g. `"messenger"`, `"horizon"`, `"vite"`)
- `branch` (optional): worktree branch name. Required to start a `per_worktree: true` worker on a specific worktree (targets `lerd-<worker>-<site>-<branch>`). Without `branch`, the parent-site unit is targeted (`lerd-<worker>-<site>`)

Examples:
```
worker(action: "start", site: "myapp", worker: "vite")                       // parent site Vite
worker(action: "start", site: "myapp", worker: "vite", branch: "feat-x")     // per-worktree Vite
worker(action: "stop",  site: "myapp", worker: "vite", branch: "feat-x")     // stop just the worktree's instance
```

### `worker_list`
List all workers defined for a site's framework, with their running status, command, unit name, restart policy, and per-worker flags (`host`, `per_worktree`, `replaces_build`). Use this to discover available workers before calling `worker`.

Arguments:
- `site` (required): site name from `sites` tool
- `branch` (optional): worktree branch name. With `branch`, status is reported for `lerd-<worker>-<site>-<branch>` units instead of the parent-site units

### `commands_list` / `commands_run` / `command_add` / `command_remove`
One-shot framework commands (`optimize:clear`, `migrate`, `drush uli`, `cache:flush`, etc). Set = framework yaml + project `.lerd.yaml` `commands:`. Prefer over invoking `php artisan` / `drush` / `wp` directly because per-project overrides are honored. `command_add` writes to `.lerd.yaml`; use `disabled: true` to suppress a framework default without replacement.

Arguments:
- `site` (required): site name
- `name` (commands_run / command_add / command_remove): name from `commands_list` or a new identifier
- `command` (command_add): shell command (required unless `disabled: true`)
- `label`, `description`, `icon` (command_add, optional)
- `output` (command_add): `silent | text | url | terminal` (default silent)
- `confirm` (command_add): gate behind a safety modal
- `check_file` / `check_composer` (command_add): hide unless the rule passes
- `disabled` (command_add): suppress a framework default of the same name
- `force` (commands_run): required for confirm-gated commands

### `worker_add`
Add or update a custom worker for a project. Saves to `.lerd.yaml` `custom_workers` by default, or to the global framework overlay (`~/.config/lerd/frameworks/`) with `global: true`. Does not auto-start — use `worker(action: "start", ...)` afterwards.

Arguments:
- `site` (required): site name from `sites` tool
- `name` (required): worker name (slug, e.g. `"pdf-generator"`)
- `command` (required): command to run inside the PHP-FPM container
- `label`: human-readable label
- `restart`: `"always"` or `"on-failure"` (default: always)
- `check_file`: only show worker when this file exists
- `check_composer`: only show worker when this Composer package is installed
- `conflicts_with`: array of workers to stop before starting this one
- `global`: save to global framework overlay instead of `.lerd.yaml`

### `worker_remove`
Remove a custom worker from a project's `.lerd.yaml` or global framework overlay. Stops the worker if running.

Arguments:
- `site` (required): site name from `sites` tool
- `name` (required): worker name to remove
- `global`: remove from global framework overlay instead of `.lerd.yaml`

### `worktree`
Manage git worktrees for a site. Watcher auto-installs deps on add and presents a unified asset-worker / npm-build prompt (workers with `replaces_build` + `per_worktree` appear alongside npm scripts; picked workers start ad-hoc with `persist=false`, leaving `.lerd.yaml workers:` as the source of truth). Worktrees on secured sites get `*.<branch>.<site>.test` wildcard cert SANs and nginx `server_name` automatically.

Arguments:
- `action` (required): `"list"` / `"add"` / `"remove"` / `"db_isolate"` / `"db_share"`
- `site` (optional): defaults to the site at cwd (or its parent for worktree paths)
- `branch` (required for add / remove / db_isolate): branch name
- `git_args` (array, optional): forwarded to `git worktree`; use this to pass `-b new-branch` etc.
- `force` (optional, remove): `--force` flag for `git worktree remove`
- `keep_db` (optional, remove): preserve isolated DB on removal (default `true`)
- `source` (optional, db_isolate): seed for the isolated DB (`empty` / `main` / `<branch>`)

To toggle a per-worktree worker (e.g. Vite on branch `feat-x`), call `worker(action: "start", site: "myapp", worker: "vite", branch: "feat-x")`; this targets `lerd-vite-myapp-feat-x` rather than the parent unit.

Multi-tenant `.env` per worktree: declare `env_overrides` in `.lerd.yaml` with `{{domain}}` / `{{scheme}}` / `{{site}}` placeholders, e.g. `SESSION_DOMAIN: ".{{domain}}"` so cookies scope per branch.

### `project_new`
Scaffold a new PHP project using a framework's create command. For Laravel, runs `composer create-project --no-install --no-plugins --no-scripts laravel/laravel <path>`. Other frameworks must have a `create` field in their YAML definition.

Arguments:
- `path` (required): absolute path for the new project directory (e.g. `/home/user/code/myapp`)
- `framework` (optional): framework name (default: `"laravel"`)
- `args` (optional): extra arguments passed to the scaffold command

After creation, register and configure the project:
```
project_new(path: "/home/user/code/myapp")
site_link(path: "/home/user/code/myapp")
env_setup(path: "/home/user/code/myapp")
```

From the terminal you can also run:
```
lerd new myapp
cd myapp && lerd link && lerd setup
```

### `framework_list`
List all available framework definitions (Laravel built-in plus any user-defined YAMLs at `~/.config/lerd/frameworks/`), including their defined workers and setup commands. Call this before `framework_add` to see what already exists.

### `framework_add`
Create or update a framework definition. For `laravel`, only the `workers` and `setup` fields are accepted (built-in settings are always preserved). For other frameworks, creates a full definition.

Arguments:
- `name` (required): framework slug (e.g. `"symfony"`). Use `"laravel"` to add custom workers to the built-in Laravel definition (e.g. `horizon`, `pulse`)
- `label` (optional): display name, e.g. `"Symfony"`
- `public_dir` (optional): document root relative to project (default: `"public"`)
- `detect_files` (optional): array of filenames that signal this framework
- `detect_packages` (optional): array of Composer packages that signal this framework
- `env_file` (optional): primary env file path (default: `".env"`)
- `env_format` (optional): `"dotenv"` or `"php-const"`
- `workers` (optional): map of worker name → `{label, command, restart, check}` — `check` is optional (`{file}` or `{composer}`), worker only shown when check passes
- `setup` (optional): array of one-off setup commands shown in `lerd setup` wizard, each with `{label, command, default, check}` — `check` is optional, same format as workers

Example — add Horizon to Laravel:
```
framework_add(name: "laravel", workers: {
  "horizon": {"label": "Horizon", "command": "php artisan horizon", "restart": "always"}
})
```

Example — define a new framework:
```
framework_add(
  name: "wordpress",
  label: "WordPress",
  public_dir: ".",
  detect_files: ["wp-login.php"],
  workers: {
    "cron": {"label": "WP Cron", "command": "wp cron event run --due-now --allow-root", "restart": "always"}
  }
)
```

### `framework_remove`
Delete a user-defined framework YAML. For `laravel`, removes only custom worker and setup command additions (built-in queue/schedule/reverb workers and storage:link/migrate/db:seed setup remain). Takes `name` (required).

### `site_php` / `site_node`
Change the PHP or Node.js version for a registered site. Both take `site` (required), `version` (required), and an optional `branch` (worktree).

`site_php` writes a `.php-version` pin file to the project root, updates the site registry, and regenerates the nginx vhost. The FPM container for the target PHP version must be running — start it with `service_control(action: "start", name: "php<version>")` if needed.

`site_node` writes a `.node-version` pin file and installs the version via fnm if it isn't already installed. Run `npm install` inside the project if dependencies need rebuilding against the new version.

Pass `branch` to pin the version on a specific worktree instead of the parent site. The pin file is written inside the worktree's checkout, `php_version` / `node_version` is persisted to that worktree's `.lerd.yaml` (so the override travels with the branch in git), and only that worktree's nginx vhost is regenerated. The parent site's version stays unchanged.

### `workers_mode`
Show or set the macOS worker runtime mode.

Arguments:
- `action` (required): `"get"` or `"set"`
- `mode` (required for set): `"exec"` (default; one `podman exec` per worker, supervised by launchd, lower memory) or `"container"` (one detached container per worker, 1:1 supervisor boundary, higher memory)

Linux always uses exec under systemd — this setting is a no-op there. Setting on macOS stops each active worker in its old shape, cleans up the stale on-disk artifacts, and restarts it in the new shape.

### `bug_report`
Generate a plain-text diagnostic report for a GitHub issue. Collects `lerd doctor` output, config files, systemd / podman state, recent service logs and a curated set of environment variables.

Arguments:
- `output` (optional): file path. Defaults to `./lerd-bug-report-<timestamp>.txt`
- `log_lines` (optional): lines per service / container log. Default 200.
- `show_real_names` (optional): keep real site names, domains and parked-directory paths instead of replacing them with `site-1` / `$PARK_1` / etc. Use only for local debugging — anonymisation is on by default for issue posting.

Returns the file path so the user can attach it to the issue.

### `site_control`
Pause, unpause, restart, or rebuild a site.

Arguments:
- `action` (required): `"pause"`, `"unpause"`, `"restart"`, or `"rebuild"`
- `site` (required): site name from `sites` tool

- `pause`: stops all running workers for the site, stops the custom container (for custom container sites), and replaces its nginx vhost with a landing page that includes a **Resume** button. Services no longer needed by any active site are auto-stopped. The paused state is persisted.
- `unpause`: starts the custom container (if applicable), restores the nginx vhost, ensures required services are running, and restarts any workers that were running when the site was paused.
- `restart`: restarts the container for a site without rebuilding the image. For custom container sites this restarts the dedicated container; for PHP sites it restarts the shared FPM container.
- `rebuild`: rebuilds the custom container image from the Containerfile and restarts the container. Use after changing the Containerfile. `site_link` reuses the cached image; `rebuild` forces a fresh build. Only works for custom container sites.

Use `pause` / `unpause` to free up resources for sites you're not actively working on without fully unlinking them.

### `site_runtime`
Switch the PHP runtime for a site between the shared PHP-FPM container (`fpm`, default) and a per-site FrankenPHP container (`frankenphp`). Arguments:
- `site` (required): site name from `sites` tool
- `runtime` (required): `fpm` or `frankenphp`
- `worker` (optional, default false): when runtime=frankenphp, enable worker mode (keeps PHP resident for ~10-50x faster requests)

FrankenPHP is framework-aware: Laravel uses `octane:start --server=frankenphp --workers=auto` (needs pcntl, installed at container start); Symfony uses `frankenphp php-server --worker=public/index.php --watch` for live reload; unknown frameworks fall back to `frankenphp php-server` rooted at the framework's public dir. Switching to `fpm` removes the runtime fields from `.lerd.yaml` and regenerates the FPM vhost. Not supported on custom-container sites (their runtime comes from their Containerfile). Xdebug is not wired up for FrankenPHP; switch back to `fpm` to debug.

### `stripe`
Start or stop a Stripe webhook listener for a site using the Stripe CLI container. On `start` it reads `STRIPE_SECRET` from the site's `.env` and forwards webhooks to `/stripe/webhook` by default.

Arguments:
- `action` (required): `"start"` or `"stop"`
- `site` (required): site name from `sites` tool
- `api_key` (optional, `start` only): Stripe secret key (defaults to `STRIPE_SECRET` in the site's `.env`)
- `webhook_path` (optional, `start` only): webhook route path (default: `"/stripe/webhook"`)

### `db_export`
Export a database to a SQL dump file. Works with any project type — service and database are auto-detected. Arguments:
- `path` (optional): absolute path to the project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)
- `service` (optional): lerd service name to target (e.g. `mysql`, `postgres`) — overrides auto-detection
- `database` (optional): database name to export — overrides auto-detection
- `output` (optional): output file path (defaults to `<database>.sql` in the project root)

### `db_import`
Import a SQL dump file into the project database. Service and database are auto-detected; the service is started if not already running. Arguments:
- `file` (required): absolute path to the SQL file to import
- `path` (optional): absolute path to the project root — defaults to the current working directory
- `service` (optional): lerd service name to target — overrides auto-detection
- `database` (optional): database name to import into — overrides auto-detection

### `db_create`
Create a database and a `<name>_testing` variant for the project. Service and database name are auto-detected; the service is started if not already running. Arguments:
- `path` (optional): absolute path to the project root
- `service` (optional): lerd service name to target — overrides auto-detection
- `name` (optional): database name — overrides auto-detection

### `logs`
Fetch recent container logs. `target` is optional — when omitted, returns logs for the current site's PHP-FPM container (resolved from `LERD_SITE_PATH`). Specify `target` only when you want a different container:
- `"nginx"` — nginx proxy logs
- Service name: `"mysql"`, `"redis"`, or any custom service name
- PHP version: `"8.4"` — logs for that PHP-FPM container
- Site name — logs for a different site's PHP-FPM container

Optional `lines` parameter (default: 50).

### `status`
Return the health status of core lerd services as structured JSON: DNS resolution (ok + tld), nginx (running), PHP-FPM containers (running per version), and the file watcher (running). **Call this first when a site isn't loading** — it pinpoints which service is down before suggesting fixes.

### `which`
Show the resolved PHP version, Node version, document root, and nginx config path for the current site. Call this to confirm which runtime versions a project will use before running commands.

Arguments:
- `path` (optional): absolute path to the project root — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)

### `check`
Validate a project's `.lerd.yaml` file. Returns structured JSON with per-field status (ok/warn/fail). Checks PHP version format and installation, service definitions (built-in, custom, inline), framework references, and worker configuration.

Returns: `{"valid": bool, "errors": N, "warnings": N, "items": [{name, status, detail}]}`

Arguments:
- `path` (optional): absolute path to the project root containing `.lerd.yaml` — defaults to the current working directory (or `LERD_SITE_PATH` if set by `mcp:inject`)

> **Use this before** `env_setup` or `site_link` to catch configuration errors early.

### `doctor`
Run a full environment diagnostic. Returns structured JSON with per-check status (ok/warn/fail): podman, systemd, linger, dir writability, config validity, DNS resolution, nginx, PHP images, and update availability.

Returns: `{"version": "...", "checks": [{name, status, detail}], "failures": N, "warnings": N, "php_installed": [...], "php_default": "...", "node_default": "..."}`

**Use this when the user reports setup issues or unexpected behaviour.**

## Common Workflows

Single-tool tasks are covered by the tool definitions above (e.g. `site_tls` enables HTTPS, `doctor` runs a full diagnostic, `logs` tails FPM/nginx). These flows only cover multi-step compositions where ordering or non-obvious glue matters.

**Bootstrap a new project from scratch, end-to-end** — works for any lerd-known framework (laravel, symfony, etc.). **Run every step, in order. Do not stop until `setup` returns.**
```
project_new(path: "/abs/path/myapp", framework: "laravel")
// project_new scaffolds AND runs composer install — vendor/ is populated on return
site_link(path: "/abs/path/myapp")
env_setup(path: "/abs/path/myapp")    // .env, services, DB (sqlite auto-created), APP_KEY
setup(path: "/abs/path/myapp")        // framework Default:true steps — migrations, storage:link, etc.
// Optional:
site_tls(action: "enable", site: "myapp")   // HTTPS via mkcert
```

**Set up a cloned project, end-to-end** — framework-agnostic. **Run every step, in order.**
```
site_link()                           // registers cwd as a lerd site
composer(args: ["install"])           // BEFORE env_setup — APP_KEY generation needs vendor/
env_setup()                           // .env, services, DB (sqlite auto-created), APP_KEY
setup()                               // framework migrations + other Default:true setup steps
// Optional:
// vendor_run(bin: "pest")            // run tests to confirm everything works
```

**Debugging a 500 on a lerd site** (ordered, stop at the first signal):
```
logs()                                 // current site's FPM + recent errors
logs(target: "nginx")                  // if FPM logs are clean
env_check()                            // missing .env keys vs .env.example
which()                                // confirm PHP version, docroot, vhost
// If the error mentions vendor/, autoload, or class-not-found:
composer(args: ["install"])
// If the error mentions APP_KEY:
artisan(args: ["key:generate"])        // or framework's equivalent
// If the error mentions the database file / connection:
//   sqlite: env_setup() auto-creates database/database.sqlite
//   mysql/postgres: service_control(action: "start", name: "<service>")
setup()                                // re-runs pending migrations + setup steps
status()                               // DNS / nginx / FPM container health at a glance
doctor()                               // full diagnostic if nothing above explains it
```

**Install a package that needs publish + migration:**
```
composer(args: ["require", "spatie/laravel-permission"])
artisan(args: ["vendor:publish", "--provider=Spatie\\Permission\\PermissionServiceProvider"])
artisan(args: ["migrate"])
```

**Xdebug coverage for phpunit/pest (mode swap, no action: "off" needed between modes):**
```
xdebug(action: "on", version: "8.4", mode: "coverage")
vendor_run(name: "pest", args: ["--coverage"])
xdebug(action: "off", version: "8.4")
```

**Back up before a risky migration:**
```
db_export(output: "/tmp/myapp-backup.sql")
artisan(args: ["migrate"])
// on failure: db_import(file: "/tmp/myapp-backup.sql")
```

**Add a Laravel Horizon worker (custom framework worker):**
```
framework_add(name: "laravel", workers: {
  "horizon": {"label": "Horizon", "command": "php artisan horizon", "restart": "always"}
})
worker(action: "start", site: "myapp", worker: "horizon")
```

**Set up a custom container site (Node.js, Python, Go, etc.):**

1. Create a `Containerfile.lerd` in the project root (do NOT add WORKDIR or COPY — lerd volume-mounts the project directory at its host path and sets --workdir automatically):
```dockerfile
FROM node:20-alpine
RUN npm install -g nodemon
CMD ["npm", "run", "start:dev"]
```

   > **Hot-reload on macOS**: inotify events do not fire across Podman Machine's virtiofs mount. Use polling: nodemon needs `--legacy-watch`, Vite needs `server.watch.usePolling: true`, webpack needs `watchOptions: { poll: 1000 }`.

2. Write `.lerd.yaml` with the container section (no MCP tool for this — write the file directly or run `lerd init`):
```yaml
domains:
  - myapp
container:
  port: 3000
services:
  - mysql
  - redis
```

3. **Configure env BEFORE linking.** The container starts immediately on `site_link`. Lerd services are reachable by container name on the `lerd` network:
```
DB_HOST=lerd-mysql     # or lerd-postgres (port 5432)
DB_PORT=3306
DB_USERNAME=root       # postgres for postgres
DB_PASSWORD=lerd
REDIS_HOST=lerd-redis
REDIS_PORT=6379
```

4. Link:
```
site_link()            // builds image, creates container, generates nginx vhost
```

The `container.port` field is required. `container.containerfile` defaults to `Containerfile.lerd`. Workers defined in `custom_workers` exec into the custom container.

## .lerd.yaml Reference

`.lerd.yaml` is the per-project config file, committed to the repo. `lerd link` and `lerd init` apply it automatically.

### PHP site fields

| Field | Description |
|-------|-------------|
| `domains` | Site hostnames without TLD (e.g. `[myapp, api]`). First is primary. |
| `php_version` | PHP version for this project (e.g. `"8.4"`) |
| `node_version` | Node version (e.g. `"22"`) |
| `framework` | Framework name (e.g. `laravel`, `symfony`, `wordpress`) |
| `secured` | `true` to enable HTTPS |
| `request_timeout` | nginx request timeout in seconds (default 60). Raises `fastcgi_read/send_timeout` for FPM sites or `proxy_read/send_timeout` for proxy/container sites — for deliberately long-running requests. Overrides the global `nginx.request_timeout` |
| `services` | Services to start (e.g. `[mysql, redis]`) |
| `workers` | Active worker names (e.g. `[queue, schedule]`) — auto-synced by start/stop |
| `app_url` | Override for APP_URL in `.env` |
| `env_overrides` | Map of env var names → templated values written into per-worktree `.env` (not the parent's; not applied on `lerd setup`). Placeholders: `{{domain}}`/`{{scheme}}`/`{{site}}`/`{{branch}}`/`{{parent}}`, or plain strings. `APP_URL` here beats the default rewrite. `DB_DATABASE` is owned by isolation when on |

### Custom container fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `container.port` | yes | | Port the app listens on inside the container |
| `container.containerfile` | no | `Containerfile.lerd` | Path to the Containerfile (relative to project root) |
| `container.build_context` | no | `.` | Build context directory |
| `container.target` | no | (last stage) | Stage to build in a multi-stage Containerfile, passed as `podman build --target` |
| `custom_workers` | no | | Worker definitions — see below |
| `domains` | no | | Same as PHP sites |
| `secured` | no | | Same as PHP sites |
| `request_timeout` | no | 60 | Same as PHP sites — sets `proxy_read/send_timeout` for the container |
| `services` | no | | Same as PHP sites |

When `container` is present, `php_version`, `framework`, and `node_version` are ignored — the container defines its own runtime.

### custom_workers fields

Each entry under `custom_workers` is a name-to-config map. Works for both PHP and custom container sites.

```yaml
custom_workers:
  queue:
    label: Queue Worker
    command: node dist/queue.js
    restart: always
  cron:
    label: Cron
    command: node dist/cron.js
    restart: on-failure
```

| Field | Required | Description |
|-------|----------|-------------|
| `label` | no | Display name in the UI |
| `command` | yes | Shell command to run inside the container |
| `restart` | no | `always` (default) or `on-failure` |
| `schedule` | no | systemd OnCalendar expression for cron-style workers (e.g. `minutely`) |
| `conflicts_with` | no | List of worker names to stop before starting this one |
| `host` | no | `true` runs on the host via fnm instead of in the FPM container. For Node tools that need direct filesystem access for HMR (Vite, Tailwind watcher, etc.) |
| `per_worktree` | no | `true` lets the worker run independently per git worktree under `lerd-<wname>-<site>-<wt>`. Required for worktree auto-start |
| `replaces_build` | no | `true` declares that, while running, the worker provides the asset manifest. `lerd worktree add` skips the static `npm run build` step when this worker is opted into |
