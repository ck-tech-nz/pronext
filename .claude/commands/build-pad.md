---
description: Build Pad APK, push to env branch, upload to R2, register with backend, and tag
argument-hint: <test|prod>
allowed-tools: Bash(*), Read
---

# Build Pad APK

Build, push, upload, and tag a ProNext Pad release APK in one step.

## Arguments

Parse `$ARGUMENTS` to determine environment:

- `test` or `t` — Push to `env/test`, register with test backend, tag `pad-vX.Y.Z-NNNN-test`
- `prod` or `p` or empty — Push to `env/prod`, register with prod backend, tag `pad-vX.Y.Z-NNNN-prod`

**Examples:**

- `/build-pad test` → Full test pipeline
- `/build-pad prod` → Full production pipeline
- `/build-pad` → Same as `prod`

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

### Step 3: Push to Environment Branch

```bash
cd /Users/ck/Git/pronext/pronext/pad

# Push current branch to the env branch (force-with-lease since env branches diverge)
git push --force-with-lease origin HEAD:env/test   # for test
git push --force-with-lease origin HEAD:env/prod    # for prod
```

### Step 4: Execute Build

Run the build script:

```bash
cd /Users/ck/Git/pronext/pronext/pad

# Test environment
./scripts/build.sh --upload --test

# Production environment
./scripts/build.sh --upload
```

The `--test` flag only affects which backend the APK is registered with:

- `--test`: registers with `https://admin-test.pronextusa.com`
- default: registers with `https://admin.pronextusa.com`

The script will:

1. Auto-increment `versionCode` in `app/build.gradle.kts` and commit
2. Clean and build release APK via `./gradlew assembleRelease`
3. Copy APK to `./build-output/`
4. Upload APK to Cloudflare R2
5. Register APK version with the appropriate backend API

### Step 5: Post-Build Tag

After a SUCCESSFUL build and upload, create a git tag:

```bash
cd /Users/ck/Git/pronext/pronext/pad

# Read versionName and versionCode from app/build.gradle.kts
# Format: pad-v{versionName}-{versionCode}-{test|prod}
# Examples:
#   pad-v2.2.0-1412-test
#   pad-v2.2.0-1412-prod

git tag <tag_name>
git push origin <tag_name>
```

### Step 6: Report Results

Report:

1. Success or failure
2. Environment (test / prod)
3. Version info (versionName + versionCode)
4. APK file location and size
5. R2 URL from build script output
6. Git tag created
7. The version bump commit hash

## Output Locations

| Type        | Path                                  |
| ----------- | ------------------------------------- |
| Release APK | `app/build/outputs/apk/release/*.apk` |
| Copy        | `build-output/*.apk`                  |

## Version Format

`app/build.gradle.kts`: `versionName = "x.y.z"` + `versionCode = N`

The build script auto-increments `versionCode` on each build.
