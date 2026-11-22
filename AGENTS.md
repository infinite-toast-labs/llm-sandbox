# Vibecoder Operating Constitution (Phone-First, Zero-Drift Delivery)

You are building software for a solo vibecoder who works primarily from a phone and **never inspects raw code or manually babysits git branches**. Every shipped artifact (APK, Zstore release, web app, service, or sandbox config) MUST permanently land in the codebase so future sessions never overwrite or lose earlier features.

This constitution applies to:
- This repository (`llm-sandbox`)
- Existing and new projects worked on in the regular sandbox (`llm-sandbox`)
- Existing and new projects worked on in the Android sandbox (`llm-sandbox-android`)

---

## 1. Single Source of Truth: `main` IS Production

- `main` (the default branch) MUST always represent the latest working version the user has installed or is running.
- **Never leave completed work on a feature branch, in a stash, or as uncommitted files.**
- **Do not open a PR and stop to wait for the user** unless the user explicitly asks for a PR or code review.
- Normal workflow: commit verified changes directly on `main` and push `origin/main`.
- **Worktree / isolated-branch exception** (e.g., when a harness or parallel agent setup runs inside a temporary branch or git worktree):
  1. Rebase/merge onto the latest `origin/main`.
  2. Land the verified result onto `main` (fast-forward/squash merge into `main`, or push `HEAD:main` and fast-forward local `main`) and delete the temporary branch/worktree before reporting completion.
  3. If remote branch protection blocks direct push to `main`, open a PR, merge it automatically once checks pass, and **do not hand over a final user-facing artifact until the PR is merged into `main`**. If human approval blocks merge, stop and say so clearly instead of shipping an unlanded artifact.

---

## 2. Mandatory Pre-Flight Reconciliation (Run BEFORE Any Edit)

### GitHub Account Alignment (`.gitconfig` Is Source of Truth)

- Treat `.gitconfig` (including its `includeIf` directory rules such as `.gitconfig-toast` and `.gitconfig-krovzn`) as the **single source of truth** for which GitHub account owns the current repository.
- Before running `git fetch`, `git push`, or any `gh` command:
  1. Resolve the authoritative account from `.gitconfig` inside the repo directory:
     ```bash
     git config --show-origin user.name
     ```
     (If a user explicitly requests a project directory not yet matched by `~/.gitconfig` `includeIf` rules, follow the matching profile in `~/.gitconfig`—for example `.gitconfig-toast` → `infinite-toast-labs` for ITL repos—and configure `includeIf` or local repo identity so `.gitconfig` resolves accurately.)
  2. Check the active `gh` account with `gh auth status`.
  3. **You have explicit permission to switch `gh` to the matching account** whenever the active account differs from `.gitconfig`'s resolved `user.name`:
     ```bash
     gh auth switch --user "<resolved-user.name>"
     ```
  4. Never run `git push`, `gh repo create`, or other GitHub operations under a mismatched account. If the `.gitconfig` account is not logged into `gh`, stop and ask the user to authenticate it.

### Repository State Audit

Before writing code or switching branches in any existing repository, audit the full git state:

```bash
git fetch --all --prune            # when a remote exists
git status --porcelain
git branch --no-merged main
git branch -vv
git stash list
git worktree list
```

**Hard prohibitions:**
- **NEVER** silently create a new branch off `main` when dirty files, untracked source code, stashes, or unmerged branches exist.
- **NEVER** run destructive discards (`git reset --hard`, `git checkout -- .`, `git clean -fd`) on unknown work.

**Reconciliation protocol:**
1. If `origin/main` is ahead of local `main` and the working tree is clean, fast-forward `main` first so work done on another host or sandbox container is never overwritten.
2. If you find uncommitted source changes, untracked source directories, stashes, or unmerged branches:
   - Inspect them (`git diff --stat`, `git log main..<branch> --stat`) and summarize what feature/fix they contain in **plain English** (no git jargon).
   - **STOP and ask the user ONE concise, phone-friendly question** before starting the new task:
     > "Before I start **[new task]**, I found unsaved/unmerged work from **[date/branch]**: **[1-sentence plain-English summary]**. Should I:
     > 1. **Keep & merge it first**, then build **[new task]** on top of it (Recommended)
     > 2. **Discard it** and start from the last saved version?"
3. Proceed only after the workspace is cleanly reconciled onto `main`.

---

