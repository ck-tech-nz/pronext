---
description: Build Mobile (Flutter) app for App Store or Google Play
argument-hint: <ios|android|all> [options]
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep
---

# Build App Command

Unified app build workflow for iOS App Store and Google Play Store.

## Arguments

Parse `$ARGUMENTS` to determine platform and options:

**Platforms:**
- `ios` - Build and publish to App Store
- `android` - Build release APK for Google Play (default)
- `all` - Build both iOS and Android

**Options:**
- `-u` or `--upload` - Upload after build (iOS: App Store, Android: PGYER via pgyer.env)
- `-t` or `--test` - Build test APK (Android, overrides default release APK)
- `-d` or `--debug` - Build debug APK (Android, overrides default release APK)
- `-s` or `--sign` - Build signed AAB for Play Store (Android, overrides default release APK)

**Implicit behaviors (no flags needed):**
- Build number auto-increment is ALWAYS applied automatically (once per invocation)
- Android always builds release APK unless overridden by `-t`, `-d`, or `-s`

## Instructions

### Step 1: Parse Arguments

If `$ARGUMENTS` is empty, ask the user:
1. Which platform? (ios / android / all)
2. Upload after build? (-u)

**Platform `all` with `-u` means:**
- iOS: build IPA + upload to App Store
- Android: build release APK + upload to PGYER

### Step 2: Pre-Build Checks & Version Increment

Before building, ALWAYS perform these steps in order:

#### 2a. Check for uncommitted changes

```bash
cd /Users/ck/Git/pronext/mobile
git status --short
```

If there are uncommitted changes:
- Run `git diff` to review them
- If the changes are safe and minor (no sensitive files, no half-finished work), commit them with a descriptive message summarizing what changed
- If the changes look risky or incomplete, STOP and ask the user how to proceed

#### 2b. Auto-increment build number

Build number is incremented **exactly once** per invocation, regardless of platform:

- **For `ios` or `all`**: Do NOT manually increment. The iOS script's `-i` flag handles it. Skip this step.
- **For `android` only**: Manually increment in pubspec.yaml and commit BEFORE running the build script:

```bash
cd /Users/ck/Git/pronext/mobile
# Read current version from pubspec.yaml
# Increment build number: x.y.z+N → x.y.z+(N+1)
# Update pubspec.yaml
# Commit: "chore: increase build number to x.y.z+(N+1) for Google Play release"
```

### Step 3: Execute Build

**CRITICAL: Build scripts are long-running (10-30 minutes). You MUST use `run_in_background: true` for each build script invocation, then poll with TaskOutput until completion.**

#### For iOS

Run the script in background and wait:

```bash
cd /Users/ck/Git/pronext/mobile

# Without upload (run_in_background: true)
./appstore_release.sh -i

# With upload (run_in_background: true)
./appstore_release.sh -i --upload-now
```

After launching, use `TaskOutput` (with `block: true, timeout: 600000`) to wait for completion. If that times out, keep polling with `TaskOutput` until the script finishes.

**iOS build process (handled by script):**
1. Increments build number in pubspec.yaml and commits
2. Runs `flutter clean` and `flutter pub get`
3. Builds IPA: `flutter build ipa --release`
4. Validates with App Store Connect
5. Optionally uploads to App Store

#### For Android

Run the script in background and wait:

```bash
cd /Users/ck/Git/pronext/mobile

# Default: Release APK — production: api.pronextusa.com (run_in_background: true)
./googleplay_release.sh -a

# Test APK — test environment: api-test.pronextusa.com (run_in_background: true)
./googleplay_release.sh -t

# Debug APK — local: 192.168.31.163:8000 (run_in_background: true)
./googleplay_release.sh -d

# Signed AAB for Google Play Store (run_in_background: true)
./googleplay_release.sh -s
```

After launching, use `TaskOutput` (with `block: true, timeout: 600000`) to wait for completion. If that times out, keep polling with `TaskOutput` until the script finishes.

#### For `all`

Run iOS first, wait for completion, then run Android. **Build number is only incremented once by the iOS script's `-i` flag. Do NOT increment again for Android.**

1. iOS: `./appstore_release.sh -i` or `./appstore_release.sh -i --upload-now` (if `-u`) — `run_in_background: true`, wait for completion
2. Android: `./googleplay_release.sh -a` — `run_in_background: true`, wait for completion (then PGYER upload if `-u`)

### Step 4: Post-Build Tag

After a SUCCESSFUL build, ALWAYS create a git tag:

```bash
cd /Users/ck/Git/pronext/mobile
# Format: v{version}+{build_number}
# Example: v1.5.6+1059
git tag v<version>
git tag  # verify
```

### Step 5: Upload (if -u flag)

#### iOS Upload

Handled by `./appstore_release.sh --upload-now` (already included in Step 3).

#### Android Upload (PGYER)

If `-u` flag is specified for Android builds:

```bash
cd /Users/ck/Git/pronext/mobile

# Read API key from pgyer.env
source pgyer.env

# Upload with buildUpdateDescription = build number
curl -F "file=@<apk_or_aab_path>" \
     -F "_api_key=$API_Key" \
     -F "buildUpdateDescription=<build_number>" \
     https://www.pgyer.com/apiv2/app/upload
```

- `buildUpdateDescription` should be the build number only (e.g., `1059`)
- Report the PGYER short URL from the response: `https://www.pgyer.com/<buildShortcutUrl>`

### Step 6: Report Results

After build completes:

1. Report success or failure
2. Show output file location
3. Show the git tag created
4. If uploaded, show the upload URL
5. Provide next steps for store submission

## Output Locations

| Platform | Type        | Path                                                    |
|----------|-------------|---------------------------------------------------------|
| iOS      | IPA         | `build/ios/ipa/pronext_flutter.ipa`                     |
| Android  | Test APK    | `build/app/outputs/flutter-apk/pronext_test.apk`       |
| Android  | Debug APK   | `build/app/outputs/flutter-apk/pronext_debug.apk`      |
| Android  | Release APK | `build/app/outputs/flutter-apk/pronext_release.apk`    |
| Android  | Signed AAB  | `build/app/outputs/bundle/release/pronext_production.aab` |

## Version Format

`pubspec.yaml` version: `x.y.z+build` (e.g., `1.4.3+1403`)

Build number is auto-incremented once per invocation: `1.4.3+1403` → `1.4.3+1404`
