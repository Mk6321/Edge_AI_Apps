# Lightweight Baby

Lightweight Baby is a minimal Flutter Android application for offline mobile inference with LiquidAI's `LFM2-VL-450M` multimodal model.

## Overview

The app is designed for practical device testing:

- text-to-text chat
- image-to-text prompts
- one-time model download
- offline usage after setup
- simple mobile-first chat interface

## Model Files

The runtime expects these GGUF assets:

- `LFM2-VL-450M-Q4_0.gguf`
- `mmproj-LFM2-VL-450M-Q8_0.gguf`

They are downloaded by the app on first launch and stored locally on the device.

## Tech Stack

- Flutter
- Dart
- `llamadart`
- `image_picker`
- `path_provider`

## Target Platform

- Android only
- `arm64-v8a`
- minimum SDK 26

## Run Locally

```bash
flutter pub get
flutter run --release
```

## Build APK

```bash
flutter build apk --release
```

Output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Notes

The app keeps the interface intentionally simple. The model is loaded after setup so the application opens more safely on a broader set of Android devices.
