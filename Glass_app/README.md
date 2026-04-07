# AI Smart Glass Assistive System

This folder contains the Smart Glass project assets and the active Flutter app
used as a voice-controlled assistive vision tool for visually impaired users.

## Current Status

The active mobile path is `smart_glass_app/`.
That app now uses:

- direct Gemini calls from Flutter for scene description, OCR, and currency detection
- on-device face recognition with ML Kit + MobileFaceNet
- ESP32-CAM image capture over local HTTP

The old `backend/` folder is legacy prototype code from the earlier Flask/ngrok
architecture and is not required for the current `smart_glass_app` flow.

## Directory Structure

- `smart_glass_app/`: active Flutter mobile application
- `backend/`: legacy backend prototype and historical assets

## Quick Start

1. Navigate to `smart_glass_app/`.
2. Make sure Flutter is installed and your Android device is connected.
3. Ensure the ESP32-CAM is reachable on the same Wi-Fi or hotspot network.
4. Run `flutter pub get`.
5. Run `flutter run`.

## Hardware Assumption

The current Flutter app fetches frames from:

- `http://10.235.89.20/capture`

That endpoint is hardcoded in `smart_glass_app/lib/services/api_service.dart`.

## Documentation

See `smart_glass_app/README.md` for the active app summary and
`smart_glass_app/PROJECT_OVERVIEW.md` for the detailed architecture memory.
