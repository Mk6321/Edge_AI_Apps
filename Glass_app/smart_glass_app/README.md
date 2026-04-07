# Smart Glass App

`smart_glass_app` is a Flutter mobile application that acts as an offline-first,
voice-controlled spatial awareness assistant for visually impaired users.
It pairs with an ESP32-CAM, captures an image on demand, and then either:

- sends the frame to Gemini for scene understanding, OCR, or currency reading
- processes the frame fully on-device for face registration and recognition

## Current Architecture

This app no longer depends on the old Flask + ngrok + laptop backend.
The active architecture is:

- `lib/services/api_service.dart`: captures from ESP32-CAM and calls Gemini directly with `google_generative_ai`
- `lib/services/face_service.dart`: runs the on-device face pipeline with ML Kit + MobileFaceNet TFLite
- `lib/screens/home_screen.dart`: voice router, UI state machine, and orchestration logic
- `lib/services/background_service.dart`: Android/iOS background service bootstrap
- `assets/models/mobilefacenet.tflite`: bundled face embedding model

The parent `backend/` folder is now legacy project history, not the active app path.

## What The App Can Do

- Describe the environment from an ESP32-CAM snapshot
- Read visible text from signs, labels, or documents
- Detect currency denomination with a stricter prompt path
- Register a person locally by name and spoken description
- Recognize previously registered faces completely on-device
- Listen for a wake word in the background and open into question-listening mode
- Attach a photo from the phone's back camera and ask questions about that image

## Runtime Flow

1. The app starts, requests permissions, initializes the background service, Gemini client, and face engine.
2. The user taps the mic button and speaks a command.
3. `home_screen.dart` routes the transcript locally with regex matching.
4. Face commands go to the offline face pipeline.
5. All other vision requests go to Gemini with the live ESP32-CAM frame.
6. The result is spoken back through text-to-speech.

## Face Pipeline

Face processing stays on the phone:

- Stage 1: Google ML Kit detects the face and crops the largest face from the image.
- Stage 2: MobileFaceNet converts the crop into a normalized 192-dimensional embedding.
- Registration stores metadata in `face_vault.json`, embeddings in `face_embeddings.json`, and cropped images under the app documents directory.
- Recognition compares the live embedding with stored embeddings using Euclidean distance and a threshold of `< 1.0`.

## Gemini Vision Pipeline

`ApiService` fetches a JPEG from the hardcoded ESP32 endpoint:

- `http://10.235.89.20/capture`

It then selects one of three prompt modes based on the spoken query:

- general scene description
- OCR / text extraction
- currency detection

The selected prompt and image bytes are sent directly to `gemini-2.5-flash`.

## Important Notes

- Gemini features require network access and a valid embedded API key.
- Face recognition works without a backend and keeps face data on-device.
- Speech recognition and text-to-speech behavior depend on the device speech engines and platform support.
- The Gemini API key is embedded in the client, which is acceptable for personal testing but not ideal for a public release.
- Wake word detection uses Picovoice Porcupine and requires `PICOVOICE_ACCESS_KEY` via `--dart-define`.
- Without a custom `.ppn` asset, the wake word falls back to built-in `Jarvis`. For exact `Hey Jarvis`, provide a custom keyword asset through `PICOVOICE_KEYWORD_ASSET`.

## Docs

For the detailed inch-by-inch project memory, see [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md).