## 3. The "Land-Before-Build" Artifact Gate (Strict Order)

Never hand the user an installable or runnable artifact (APK, AAB, Zstore release, binary, archive, deployed bundle, or rebuilt service) built from a dirty working tree or an unmerged branch.

Follow this exact sequence for every deliverable:
1. **Implement & verify** (unit tests, lint, compile, emulator E2E when in scope, or `make` checks).
2. **Clean & commit** all intended changes—including `Makefile`, Gradle wrapper, and any Zstore `catalog/` files (`manifest.yaml`, `description.md`, `icon.png`, `release-<version>.md`)—while keeping build outputs, caches, and local artifacts in `.gitignore`. Never leave source files untracked.
3. **Land onto `main`** and delete any temporary branch/worktree.
4. **Push `main` to `origin`** so the macOS host, `llm-sandbox`, and `llm-sandbox-android` stay synchronized (for brand-new repos with no remote yet, follow Section 4).
5. **Confirm clean landed state:** `git branch --show-current` is `main`, `git status --porcelain` is empty, and `HEAD == origin/main` (when a remote exists).
6. **Build (and for Zstore: sign, inspect, publish, promote) the final deliverable artifact FROM that clean `main` commit**, stamped with the version and short git SHA.

---

## 4. Host vs. Sandbox Execution Boundaries & Project Standards

### Host-to-Container Routing (Read Carefully When Starting Under `llm-sandbox`)

Threads opened under the `llm-sandbox` project typically run on the **macOS host** (`/Users/captn/cool/itl/llm-sandbox`), NOT inside Docker.
- **NEVER create new app or project directories inside `/Users/captn/cool/itl/llm-sandbox/`.**
- When the user asks to create or modify a project in the **Android sandbox**, execute commands inside container `llm-sandbox-android` as user `gem`:
  ```bash
  docker exec -u gem llm-sandbox-android bash -lc '...'
  ```
- When the user asks to create or modify a project in the **regular sandbox**, execute commands inside container `llm-sandbox` as user `gem`:
  ```bash
  docker exec -u gem llm-sandbox bash -lc '...'
  ```
- **Container preservation (hard safety boundary):** During app work, **NEVER** stop, restart, recreate, remove, or run `make up`, `make android-up`, `make android-connect`, or `make android-emulator-start` on running sandbox containers without explicit user approval. (`llm-sandbox-android` hosts live Zstore services; ignore a Docker `(unhealthy)` status badge as long as `docker exec` and required services work.)

### Canonical Project Paths (Aligned with `.gitconfig`)

- **Android sandbox (`llm-sandbox-android`):** `/home/gem/workspace/itl/<kebab-case-name>` (matches `includeIf "gitdir:~/workspace/itl/**"` → `.gitconfig-toast` → `infinite-toast-labs`).
- **Regular sandbox (`llm-sandbox`):** `/home/gem/workspaces/itl/<kebab-case-name>` (matches `includeIf "gitdir:~/workspaces/itl/**"` → `.gitconfig-toast` → `infinite-toast-labs`).
- Before creating a new project, check `~/workspace/itl/`, `~/workspaces/itl/`, and `~/projects/itl/` in the target container (and check `gh repo view infinite-toast-labs/<name>`) so you never create a duplicate repo.

### Makefile-First Operational UX

- Every project MUST have a root `Makefile` on day zero.
- `make` targets are the primary interface for setup, build, run, test, lint, clean, and ship operations (minimum targets as applicable: `help`, `start`, `status`, `build`, `test`, `lint`, `clean`, plus `ship-apk` for Android apps).
- Never ask the user to copy/paste raw shell sequences when a `make` target can exist; update `Makefile` first, then run `make <target>`.

### Day-Zero Repository Bootstrap (Every New Project)

1. `git init -b main`
2. Verify git author identity from `.gitconfig` (`git config --show-origin user.name` → `infinite-toast-labs` for ITL repos) and align `gh` to that account per Section 2.
3. Add a stack-appropriate `.gitignore` (never commit `.gradle/`, `.kotlin/`, `build/`, `app/build/`, `local.properties`, `node_modules/`, `dist/`, `artifacts/`, `__pycache__/`, `.DS_Store`, secrets, or keystores).
4. Create the root `Makefile` (and for Android projects, commit a Gradle Wrapper `./gradlew` per Section 5).
5. Make an initial commit on `main`.
6. If `gh auth status` succeeds and no remote exists, create a **private** GitHub repository under `infinite-toast-labs/<project-name>` and push `main` immediately so container rebuilds never lose work. If `gh` is unavailable or unauthenticated, warn explicitly in the handoff: `Backup: LOCAL-ONLY (not pushed to GitHub)`.

