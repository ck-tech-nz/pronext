---
description: Build Pad APK, upload to R2, register with backend; tag on prod
argument-hint: <test|prod>
allowed-tools: Bash(*), Read
---

# Build Pad APK

Build a ProNext Pad release APK, upload to R2, and register it with the backend. On `prod` also create a git tag.

Every build auto-bumps the **patch segment of `versionName`** (e.g. `2.2.2` → `2.2.3`) **and** `versionCode`, and commits the bump.

## Arguments

Parse `$ARGUMENTS` to determine environment:

- `test` or `t` — register with test backend as `TESTING` status, **no tag**
- `prod` or `p` or empty — register with prod backend as `UNPUBLISHED` status, tag `pad-vX.Y.Z-NNNN`

**Examples:**

- `/build-pad test` → test build, APK lands as `TESTING` on test backend, no tag
- `/build-pad prod` → full production pipeline with tag (APK enters `UNPUBLISHED` — rollout to `PUBLISHED` is a manual admin step)
- `/build-pad` → same as `prod`

## Instructions

### Step 1: Parse Arguments

Parse `$ARGUMENTS`:

- `test` or `t` → env = `test`
- `prod` or `p` or empty → env = `prod`

### Step 2: Pre-flight Checks

Navigate to `/Users/ck/Git/pronext/pronext/pad` and verify:

1. `settings.gradle.kts` exists
2. Git status is clean (no uncommitted changes — build script will fail otherwise)

Report to user:

- Environment: test / prod
- Current git branch
- Git status

### Step 3: Execute Build

Run the build script:

```bash
cd /Users/ck/Git/pronext/pronext/pad

# Test environment
./scripts/build.sh --upload --test

# Production environment
./scripts/build.sh --upload
```

The `--test` flag changes two things:

- **Backend domain**: `admin-test.pronextusa.com` instead of `admin.pronextusa.com`
- **Registered status**: `TESTING` (test) vs. `UNPUBLISHED` (prod)

The backend API (`/common/create-apk-version/`) only accepts `UNPUBLISHED` or `TESTING` — `PUBLISHED` is always rejected. Rolling out to `PUBLISHED` must be done through Django admin.

The script will:

1. Bump `versionName` patch + `versionCode` in `app/build.gradle.kts` and commit
2. Clean and build release APK via `./gradlew assembleRelease`
3. Copy APK to `./build-output/`
4. Upload APK to Cloudflare R2
5. Register APK version with the appropriate backend API (status per flag above)

### Step 4: Post-Build Tag (prod only)

**Skip this step for `test` builds.**

After a SUCCESSFUL prod build and upload, create a git tag:

```bash
cd /Users/ck/Git/pronext/pronext/pad

# Read versionName and versionCode from app/build.gradle.kts
# Format: pad-v{versionName}-{versionCode}
# Examples:
#   pad-v2.2.0-1412
#   pad-v2.2.1-1428

git tag <tag_name>
git push origin <tag_name>
```

### Step 5: Report Results

Report:

1. Success or failure
2. Environment (test / prod)
3. Version info (versionName + versionCode)
4. Registered status on backend (`TESTING` or `UNPUBLISHED`)
5. APK file location and size
6. R2 URL from build script output
7. Git tag created (prod only)
8. The version bump commit hash

## Output Locations

| Type        | Path                                  |
| ----------- | ------------------------------------- |
| Release APK | `app/build/outputs/apk/release/*.apk` |
| Copy        | `build-output/*.apk`                  |

## Version Format

`app/build.gradle.kts`: `versionName = "x.y.z"` + `versionCode = N`

Each build auto-increments both:
- `versionName`: patch segment (`x.y.z` → `x.y.(z+1)`)
- `versionCode`: `N` → `N+1`
