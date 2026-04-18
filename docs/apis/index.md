# Pronext Docs

## How Your App's Auto-Update System Works

- Your app implements an auto-update system through the UpdateManager class. Here's how it works:
- Update Check: The app periodically calls the server endpoint common/check_update to check for updates.
Update Information: If an update is available, the server returns an UpdateInfo object containing an apk_url that points to the new APK.
- Download Process: When an update is available, the app:
- Downloads the APK file from the provided URL
- Saves it to the device's cache directory
- Attempts to install it using the shell command pm install -r [path_to_apk]
- Update Schedule: The update check is performed:
- Every 5 seconds when in the check page
- Every 3 minutes (180 seconds) during normal app usage

## app/src/build.gradle.kts

The build.gradle.kts file is the Kotlin-based build configuration file for an Android application. It defines how the project is built, dependencies, and various configuration options. Let me explain its key components:

**Key Functions**

- Project Configuration: Defines project-wide settings and properties
- Dependency Management: Manages external libraries and internal module dependencies
- Build Configuration: Controls build variants, signing, and compilation options
- Feature Enablement: Toggles Compose and other Android features
- Resource Management: Configures resource handling and packaging
