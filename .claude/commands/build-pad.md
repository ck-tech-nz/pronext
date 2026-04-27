---
description: Build Pad APK, upload to R2, register with backend; tag on prod
argument-hint: <test|prod>
allowed-tools: Bash(*), Read
---

# Build Pad APK

Build a ProNext Pad APK, upload to R2, and register it with the backend. On `prod` also create a git tag.

Every build auto-bumps the **patch segment of `versionName`** (e.g. `2.2.2` → `2.2.3`) **and** `versionCode`, and commits the bump.

Both modes register against the same backend (`admin.pronextusa.com`) — only the build type and registered status differ.

## Arguments

Parse `$ARGUMENTS` to determine environment:

- `test` or `t` — debug build (`BuildConfig.DEBUG = true`, no R8), registered as `TESTING`, **no tag**
- `prod` or `p` or empty — release build (`BuildConfig.DEBUG = false`, full minify), registered as `UNPUBLISHED`, tag `pad-vX.Y.Z-NNNN`

**Examples:**

- `/build-pad test` → debug APK, status `TESTING`, no tag — installable on real devices for debugging (attach debugger, no R8 obfuscation)
- `/build-pad prod` → release APK, status `UNPUBLISHED`, tagged — full production pipeline (rollout to `PUBLISHED` is a manual admin step)
- `/build-pad` → same as `prod`

## Why two build types?

`--test` produces an `assembleDebug` APK so devs can attach a debugger and read unobfuscated stack traces on a real device. The debug build is still signed with the release keystore (per `app/build.gradle.kts` `debug { signingConfig = signingConfigs.getByName("release") }`), so it installs cleanly on any Pad.

`--prod` produces `assembleRelease` with R8 minify + resource shrink for the production rollout.

### Default BASE_URL

`Net.kt:DEFAULT_BASE_URL` picks the initial backend based on two `BuildConfig` flags:

| Build path                                 | `IS_TEST_BUILD` | `DEBUG` | Default BASE_URL |
| ------------------------------------------ | :-------------: | :-----: | ---------------- |
| IDE Run / `./gradlew assembleDebug`        | false           | true    | `DEV_URL` (`10.0.2.2:8000`) |
| `/build-pad test` (`-PtestBuild=true`)     | true            | true    | `TEST_URL`       |
| `/build-pad` / `/build-pad prod`           | false           | false   | `PROD_URL`       |

The `IS_TEST_BUILD` flag is set only when `build.sh` passes `-PtestBuild=true` to gradle; plain debug builds from the IDE keep it false so the local-emulator → local-Django flow is unchanged.

### Developer mode

The hidden 11-tap-logo gesture on the activation page enables Developer Mode on **every** build (debug or release). The user can then switch BASE_URL between Dev / Prod / Test / Custom. See `Net.kt:DeveloperMode.enable()`.

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

# Test environment (debug build, status=TESTING)
./scripts/build.sh --upload --test

# Production environment (release build, status=UNPUBLISHED)
./scripts/build.sh --upload
```

The `--test` flag changes three things:

- **Gradle task**: `assembleDebug -PtestBuild=true` instead of `assembleRelease` → `BuildConfig.DEBUG = true`, `BuildConfig.IS_TEST_BUILD = true`, no R8
- **Default BASE_URL**: `TEST_URL` instead of `PROD_URL` (so the APK reaches the test backend on first launch without manually switching)
- **Registered status**: `TESTING` (test) vs. `UNPUBLISHED` (prod)

Backend domain for the registration call is `admin.pronextusa.com` in both cases.

The backend API (`/common/create-apk-version/`) only accepts `UNPUBLISHED` or `TESTING` — `PUBLISHED` is always rejected. Rolling out to `PUBLISHED` must be done through Django admin.

The script will:

1. Bump `versionName` patch + `versionCode` in `app/build.gradle.kts` and commit
2. Clean and build APK via `./gradlew assembleDebug` (test) or `./gradlew assembleRelease` (prod)
3. Copy APK to `./build-output/`
4. Upload APK to Cloudflare R2
5. Register APK version with the backend API (status per flag above)

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
2. Environment (test / prod) + build type (debug / release)
3. Version info (versionName + versionCode)
4. Registered status on backend (`TESTING` or `UNPUBLISHED`)
5. APK file location and size
6. R2 URL from build script output
7. Git tag created (prod only)
8. The version bump commit hash

## Output Locations

| Mode  | APK Path                              |
| ----- | ------------------------------------- |
| test  | `app/build/outputs/apk/debug/*.apk`   |
| prod  | `app/build/outputs/apk/release/*.apk` |
| both  | `build-output/*.apk` (copy)           |

APK filename pattern: `pronext-v{versionName}-{versionCode}_{buildType}_{gitHash}.apk` (`buildType` = `debug` or `release`).

## Version Format

`app/build.gradle.kts`: `versionName = "x.y.z"` + `versionCode = N`

Each build auto-increments both:
- `versionName`: patch segment (`x.y.z` → `x.y.(z+1)`)
- `versionCode`: `N` → `N+1`
