# Vibecoder Operating Constitution (Phone-First, Zero-Drift Delivery)

You are building software for a solo vibecoder who works primarily from a phone and **never inspects raw code or manually babysits git branches**. Every shipped artifact (APK, web app, service, or sandbox config) MUST permanently land in the codebase so future sessions never overwrite or lose earlier features.

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
     (For brand-new project roots such as `~/projects/itl/<app>`, if `~/.gitconfig` does not yet have a matching `includeIf` rule for `~/projects/itl/**`, follow the matching profile in `~/.gitconfig`—for example `.gitconfig-toast` → `infinite-toast-labs` for ITL repos—and configure `includeIf` or local repo identity so `.gitconfig` resolves accurately.)
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

Never hand the user an installable or runnable artifact (APK, AAB, binary, archive, deployed bundle, or rebuilt service) built from a dirty working tree or an unmerged branch.

Follow this exact sequence for every deliverable:
1. **Implement & verify** (unit tests, lint, emulator E2E, or `make` checks).
2. **Clean & commit** all intended changes (keep build outputs, caches, and local artifacts in `.gitignore`; never leave source files untracked).
3. **Land onto `main`** and delete any temporary branch/worktree.
4. **Push `main` to `origin`** so the macOS host, `llm-sandbox`, and `llm-sandbox-android` stay synchronized (for brand-new repos with no remote yet, follow Section 4).
5. **Confirm clean landed state:** `git branch --show-current` is `main`, `git status --porcelain` is empty, and `HEAD == origin/main` (when a remote exists).
6. **Build the final deliverable artifact FROM that clean `main` commit**, stamped with the version and short git SHA.

---

## 4. New & Existing Project Standards (Both Sandboxes)

- **Canonical path for new ITL projects:** `~/projects/itl/<kebab-case-name>` (for example, `~/projects/itl/calculator`), unless the user explicitly specifies another path.
  - Before creating a new project, check `~/projects/itl/`, `~/workspace/itl/`, and `~/workspaces/itl/` so you never accidentally create a duplicate repo.
- **Makefile-First operational UX:**
  - Every project MUST have a root `Makefile` on day zero.
  - `make` targets are the primary interface for setup, build, run, test, lint, clean, and ship operations (minimum targets as applicable: `help`, `start`, `status`, `build`, `test`, `lint`, `clean`, plus `ship-apk` for Android apps).
  - Never ask the user to copy/paste raw shell sequences when a `make` target can exist; update `Makefile` first, then run `make <target>`.
- **Day-zero repository bootstrap (every new project):**
  1. `git init -b main`
  2. Verify git author identity from `.gitconfig` (for ITL repos under `~/projects/itl/`, confirm `.gitconfig` resolves `infinite-toast-labs` via `.gitconfig-toast` or add/set the matching identity) and switch `gh` to that account per Section 2.
  3. Add a stack-appropriate `.gitignore` (never commit `.gradle/`, `build/`, `app/build/`, `node_modules/`, `dist/`, `artifacts/`, secrets, or keystores).
  4. Create the root `Makefile`.
  5. Make an initial commit on `main`.
  6. If `gh auth status` succeeds and no remote exists, create a **private** GitHub repository under `infinite-toast-labs/<project-name>` and push `main` immediately so container rebuilds never lose work. If `gh` is unavailable or unauthenticated, warn explicitly in the handoff: `Backup: LOCAL-ONLY (not pushed to GitHub)`.

---

## 5. Android Sandbox Rules (`llm-sandbox-android`)

- Keep **all** Gradle, Android SDK, and `adb` work inside the container. **Never** launch an Android emulator inside Docker.
- Connect to the macOS host emulator via the host ADB server bridge (`host.docker.internal:5037`, deterministic serial `emulator-5560`) using `android-adb` / `android-emulator-adb`. If the bridge or device is missing, stop and tell the user to run `make android-up` (or `make android-connect`) on the host.
- **Phone install & upgrade continuity (mandatory on every Android app):**
  - Reuse a **persistent signing keystore** stored outside git (e.g., `~/.android/debug.keystore` or a persistent release keystore). Never regenerate signing keys between builds (doing so breaks in-place updates and forces data-wiping uninstalls).
  - Compute **`versionCode` monotonically** (e.g., from `git rev-list --count HEAD` or a strictly increasing integer) so Android always upgrades in place without `INSTALL_FAILED_VERSION_DOWNGRADE`.
  - Include the **short git SHA** in `versionName` (e.g., `1.0.<commitCount>-<shortSHA>`) and display it in a subtle footer or About label inside the app so the user can confirm on their phone exactly which build is installed.
- **Mechanical `make ship-apk` guard:** Include a `ship-apk` target in every Android project's `Makefile` that refuses to copy a deliverable APK into `dist/` unless `git branch --show-current == main`, `git status --porcelain` is empty, and (when a remote exists) `HEAD == origin/main`.
- **Verification before delivery:**
  1. Compile via `./gradlew --no-daemon assembleDebug --console=plain` (or project `make build`).
  2. Install onto `emulator-5560` via `android-emulator-adb install -r <apk>`.
  3. Launch the main activity and run at least one deterministic UI check.
  4. Capture screenshot evidence under `artifacts/android-e2e/` (gitignored).
- **Deliverable output:** Emit the final clean-`main` APK to `dist/<app-name>-v<versionName>-<shortSHA>.apk` (gitignored) and report its exact path.

---

## 6. `llm-sandbox` Infrastructure Repo Rules

When working on `llm-sandbox` itself (on the macOS host or inside a sandbox):
- Follow the exact same trunk-based, pre-flight reconciliation, and clean-`main` push rules above.
- **Never apply container-only hotfixes** (editing files under `/opt/llm-sandbox/`, `/opt/gem/`, nginx, or supervisord directly inside a running container) without committing the source change in `llm-sandbox` and applying it via `Makefile` targets (`make up`, `make android-up`, `make location-install`, `make clipboard-install`, etc.). Container-only edits vanish on the next rebuild.
- Keep `Makefile` targets idempotent and preserve isolation between the regular sandbox (`llm-sandbox`, `:8080`, volume `llm-sandbox-home`) and the Android sandbox (`llm-sandbox-android`, `:8081`, volume `llm-sandbox-android-home`).

---

## 7. Phone-First Handoff Receipt (Required at End of Every Task)

Keep final replies brief, plain-English, and easy to scan on a phone screen. End every completed delivery with this exact receipt:

- **What changed:** 2–4 plain-English bullets describing user-visible behavior (not code diffs).
- **Verified:** Exact verification performed (tests, `make` targets, or emulator install/launch + screenshot path).
- **Source of truth:** `<repo-path>` on `main @ <shortSHA>` — working tree clean, pushed to `origin/main` (`✓` or explicit `LOCAL-ONLY` warning), unmerged branches: `0`.
- **Artifact:** Exact path/URL/target (for Android APKs: include `versionName` and `versionCode`).
