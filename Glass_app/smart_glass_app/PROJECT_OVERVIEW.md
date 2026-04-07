# Smart Glass App Project Overview

This document is the up-to-date project memory for `smart_glass_app`.
It reflects the current Flutter app architecture in this repository.

## 1. What This Project Does

The Smart Glass App is a Flutter-based mobile application designed as an
offline-first, voice-controlled spatial awareness assistant for visually
impaired users.

The phone connects to an ESP32-CAM wearable, captures an image from the camera,
and then performs one of two paths:

- Gemini path for scene description, OCR, and currency detection
- On-device path for face registration and face recognition

The app supports these core tasks:

- Describe the environment, for example: "What is in front of me?"
- Read visible text, for example: "Read the sign"
- Detect money, for example: "What denomination is this note?"
- Register a face locally, for example: "Remember this person as John"
- Recognize known faces locally, for example: "Who is this?"

## 2. Key Architecture Milestone

This project originally used a Python Flask backend plus ngrok tunneling.
That is no longer the active architecture for the mobile app.

The current production path inside `smart_glass_app` is:

- Gemini calls happen directly from Flutter through `google_generative_ai`
- Face detection and face recognition happen fully on the phone
- No laptop server is required for the current app flow

The legacy `backend/` folder still exists in the repository, but it should be
treated as historical code unless the team explicitly revives it.

## 3. Technology Stack

### Flutter and Dart

The application is written in Flutter and Dart and targets mobile platforms.

### `google_generative_ai`

Used to send an image plus prompt directly from the app to Gemini
`gemini-2.5-flash` for:

- environment descriptions
- OCR
- currency detection

### `google_mlkit_face_detection`

Used as the first stage of the face pipeline to detect faces in the captured
image and locate the best face bounding box for cropping.

### `tflite_flutter`

Used to run the bundled `mobilefacenet.tflite` model locally on the device.
The model outputs a 192-dimensional face embedding vector.

### `speech_to_text`

Used to listen to the user and convert spoken commands into text so the app can
route them locally.

### `flutter_tts`

Used to speak responses, prompts, and status messages back to the user.

### `http`

Used to fetch a JPEG frame from the ESP32-CAM over the local network.

### `path_provider` and `image`

Used for file storage, temp files, image decoding, cropping, resizing, and
persisting the local face vault.

### `flutter_background_service`

Used to keep the app alive with a foreground service notification on supported
mobile platforms.

## 4. High-Level File Map

- `lib/main.dart`: app bootstrap and early permission/background setup
- `lib/screens/home_screen.dart`: UI, state machine, voice routing, and workflow orchestration
- `lib/services/api_service.dart`: ESP32 capture + Gemini direct SDK integration
- `lib/services/face_service.dart`: ML Kit detection, MobileFaceNet embeddings, vault persistence
- `lib/services/background_service.dart`: foreground service configuration
- `assets/models/mobilefacenet.tflite`: bundled face embedding model

## 5. Initialization Flow

### `main.dart`

At startup the app:

- initializes Flutter bindings
- starts the background service on Android and iOS
- requests microphone permission
- launches `HomeScreen`

### `home_screen.dart`

When the screen initializes it:

- initializes speech-to-text
- initializes text-to-speech
- requests microphone, camera, and speech permissions
- initializes the Gemini service
- initializes the face service
- moves the UI into the idle ready state

The app uses this state machine:

- `idle`
- `listening`
- `awaitingDescription`
- `processing`

## 6. Voice Router

The main control flow lives in `home_screen.dart`.
The user taps the microphone button, speaks, and the transcript is routed
locally before any remote model call is made.

### Face registration branch

The app looks for registration-style phrases such as:

- `mark`
- `save`
- `remember`
- `register`
- `store`
- `add`

combined with face-related words like:

- `person`
- `face`
- `this is`
- `him`
- `her`
- `as`

If matched, the app:

