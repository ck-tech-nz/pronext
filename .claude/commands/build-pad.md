---
description: Build Pad (Android tablet) APK — production or test, with optional R2 upload
argument-hint: <prod|test> [-u]
allowed-tools: Bash(*), Read
---

# Build Pad APK

Build ProNext Pad release APK and optionally upload to R2.

## Arguments

Parse `$ARGUMENTS` to determine build type and options:

**Build types:**

- `prod` or empty - Production build (default, registers APK with prod backend)
- `test` or `t` - Test build (registers APK with test backend)

**Options:**

- `-u` or `--upload` - Upload APK to R2 after build (also creates a git tag)

**Examples:**

- `/build-pad` → Production build, no upload
- `/build-pad prod` → Production build, no upload
- `/build-pad test` → Test build, no upload
- `/build-pad prod -u` → Production build + upload to R2 + git tag
- `/build-pad test -u` → Test build + upload to R2 + git tag
- `/build-pad -u` → Production build + upload to R2 + git tag

## Instructions

### Step 1: Parse Arguments

If `$ARGUMENTS` is empty, default to production build without upload.

Parse the arguments to determine:

1. Build type: `prod` (default) or `test`
2. Upload flag: whether `-u` or `--upload` is present

### Step 2: Pre-flight Checks

Before building, verify:

1. Current working directory or navigate to `/Users/ck/Git/pronext/pad`
2. Confirm `settings.gradle.kts` exists (we're in the right directory)
3. Check git status - warn if there are uncommitted changes (the build script will fail)

Report the planned build to the user:

- Build type (Production / Test)
- Upload enabled or not
- Current git branch and status

### Step 3: Execute Build

Run the build script from the pad root directory:

```bash
cd /Users/ck/Git/pronext/pad

# Production build (no upload)
./scripts/build.sh

# Production build + upload
./scripts/build.sh --upload

# Test build (no upload)
./scripts/build.sh --test

# Test build + upload
./scripts/build.sh --test --upload
```

The script will:

1. Check for uncommitted changes (exits if any)
2. Auto-increment `versionCode` in `app/build.gradle.kts` and commit
3. Clean and build release APK via `./gradlew assembleRelease`
4. Copy APK to `./build-output/`
5. If `--upload`: upload APK to Cloudflare R2 and register with backend API
   - `--test`: registers with test backend (`admin-test.pronextusa.com`)
   - default: registers with prod backend (`admin.pronextusa.com`)

### Step 4: Post-Build Tag (if -u flag)

When `-u` is used, after a SUCCESSFUL build and upload, automatically create a git tag:

```bash
cd /Users/ck/Git/pronext/pad

# Read versionName and versionCode from app/build.gradle.kts
# Format: pad-v{versionName}-{versionCode}-{prod|test}
# Examples:
#   pad-v2.1.0-1393-prod
#   pad-v2.1.0-1393-test

git tag <tag_name>
git tag  # verify
```

### Step 5: Report Results

After build completes, report:

1. Success or failure
2. Version info (versionName + versionCode)
3. APK file location and size
4. If uploaded: R2 URL from build script output
5. If tagged: the git tag created
6. The git commit that was created for the version bump

## Output Locations

| Type        | Path                                  |
| ----------- | ------------------------------------- |
| Release APK | `app/build/outputs/apk/release/*.apk` |
| Copy        | `build-output/*.apk`                  |

## Version Format

`app/build.gradle.kts`: `versionName = "x.y.z"` + `versionCode = N`

The build script auto-increments `versionCode` on each build.
