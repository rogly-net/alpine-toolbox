# Alpine Toolbox

A lightweight Docker container based on Alpine Linux with customizable user permissions, cron job support, and timezone configuration. Perfect for Kubernetes initContainers, backup tasks, and general-purpose automation.

## 📋 Features

- 🐧 **Alpine Linux** - Minimal, secure base image (includes `bash`, `dcron`, `su-exec`, `tzdata`)
- 👤 **Custom User/Group** - Set UID/GID via `PUID`/`PGID` environment variables (supports UID/GID `0`)
- ⏰ **Smart Cron Support** - Automatic cron job setup from mounted scripts
- 🌍 **Timezone Support** - Configure timezone via `TZ` environment variable
- ☸️ **Kubernetes Ready** - Smart behavior for initContainers and workloads
- 🔒 **User Execution (Init/Cron)** - Init scripts and generated cron jobs run as the configured user
- 🧠 **Intelligent Behavior** - Exits cleanly for initContainers, runs persistently for cron jobs
- ♻️ **Nightly Updates** - Updated nightly to capture latest image layers *(includes latest edge release changes)*
- 🧾 **Startup Summary** - Prints kernel, mode, user/group, script counts, timezone, log level, and cron source
- 🗒️ **Standardized Logging** - Level-aware logs: ERROR, WARN, INFORMATIONAL (default), VERBOSE, DEBUG

## 🏷️ Image Tags

| Tag                  | Example              | Description
|----------------------|----------------------|------------------------------------------
| `latest`             | `latest`             | Latest Stable Image
| `edge`               | `edge`               | Tracks latest `main` branch commit
| `nightly`            | `nightly`            | Nightly builds off `edge` image
| `v{semver-tag}`      | `v1.2.3` `v1.0` `v1` | Major/Minor/Patch releases
| `pr-{number}`        | `pr-10`              | Build related to pull request
| `{sha}`              | `0993e5bb`           | Specific commit version

## 🏁 Quick Start

### 🐳 Docker

```bash
# Build the image
docker build -t alpine-toolbox .

# Run with defaults
docker run -it alpine-toolbox

# Run with custom settings
docker run -it \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=America/Chicago \
  alpine-toolbox
```

### ⚓️ Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: backup-pod
spec:
  containers:
  - name: backup
    image: ghcr.io/rogly-net/alpine-toolbox:latest
    env:
    - name: PUID
      value: "1000"
    - name: PGID
      value: "1000"
    - name: TZ
      value: "America/Chicago"
    - name: CRON_SCHEDULE
      value: "0 4 * * *"
    volumeMounts:
    - name: backup-scripts
      mountPath: /scripts
  volumes:
  - name: backup-scripts
    configMap:
      name: backup-scripts
```

## 🛠️ Environment Variables

| Variable | Default | Description
|----------|---------|-------------
| `PUID` | `0` | User ID for container user (`0` for root, else 1000–6000)
| `PGID` | `0` | Group ID for container user (`0` for root, else 1000–6000)
| `TZ` | `UTC` | Timezone (e.g., `America/Chicago`)
| `CRON` | `false` | `true` for cron mode, `false` or unset for init mode
| `CRON_SCHEDULE` | `0 0 * * *` | Default schedule for cron jobs (midnight daily)
| `LOG_LEVEL` | `INFORMATIONAL` | Logging level: `ERROR`, `WARN`, `INFORMATIONAL` (default), `VERBOSE`, `DEBUG`

Notes:

- `PUID`/`PGID` may both be `0` to run as root. Otherwise, both must be integers between 1000 and 6000 (inclusive). The container will exit with an error if invalid.
- In cron mode, jobs are scheduled by `crond`. For discovered scripts, entries are generated to run as the configured user (non-root) via `su-exec`.

## 🎚️ Container Modes

The container operates in two distinct modes controlled by the `CRON` environment variable:

### Init Mode (`CRON=false` or unset)

- **Executes all scripts** in `/scripts`, `/init`, or `/cron-scripts` directories
- **Runs scripts sequentially** as the specified user
- **Exits cleanly** when all scripts complete (or on first failure)
- **Perfect for initContainers** and one-time setup tasks

### Cron Mode (`CRON=true`)

- **Creates cron jobs** from scripts in mounted directories or from a mounted `/cron-schedule` file
- **Runs persistently** to execute scheduled tasks
- **Perfect for backup containers** and scheduled automation
  - Generated entries run via `su-exec <user>` when a non-root user is configured

### Command Mode (explicit command)

- **Executes provided command** instead of init/cron logic when you pass a command
- **Runs as configured user** when non-root; runs as root when `PUID=0`/`PGID=0`
- Example: `docker run --rm ghcr.io/rogly-net/alpine-toolbox:latest echo "hello"`

## 📜 Script Execution

### Script Requirements

- Must be executable (`chmod +x`)
- Must have `.sh` extension
- Init mode: runs as the specified user (PUID/PGID)
- Cron mode: generated entries run as the specified non-root user via `su-exec`. Custom `/cron-schedule` entries are used as-is.
- Logging: controlled by `LOG_LEVEL` (case-insensitive)
  - `DEBUG`: stream full script stdout/stderr in real-time (no tags)
  - `VERBOSE`: heartbeat every 1s, with explicit start/finish lines (tagged with `[VERBOSE]` and `[INFORMATIONAL]`)
  - `INFORMATIONAL` / `INFO`: heartbeat every 5s with completion line (default, tagged with `[INFORMATIONAL]`)
  - `WARN` / `ERROR`: same heartbeat behavior as `INFORMATIONAL`, but fewer container logs overall

### Supported Directories

- `/scripts` (recommended)
- `/init`
- `/cron-scripts`

## 📆 Scheduling Options

### Default Schedule

All scripts run at **midnight daily** (`0 0 * * *`) unless overridden.

### Custom Schedule Options

#### Option 1: Environment Variable

```yaml
env:
- name: CRON_SCHEDULE
  value: "0 2 * * *"  # Daily at 2 AM
