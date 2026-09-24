# Clara-Assistant (Android)

Android companion app for Ray-Ban Meta smart glasses, built on the Meta Wearables Device Access Toolkit.

See the [repository README](../README.md) for features and setup; this file covers building and running.

## Prerequisites
- Android Studio (latest stable)
- Android SDK + Platform Tools (installed via Android Studio)
- JDK 17 or 21 — JDK 25 fails this project's Gradle/AGP version with a bare `25.0.3` error

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

## Image upload to S3

Photos captured in **Picture Analysis** can additionally be archived to an S3 bucket. Leave these
blank and the feature stays off — photos then never leave the phone.

```properties
S3_BUCKET=my-clara-photos
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
# Only for temporary STS credentials:
AWS_SESSION_TOKEN=
```

Bucket names containing a dot are rejected: they break TLS certificate matching for the
virtual-hosted-style URLs the uploader uses.

### Objects are namespaced per author

The app has no accounts, so each install generates a stable 8-character author id on first use.
An optional **author name**, set in Settings → Cloud backup, is slugified onto the front of it:

```
photos/shivam-a1b2c3d4/2026/09/22/20260922-143012-c0e9785f45dc.jpg
       └── author ───┘ └─ date ─┘ └─ time ─┘ └─ content hash ┘
```

The id is always part of the prefix, so two people who pick the same name never collide. Each
object also carries `x-amz-meta-author-id`, `x-amz-meta-author-name` and `x-amz-meta-captured-at`.
Renaming yourself only affects future uploads; existing objects keep the prefix they were written
with, which is why the id — not the name — is the identity.

### Least-privilege IAM policy

Credentials compiled into an APK are readable by anyone who obtains the APK, so the IAM user must
be able to do nothing else. `s3:PutObject` alone means a leaked key can add objects but cannot
read, list or delete anything:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::my-clara-photos/photos/*"
  }]
}
```

Enable bucket versioning so an attacker with the key cannot overwrite existing objects, and keep
public access blocked. For anything beyond prototyping, move the credentials out of the app: have
a small backend hand out pre-signed `PUT` URLs, or use a Cognito identity pool, so the app never
holds a long-lived secret.

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

Unit tests cover the AWS SigV4 signer and author-prefix rules, and run on the JVM:

```bash
./gradlew :app:testDebugUnitTest
```

The signer is pinned to AWS's own published "PUT Object" example plus vectors generated with
botocore, because a wrong signature surfaces only as an opaque S3 `403`.

Instrumented tests cover the video encoder and need a connected device or emulator:

```bash
./gradlew :app:connectedDebugAndroidTest
```

## Troubleshooting

- **The build fails with only a version number as the message** (e.g. `What went wrong: 25.0.3`) —
  AGP cannot parse that JDK version. Point `JAVA_HOME` at a JDK 17 or 21 install:
  `export JAVA_HOME=$(/usr/libexec/java_home -v 21)`
- **Android SDK not found** — set `sdk.dir` in `local.properties`, or `ANDROID_HOME` in your environment.
- **`Could not resolve com.meta.wearable:mwdat-*`** — your `github_token` is missing, expired, or lacks
  the `read:packages` scope.
- **Downloads fail with `NoRouteToHostException`** — the Gradle daemon is trying IPv6 on a network
  without working IPv6 routing. Add this to `~/.gradle/gradle.properties`:
  `org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8 -Djava.net.preferIPv4Stack=true`
- **Downloads fail with `UnknownHostException` at random dependencies** — the DNS resolver is dropping
  concurrent lookups. Switching to a public resolver (1.1.1.1 / 8.8.8.8) fixes it.