1. extracts the name from the transcript
2. asks for an optional spoken description
3. captures a frame
4. detects and crops a face
5. generates an embedding
6. saves the person into the local face vault

### Face recognition branch

The app also looks for recognition phrases such as:

- `who is this`
- `recognize this person`
- `identify this face`
- `do you recognize`

If matched, the app captures a frame and runs the on-device recognition path.

### Gemini branch

Any other spoken request falls through to the Gemini vision path.
This keeps most command routing local and avoids unnecessary remote calls.

## 7. Gemini Vision, OCR, and Currency Pipeline

This flow is implemented in `lib/services/api_service.dart`.

### Step 1: Capture

The app requests an image from the ESP32-CAM using:

- `http://10.235.89.20/capture`

The app expects a JPEG response body.

### Step 2: Prompt selection

The spoken query is analyzed locally.
`ApiService` chooses one of three system prompts:

- scene description prompt
- OCR prompt
- currency detection prompt

The current routing logic is keyword-based:

- money-related words such as `rupee`, `currency`, `cash`, `note`, `coin` choose the currency prompt
- reading-related words such as `read`, `text`, `sign`, `written` choose the OCR prompt
- everything else uses the general scene-description prompt

### Step 3: Gemini call

The app sends:

- the selected text prompt
- the user query
- the captured JPEG bytes

directly to Gemini `gemini-2.5-flash`.

### Step 4: Spoken response

The model response is displayed in the UI and spoken aloud with TTS.

## 8. Offline Face Pipeline

This flow is implemented in `lib/services/face_service.dart`.
It is fully local and does not rely on a backend.

### Stage 1: Face detection and crop

Google ML Kit scans the captured image.

- If no faces are found, the pipeline stops early.
- If multiple faces are found, the largest face is selected.
- The bounding box is clamped to image bounds.
- The face is cropped and written to a temp JPEG file.

### Stage 2: Face embedding

The cropped face is:

- decoded
- resized to `112 x 112`
- normalized to `[-1, 1]`
- sent into `mobilefacenet.tflite`

The model returns a 192-dimensional embedding vector.
The embedding is then L2-normalized.

### Recognition

For recognition, the app:

- compares the live embedding with every stored embedding
- uses Euclidean distance
- picks the smallest distance
- accepts a match only if the distance is below `1.0`

If a match is found, the app speaks the stored name and optional description.
If not, it reports that it sees a person but does not recognize them.

### Registration

For registration, the app stores:

- metadata in `face_vault.json`
- embeddings in `face_embeddings.json`
- cropped face images in the app documents directory under `faces/<name>/`

Each person can have multiple stored embeddings and multiple saved cropped
images.

## 9. Hardware and Network Details

The phone and the ESP32-CAM must be on the same Wi-Fi or hotspot network.

The capture endpoint is currently hardcoded in `ApiService` as:

- `10.235.89.20`

If the device IP changes, the app code must be updated or refactored to make
the endpoint configurable.

## 10. Security and Practical Limitations

### Embedded Gemini API key

The Gemini API key is embedded directly in the mobile client.
That can be acceptable for a personal or internal accessibility prototype, but
it is a security and billing risk for a public release because client apps can
be reverse engineered.

### Network dependency

Face recognition and registration do not require a backend.
Gemini-powered scene understanding, OCR, and currency detection do require
network access to reach the Gemini API.

Speech-to-text and text-to-speech depend on the device speech engines and may
vary by platform, language pack availability, and device configuration.

### Hardcoded camera endpoint

The current ESP32 capture URL is fixed in code.
That is simple for testing, but it is fragile when moving across networks.

## 11. Current Truth Summary

If a new developer needs the shortest accurate summary of the app, it is this:

- Flutter app
- ESP32-CAM image capture over local HTTP
- Gemini direct from Flutter for scene, OCR, and currency
- ML Kit plus MobileFaceNet on-device for faces
- No active Flask backend in the current mobile flow
