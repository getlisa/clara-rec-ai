## Clara-Assistant

Companion apps for Ray-Ban Meta smart glasses, on **Android** and **iOS**. See a live view from the glasses camera, record it to video with audio, and get AI analysis of what you're looking at.

Built on the [Meta Wearables Device Access Toolkit](https://wearables.developer.meta.com/docs/getting-started-toolkit) (DAT).

> [!NOTE]
> **Developer Mode** must be enabled in the **Meta AI** app before the glasses will accept a connection — separately on each phone. See [Detailed setup](#detailed-setup).

> [!IMPORTANT]
> Both apps are built from source. There is no store release, and the Meta SDK is distributed through GitHub Packages (Android) and Swift Package Manager (iOS). Android additionally requires a GitHub token.

| | Android | iOS |
|---|---|---|
| Source | [`android/`](android/) | [`ios/`](ios/) |
| Language | Kotlin + Jetpack Compose | Swift + SwiftUI |
| Minimum OS | Android 12 (API 31) | iOS 17.2 |
| Live view | Yes | Yes |
| Recording | Video + **phone** mic | Video + **glasses** mic (HFP) |
| Recordings saved to | `Movies/Clara-Assistant` (Gallery) | `Clara-Assistant` album (Photos) |
| Picture analysis | Yes (OpenAI) | Not yet |
| History | Yes | Not yet |

## Features

### 🎥 Live view
Streams the glasses camera to your phone in real time. Video quality (low / medium / high) is configurable in Settings; the link is Bluetooth, so lower settings are more reliable.

### 🔴 Recording
Records the live view to a file on your phone, browsable from the **Clips** tab and visible in your normal gallery app.

The two platforms differ in how video is handled, because the SDKs differ:

- **iOS** requests compressed HEVC (`hvc1`) and writes it **passthrough** — frames are muxed without being decoded or re-encoded.
- **Android** receives raw I420 frames and encodes them to H.264 with `MediaCodec`.

### 🎙️ Audio
Audio is **not** part of the DAT camera stream — the SDK exposes no audio API on either platform. It has to be captured separately:

- **iOS** captures the **glasses microphone** over Bluetooth Hands-Free Profile, by declaring `.allowBluetoothHFP` on the audio session and letting iOS route input to the glasses. Falls back to the phone mic when the glasses are absent. HFP is voice-grade (8/16 kHz), so speech is clear but ambient audio is not hi-fi.
- **Android** currently records the **phone microphone**. Routing to the glasses would mean driving Bluetooth SCO manually; the conversation feature already does this, but the recorder does not yet.

Denying the microphone permission is not fatal on either platform — recording continues without audio.

### 📸 Photos
Takes a still through the glasses. The two platforms reach it differently:

- **Android** — a dedicated **Picture analysis** screen: a 3-2-1 countdown, then the photo is described aloud by OpenAI.
- **iOS** — a shutter button in the live view, capturing a JPEG straight off the running stream.

### ☁️ Cloud backup (optional)
Captured photos can additionally be uploaded to an **S3 bucket**, namespaced per author, so several people testing the app never overwrite each other:

```
photos/shivam-a1b2c3d4/2026/09/22/20260922-143012-c0e9785f45dc.jpg
       └── author ───┘ └─ date ─┘ └─ time ─┘ └─ content hash ┘
```

Each install generates a stable author id on first use; an optional author name (Settings → Cloud backup) is slugified in front of it. The id is always present, so two people who pick the same name never collide. Objects also carry `x-amz-meta-author-id`, `-author-name` and `-captured-at`.

Leave the credentials unset and the feature stays off — photos then never leave the phone. Setup and the required least-privilege IAM policy: [Android](android/README.md#image-upload-to-s3) · [iOS](#image-upload-to-s3-ios).

### 🕘 History (Android)
Transcripts of past conversation sessions.

## Requirements

- Ray-Ban Meta smart glasses, powered on and worn
- The **Meta AI** app, with **Developer Mode** enabled, on the phone you are testing from
- Glasses paired and connected in that Meta AI app
- An [OpenAI API key](https://help.openai.com/en/articles/4936850-where-do-i-find-my-openai-api-key) for the AI features
- Android: a GitHub token with `read:packages`; iOS: Xcode 16+ and an Apple developer account

> [!NOTE]
> Glasses pair to **one phone's Meta AI app at a time**. Testing the iOS app means moving them off the Android phone, and vice versa.

## Building — Android

### Prerequisites
- Android Studio (latest stable), Android SDK + Platform Tools
- **JDK 17** — newer JDKs are not compatible with this project's Gradle version

### Configure `android/local.properties`

The Meta SDK is served from GitHub Packages, which requires authentication even for public packages. Create a [personal access token](https://github.com/settings/tokens) (classic) with `read:packages`. This file is gitignored — never commit it.

```properties
sdk.dir=/path/to/Android/sdk
github_token=YOUR_GITHUB_TOKEN

# Optional: also settable in the app's Settings screen
OPENAI_API_KEY=YOUR_OPENAI_KEY
OPENAI_MODEL=gpt-4o
```

### Build and install

```bash
cd android
export JAVA_HOME=/path/to/jdk-17
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Instrumented tests for the video encoder need a connected device:

```bash
./gradlew :app:connectedDebugAndroidTest
```

## Building — iOS

The Xcode project is **generated** from [`ios/project.yml`](ios/project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen), so it is not committed. Install it once with `brew install xcodegen`.

```bash
cd ios
xcodegen generate          # creates ClaraAssistant.xcodeproj
open ClaraAssistant.xcodeproj
```

Set your own signing team in `project.yml` (`DEVELOPMENT_TEAM`) and bundle identifier before building to a device.

From the command line:

```bash
cd ios
xcodebuild -project ClaraAssistant.xcodeproj -scheme ClaraAssistant \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <device-id> \
  "$(find ~/Library/Developer/Xcode/DerivedData/ClaraAssistant-*/Build/Products/Debug-iphoneos \
      -maxdepth 1 -name 'ClaraAssistant.app' | head -1)"
```

`xcrun devicectl list devices` prints the device id. The device must be **unlocked** during install.

### Image upload to S3 (iOS)

Optional — skip it and photos stay on the device. Copy the template and fill it in:

```bash
cd ios
cp Secrets.example.plist ClaraAssistant/Secrets.plist
xcodegen generate
```

`ClaraAssistant/Secrets.plist` is gitignored. A plist rather than an `.xcconfig` because xcconfig
treats `//` as a comment and AWS secret keys can legitimately contain it.

| Key | Notes |
| --- | --- |
| `S3_BUCKET` | Must not contain a dot — that breaks TLS for virtual-hosted-style S3 URLs, and the app rejects it up front |
| `AWS_REGION` | Defaults to `us-east-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | |
| `AWS_SESSION_TOKEN` | Only for temporary STS credentials |

**Anything in the app bundle is readable by anyone who unzips the IPA**, so the IAM user must be
able to do nothing else. `s3:PutObject` alone means a leaked key can add objects but cannot read,
list or delete:

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

Enable bucket versioning so a leaked key cannot overwrite existing objects, and keep public access
blocked. For anything beyond prototyping, move the credentials out of the app: have a small backend
hand out pre-signed `PUT` URLs, or use a Cognito identity pool.

### Tests (iOS)

The AWS SigV4 signer and the author-prefix rules run as logic tests, with no host app and no
glasses needed:

```bash
cd ios
xcodebuild test -project ClaraAssistant.xcodeproj -scheme ClaraAssistantTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

They assert the same vectors as the Android suite — AWS's published "PUT Object" example plus
botocore-generated ones — so the two platforms cannot drift apart. A wrong signature otherwise
surfaces only as an opaque S3 `403`.

### Meta app registration

The app runs in **developer mode**, which needs no Wearables Developer Center account: `Info.plist` sets `MWDAT` → `MetaAppID` to `0`, alongside the app's URL scheme and your Apple `TeamID`. Shipping outside developer mode would require a registered app ID and client token from the Wearables Developer Center.

## Detailed setup

> [!WARNING]
> **Developer Mode is required**, per phone. The glasses will not connect to third-party apps without it.
>
> 1. Open the **Meta AI** app
> 2. Go to **Settings** → **App Info**
> 3. Tap the **App version** number **five times quickly**
> 4. Enable **Developer Mode** and confirm
>
> <img src="docs/images/meta-view-develop-mode.png" alt="Meta AI Developer Mode" width="50%" />
>
> See the [Meta Wearables Setup Guide](https://wearables.developer.meta.com/docs/getting-started-toolkit) for details.

Then, in Clara-Assistant:

1. Allow the nearby devices / Bluetooth permission.
2. Open **Settings** and tap **Connect my glasses**, then approve in the Meta AI app.
3. Check that the glasses appear as **connected** and **compatible**.
4. On iOS, allow **local network** access when prompted — the glasses are reached over it, and discovery silently fails without it.
5. Add your OpenAI API key (Android) and grant the microphone permission the first time you record.

> [!TIP]
> If streaming stalls or Bluetooth drops on Android, disable battery restrictions:
> `Settings → Battery → Clara-Assistant → Battery Saver → No restrictions`

## Troubleshooting

- **`noEligibleDevice` / "no eligible device"** — the glasses are known but not usable: check they are connected in the Meta AI app *on this phone*, unfolded and worn, and reported as compatible in Settings.
- **iOS: nothing found on the local network** — the permission is only requested when the app first attempts discovery, so it appears under Settings → Privacy & Security → Local Network only after a streaming attempt.
- **Android: `Could not resolve com.meta.wearable:mwdat-*`** — the `github_token` is missing, expired, or lacks `read:packages`.
- **Android: Gradle fails with `NoRouteToHostException`** — the daemon is trying IPv6 on a network without working IPv6. Add to `~/.gradle/gradle.properties`:
  `org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8 -Djava.net.preferIPv4Stack=true`
- **Android: random `UnknownHostException` during dependency resolution** — the DNS resolver is dropping concurrent lookups; a public resolver (1.1.1.1 / 8.8.8.8) fixes it.

## Privacy

- Images and audio are sent to OpenAI only for AI processing, using your own account and API key.
- Your OpenAI API key is stored locally on the device and is never logged.
- **Video recordings** stay on the device and are never uploaded.
- **Photos** stay on the device too, unless you configure an S3 bucket of your own — see [Cloud backup](#️-cloud-backup-optional). The credentials and the bucket are yours; there is no server operated by this project.
- API communication uses HTTPS.

## Credits

Forked from [meta-lens-ai](https://github.com/przemek-nowicki/meta-lens-ai) by Przemek Nowicki.

The Meta Wearables Device Access Toolkit is covered by [Meta's Developer Terms](https://wearables.developer.meta.com/terms), not an open-source licence.

## License

This project is licensed under the [MIT License](LICENSE).