```

#### Option 2: Custom Schedule File

Mount a file at `/cron-schedule` with individual schedules:

```text
0 2 * * * /scripts/backup.sh
30 3 * * * /scripts/cleanup.sh
0 4 * * 0 /scripts/weekly-maintenance.sh
```

## 🧪 Examples

### Cron Mode (Persistent - Backup Container)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: backup-pod
spec:
  containers:
  - name: backup
    image: ghcr.io/rogly-net/alpine-toolbox:latest
    env:
    - name: PUID
      value: "1000"
    - name: PGID
      value: "1000"
    - name: TZ
      value: "America/Chicago"
    - name: CRON
      value: "true"  # Enable cron mode
    - name: CRON_SCHEDULE
      value: "0 4 * * *"  # Daily at 4 AM
    volumeMounts:
    - name: backup-scripts
      mountPath: /scripts
    - name: data
      mountPath: /data
  volumes:
  - name: backup-scripts
    configMap:
      name: backup-scripts
  - name: data
    persistentVolumeClaim:
      claimName: data-pvc
```

**Container Output:**

```text
== Alpine Toolbox Startup ==
Kernel: 6.8.0-1017-azure
Mode: cron
User ID: 1000
Group ID: 1000
Timezone: America/Chicago
Startup time: 2025-10-21 09:15:32 CDT
Log level: INFORMATIONAL
Script directories: /scripts(1) (total: 1)
Cron source: env CRON_SCHEDULE: 0 4 * * *
=============================
[INFORMATIONAL] Creating user with UID: 1000, GID: 1000
[INFORMATIONAL] No existing group found with GID: 1000, creating new group
[INFORMATIONAL] No existing user found with UID: 1000, creating new user
[INFORMATIONAL] Using user: customuser (UID: 1000, GID: 1000)
[INFORMATIONAL] CRON mode enabled - setting up cron jobs and running persistently
[INFORMATIONAL] Found scripts directory: /scripts
[INFORMATIONAL] Setting up cron job for: backup.sh (schedule: 0 4 * * *)
[INFORMATIONAL] Starting crond...
[INFORMATIONAL] crond started successfully (PID: 15)
[INFORMATIONAL] Cron jobs detected - keeping container running...
0 4 * * * su-exec customuser /usr/local/bin/run_script.sh /scripts/backup.sh backup.sh >> /proc/1/fd/1 2>&1

[INFORMATIONAL] Container will run indefinitely for cron jobs. Use Ctrl+C to stop.
```

### Init Mode (Exits Cleanly - InitContainer)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
spec:
  initContainers:
  - name: setup
    image: ghcr.io/rogly-net/alpine-toolbox:latest
    env:
    - name: PUID
      value: "1000"
    - name: PGID
      value: "1000"
    - name: CRON
      value: "false"  # Init mode (default)
    volumeMounts:
    - name: setup-scripts
      mountPath: /scripts
  containers:
  - name: app
    image: nginx