---

## 5. Android Sandbox Rules (`llm-sandbox-android`)

- **Container-only builds & exact toolchain:**
  - Keep **all** Gradle, Android SDK, and `adb` work inside `llm-sandbox-android`. **Never** launch an Android emulator inside Docker.
  - **Never use `/usr/bin/gradle`** (it is legacy Gradle 4.4.1). The container provides JDK 17 (`/usr/bin/java`), Android SDK at `/opt/android-sdk` (`compileSdk 36`, build-tools `34.0.0`, `35.0.0`, `36.0.0`), and `/home/gem/gradle-8.7/bin/gradle`.
  - On day zero for every new Android app, generate and commit a Gradle Wrapper matching the project's AGP version (for example, `/home/gem/gradle-8.7/bin/gradle wrapper --gradle-version 8.9` for AGP 8.7.x) and run builds with `./gradlew --no-daemon ... --console=plain`.
- **Protected device & emulator boundaries (HARD RULES):**
  - **NEVER** touch, query, install on, stop, or wipe **`emulator-5570`** (protected device).
  - **NEVER** run `make android-up`, `make android-connect`, or `make android-emulator-start` during app work without explicit user approval.
  - When emulator verification is in scope:
    - For Zstore-targeted apps, use **`-s emulator-5580`** (`zstore_pixel_9_pro_api_36_1`) via `android-adb -s emulator-5580 ...` only. Fail closed if `emulator-5580` is unavailable.
    - Use `android-emulator-adb` (`emulator-5560`) only if `emulator-5560` is already attached and explicitly requested.
  - **Honoring explicit testing opt-outs:** If the user explicitly skips UI/emulator testing (for example, *"no need for extensive ui testing"*), do **not** block on an emulator—still run a clean Gradle compile plus lint/unit tests where applicable, skip emulator UI steps, and explicitly record `"Device/UI testing skipped per user request"` in both Zstore release notes and the Handoff Receipt.
- **Phone install & upgrade continuity (mandatory on every Android app):**
  - **Monotonic `versionCode`:** Increment `versionCode` strictly on every release (or derive from `git rev-list --count HEAD` on linear `main`) so Android and Zstore always upgrade in place without `INSTALL_FAILED_VERSION_DOWNGRADE`.
  - **Visible build lineage:** Include the **short git SHA** in `versionName` (e.g., `1.0.<versionCode>-<shortSHA>`) or display it in a subtle footer/About label inside the app so the user can confirm on their phone exactly which build is installed.
  - **Signing mode separation:**
    - **Zstore releases (Section 6):** Build an **unsigned universal APK** (`zstore` build type with `signingConfig null`, package like `dev.toastlabs.<app>`). Sign exclusively via `zstorectl` with that package's permanent managed key.
    - **Direct ADB debug installs (non-Zstore):** Reuse a persistent signing keystore outside git (e.g., `~/.android/debug.keystore`). Never regenerate signing keys between builds.
- **Mechanical `make ship-apk` guard:** Include a `ship-apk` target in every Android project's `Makefile` that refuses to copy a deliverable APK into `dist/` unless `git branch --show-current == main`, `git status --porcelain` is empty, and (when a remote exists) `HEAD == origin/main`.
- **Verification & output:**
  - When emulator verification runs: compile → install on permitted emulator (`-s emulator-5580` or running `emulator-5560`) → launch main activity → run deterministic UI check → capture screenshot under `artifacts/android-e2e/` (gitignored).
  - Emit local clean-`main` APKs to `dist/<app-name>-v<versionName>-<shortSHA>.apk` (gitignored).

---

## 6. Zstore Publishing Rules (`llm-sandbox-android`)

When the user asks to push or publish a build (draft, `canary`, or `stable`) to **Zstore**:

1. **Read Zstore's guardrails and publishing guide first** inside `llm-sandbox-android`:
   - `/home/gem/workspace/itl/zstore/AGENTS.md`
   - `/home/gem/workspace/itl/zstore/docs/PUBLISHING.md`
   - Reference app catalog example: `/home/gem/workspace/itl/poweramp-remote/catalog/`
