# Clara-Assistant (Android)

Android companion app for Ray-Ban Meta smart glasses, built on the Meta Wearables Device Access Toolkit.

See the [repository README](../README.md) for features and setup; this file covers building and running.

## Prerequisites
- Android Studio (latest stable)
- Android SDK + Platform Tools (installed via Android Studio)
- JDK 17 — newer JDKs are not compatible with this project's Gradle version

## Configure `local.properties`

This project pulls `meta-wearables-dat-android` from GitHub Packages, which requires authentication
even for public packages. Gradle reads the token from the `GITHUB_TOKEN` environment variable or from
`android/local.properties`. Create a [personal access token](https://github.com/settings/tokens)
(classic) with the `read:packages` scope.

`local.properties` is gitignored — never commit it.

```properties
sdk.dir=/path/to/Android/sdk
github_token=YOUR_GITHUB_TOKEN

# Optional: needed only for the AI features. Can also be set in the app's Settings screen.
OPENAI_API_KEY=YOUR_OPENAI_KEY
OPENAI_MODEL=gpt-4o
```

More details: https://github.com/facebook/meta-wearables-dat-android

## Run in Android Studio (recommended)
1. Open Android Studio.
2. Click **Open** and select the `android/` folder in this repo (not the repository root).
3. Let Gradle sync finish.
4. Connect a device running Android 12+, or start an emulator via **Tools → Device Manager**.
5. Click **Run**.

Note that the glasses features need real hardware; an emulator can only run the UI.

## Run from the command line

```bash
cd android
export JAVA_HOME=/path/to/jdk-17
./gradlew :app:installDebug
```

Over a slow adb connection, building and installing separately is noticeably faster:

```bash
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Tests

Instrumented tests cover the video encoder and need a connected device or emulator:

```bash
./gradlew :app:connectedDebugAndroidTest
```

## Troubleshooting

- **Gradle cannot find Java** — set `JAVA_HOME` to your JDK 17 path. A JDK newer than 17 will fail.
- **Android SDK not found** — set `sdk.dir` in `local.properties`, or `ANDROID_HOME` in your environment.
- **`Could not resolve com.meta.wearable:mwdat-*`** — your `github_token` is missing, expired, or lacks
  the `read:packages` scope.
- **Downloads fail with `NoRouteToHostException`** — the Gradle daemon is trying IPv6 on a network
  without working IPv6 routing. Add this to `~/.gradle/gradle.properties`:
  `org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8 -Djava.net.preferIPv4Stack=true`
- **Downloads fail with `UnknownHostException` at random dependencies** — the DNS resolver is dropping
  concurrent lookups. Switching to a public resolver (1.1.1.1 / 8.8.8.8) fixes it.