```

**Container Output:**

```text
== Alpine Toolbox Startup ==
Kernel: 6.8.0-1017-azure
Mode: init
User ID: 1000
Group ID: 1000
Timezone: UTC
Startup time: 2025-10-21 15:22:45 UTC
Log level: INFORMATIONAL
Script directories: /scripts(2) (total: 2)
=============================
[INFORMATIONAL] Creating user with UID: 1000, GID: 1000
[INFORMATIONAL] No existing group found with GID: 1000, creating new group
[INFORMATIONAL] No existing user found with UID: 1000, creating new user
[INFORMATIONAL] Using user: customuser (UID: 1000, GID: 1000)
[INFORMATIONAL] Init mode enabled - executing scripts and exiting
[INFORMATIONAL] Found scripts directory: /scripts
[INFORMATIONAL] Executing init script: setup-database.sh
[INFORMATIONAL] setup-database.sh: 100% complete
[INFORMATIONAL] ✅ setup-database.sh completed successfully
[INFORMATIONAL] Executing init script: create-users.sh
[INFORMATIONAL] create-users.sh: 100% complete
[INFORMATIONAL] ✅ create-users.sh completed successfully
[INFORMATIONAL] All init scripts completed successfully. Container exiting.
```

### Custom Schedule File

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: maintenance-pod
spec:
  containers:
  - name: maintenance
    image: ghcr.io/rogly-net/alpine-toolbox:latest
    env:
    - name: CRON
      value: "true"
    volumeMounts:
    - name: maintenance-scripts
      mountPath: /scripts
    - name: cron-schedule
      mountPath: /cron-schedule
  volumes:
  - name: maintenance-scripts
    configMap:
      name: maintenance-scripts
  - name: cron-schedule
    configMap:
      name: cron-schedule
```

**Cron Schedule File (`/cron-schedule`):**

```text
0 2 * * * /scripts/daily-backup.sh
30 3 * * * /scripts/cleanup.sh
0 4 * * 0 /scripts/weekly-maintenance.sh
```

Tip: Custom schedule lines are used as-is. To force user execution here, explicitly wrap:

```text
0 2 * * * su-exec customuser /scripts/daily-backup.sh >> /proc/1/fd/1 2>&1
```

## Container Behavior

The container behavior is controlled by the `CRON` environment variable:

| Mode | CRON Value | Behavior | Use Case
|------|------------|----------|----------
| **Init Mode** | `false` or unset | Executes scripts sequentially, exits cleanly | InitContainers, setup tasks
| **Cron Mode** | `true` | Creates cron jobs, runs persistently | Backup containers, scheduled tasks
| **Command Mode** | any (explicit command) | Executes provided command | One-off commands

### Startup Information & Logging

On startup, the container prints a summary to stdout, including:

- Kernel version
- Mode (`init`, `cron`, or `command`)
- User ID and Group ID (PUID/PGID values)
- Timezone
- Startup time (current date/time in the configured timezone)
- Log level (`LOG_LEVEL`)
- Discovered script directories and counts
- Cron source (env `CRON_SCHEDULE` or custom `/cron-schedule` file when in cron mode)

Example:

```text
== Alpine Toolbox Startup ==
Kernel: 6.8.0-1017-azure
Mode: cron
User ID: 1000
Group ID: 1000
Timezone: UTC
Startup time: 2025-10-21 12:00:00 UTC
Log level: INFORMATIONAL
Script directories: /scripts(2), /cron-scripts(1) (total: 3)
Cron source: env CRON_SCHEDULE: 0 4 * * *
=============================
```

Most operational messages are now level-tagged (e.g., `[INFORMATIONAL]`, `[VERBOSE]`, `[DEBUG]`) and respect `LOG_LEVEL`.

## 🔐 Security

- **Init Mode**: Works with any security context (root or non-root)
- **Cron Mode**: Requires root privileges for `crond`; generated jobs run as the configured user (non-root) via `su-exec`
- **Command Mode**: Executes as configured user (or root if `PUID=0`/`PGID=0`)
- Uses `su-exec` for secure user switching when needed
- Minimal Alpine Linux base reduces attack surface
- Timezone handled automatically via `TZ` environment variable