2. **Protect secrets and existing repos:**
   - Credentials live at `/home/gem/.config/zstore/credentials/operator.token` and managed keys under `/home/gem/.config/zstore/signing` (`0700`/`0600`). Pass paths via CLI flags; **never** print secret values or commit keystores/tokens.
   - Do not modify `/home/gem/workspace/itl/zstore` or `/home/gem/workspace/itl/stool-facts` when publishing a separate app. Keep each app's `catalog/` inside that app's own repo.
3. **Commit & push BEFORE building/publishing (Section 3 gate):**
   - Commit the app source, Gradle wrapper, `Makefile`, and valid schema-v1 `catalog/` files (`manifest.yaml`, `description.md`, `icon.png`, `release-<version>.md`—all regular files under `catalog/`) onto `main` and push `origin/main` **before** building, signing, and publishing the final APK.
4. **Managed per-package signing key (generate ONCE, never regenerate):**
   - Check `/home/gem/.config/zstore/signing` first. Only if no key exists for `<packageName>`, run:
     ```bash
     cd /home/gem/workspace/itl/zstore
     ./bin/zstorectl key generate --package <packageName> --alias <alias>
     ```
   - Never regenerate an existing package's key; Zstore permanently pins the first signer per package.
5. **Sign → inspect → publish draft → promote:**
   - Build the unsigned universal `zstore` APK from the clean, pushed `main` commit.
   - Sign into a gitignored or state staging path (e.g., `/home/gem/.local/state/zstore/<app>-<version>/` or gitignored `dist/`):
     ```bash
     cd /home/gem/workspace/itl/zstore
     ./bin/zstorectl sign <unsigned.apk> --package <packageName> --alias <alias> --output <signed.apk>
     ./bin/zstorectl inspect <signed.apk>
     ```
   - Publish draft to the live loopback server (`http://127.0.0.1:8380`):
     ```bash
     ./bin/zstorectl publish <signed.apk> \
       --metadata <path/to/catalog/manifest.yaml> \
       --server http://127.0.0.1:8380 \
       --identity operator@example.com \
       --credential-file /home/gem/.config/zstore/credentials/operator.token \
       --draft
     ```
   - Promote to the requested channel (`canary` or `stable`):
     ```bash
     ./bin/zstorectl promote <RELEASE_ID> \
       --channel canary \
       --server http://127.0.0.1:8380 \
       --identity operator@example.com \
       --credential-file /home/gem/.config/zstore/credentials/operator.token
     ```
   - Check `./bin/zstorectl <subcommand> --help` if flag order or options need verification.

---

## 7. `llm-sandbox` Infrastructure Repo Rules

When working on `llm-sandbox` itself (on the macOS host or inside a sandbox):
- Follow the exact same trunk-based, pre-flight reconciliation, and clean-`main` push rules above.
- **Never apply container-only hotfixes** (editing files under `/opt/llm-sandbox/`, `/opt/gem/`, nginx, or supervisord directly inside a running container) without committing the source change in `llm-sandbox` and applying it via `Makefile` targets (`make up`, `make android-up`, `make location-install`, `make clipboard-install`, etc.). Container-only edits vanish on the next rebuild.
- Keep `Makefile` targets idempotent and preserve isolation between the regular sandbox (`llm-sandbox`, `:8080`, volume `llm-sandbox-home`) and the Android sandbox (`llm-sandbox-android`, `:8081`, volume `llm-sandbox-android-home`).

---

## 8. Phone-First Handoff Receipt (Required at End of Every Task)

Keep final replies brief, plain-English, and easy to scan on a phone screen. End every completed delivery with this exact receipt:

- **What changed:** 2–4 plain-English bullets describing user-visible behavior (not code diffs).
- **Verified:** Exact verification performed (compile/lint/tests, `make` targets, emulator install/launch + screenshot path, or explicit note that device/UI testing was skipped per user request).
- **Source of truth:** `<repo-path>` on `main @ <shortSHA>` — working tree clean, pushed to `origin/main` (`✓` or explicit `LOCAL-ONLY` warning), unmerged branches: `0`.
- **Artifact:** Exact path/URL/target (for Android/Zstore builds: include `packageName`, `versionName`, `versionCode`, Zstore `RELEASE_ID` + channel, and APK SHA-256).
