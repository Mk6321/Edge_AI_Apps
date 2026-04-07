import os
import sys
import json
import base64
import logging
import pickle
import time
import cv2
import numpy as np
from flask import Flask, request, jsonify
from pyngrok import ngrok
from ultralytics import YOLO
import face_recognition
from google import genai
from google.genai import types
from PIL import Image
import io

# =============================================================================
# FLASK APP INIT
# =============================================================================
app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = app.logger

# Global variable to store ngrok URL
public_url = None

# =============================================================================
# GOOGLE GEMINI 1.5 FLASH — General Vision "Brain"
# Uses the new google-genai SDK (google.genai), replacing the deprecated
# google.generativeai package.
# =============================================================================
GEMINI_API_KEY = "AIzaSyBp4174f49EbKRqJZF2bKALKKyWUJb58Eg"
GEMINI_MODEL   = "gemini-2.5-flash"

try:
    logger.info("Configuring Google Gemini 1.5 Flash (google-genai SDK)...")
    gemini_client = genai.Client(api_key=GEMINI_API_KEY)
    logger.info("Gemini client initialized successfully.")
except Exception as e:
    logger.error(f"Failed to initialize Gemini: {e}")
    sys.exit(1)


# =============================================================================
# LEGACY MODELS (Preserved but Unused)
# Kept for reference. Kimi now acts as the "Eye and Brain".
# =============================================================================
USE_LEGACY_MODELS = False

if USE_LEGACY_MODELS:
    try:
        logger.info("Loading YOLO11 Nano model...")
        detection_model = YOLO("yolo11n.pt")
        logger.info("YOLO11 Nano loaded successfully.")
    except Exception as e:
        logger.error(f"Failed to load YOLO model: {e}")

    try:
        logger.info("Initializing PaddleOCR...")
        ocr_model = PaddleOCR(use_textline_orientation=True, lang='en')
        logger.info("PaddleOCR initialized successfully.")
    except Exception as e:
        logger.error(f"Failed to initialize PaddleOCR: {e}")


# =============================================================================
# FACE RECOGNITION CONFIGURATION
# =============================================================================

# Path where face encodings (128-d numpy arrays) are stored as a .pkl dict:
#   { "David": [np.array(...)], "Kavya": [np.array(...)] }
ENCODINGS_PATH = os.path.join(os.path.dirname(__file__), "face_encodings.pkl")
DATASET_DIR    = os.path.join(os.path.dirname(__file__), "dataset")

# Central JSON database — stores name, description and image paths per person.
# Format: { "David": { "description": "...", "images": ["path1", "path2"] }, ... }
FACES_DB_PATH  = os.path.join(os.path.dirname(__file__), "faces_database.json")


# =============================================================================
# UTILITY — FACES JSON DATABASE
# =============================================================================

def load_faces_db() -> dict:
    """Loads the faces_database.json or returns an empty dict if not found."""
    if os.path.exists(FACES_DB_PATH):
        try:
            with open(FACES_DB_PATH, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Failed to load faces_database.json: {e}")
    return {}


def save_faces_db(db: dict) -> None:
    """Persists the faces_database.json to disk."""
    try:
        with open(FACES_DB_PATH, 'w', encoding='utf-8') as f:
            json.dump(db, f, indent=2, ensure_ascii=False)
        logger.info(f"faces_database.json saved ({len(db)} people registered).")
    except Exception as e:
        logger.error(f"Failed to save faces_database.json: {e}")

# ---------------------------------------------------------------------------
# IMAGE QUALITY THRESHOLDS
#
# BLUR_THRESHOLD (100):
#   The Laplacian operator measures the second derivative of pixel intensity.
#   A sharp image has rapid intensity changes near edges → high variance.
#   A blurry image has smooth gradients → low variance.
#   Empirically, variance < 100 indicates an image too blurry for reliable
#   face encoding extraction. Increase this value in brighter / higher-res
#   cameras; decrease it if too many good images are being rejected.
#
# Face count: we require exactly 1 face in registration images to guarantee
#   the encoding belongs to the person being named (not a bystander).
# ---------------------------------------------------------------------------
BLUR_THRESHOLD = 100
FACE_RECOGNITION_TOLERANCE = 0.50  # Lower = stricter. dlib default is 0.6.


# =============================================================================
# UTILITY — BASE64 → OpenCV NUMPY ARRAY
# =============================================================================

def decode_base64_image(b64_string: str) -> np.ndarray | None:
    """
    Decodes a base64-encoded JPEG string to an OpenCV BGR numpy array.
    Returns None if decoding fails.
    """
    try:
        img_bytes = base64.b64decode(b64_string)
        np_arr = np.frombuffer(img_bytes, dtype=np.uint8)
        img_bgr = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        return img_bgr
    except Exception as e:
        logger.error(f"Base64 decode error: {e}")
        return None


# =============================================================================
# PHASE 2 — IMAGE QUALITY THRESHOLDING
# =============================================================================

def check_image_quality(image_bgr: np.ndarray) -> tuple[bool, str]:
    """
    Validates that an image is sharp enough and contains exactly one face.

    Steps:
      1. Convert to greyscale for Laplacian blur detection.
      2. Compute Laplacian variance — a measure of edge sharpness.
         Formula: var(∇²I) where ∇² is the discrete Laplacian kernel.
         Low variance (<BLUR_THRESHOLD) → blurry image → reject.
      3. Convert BGR → RGB (face_recognition expects RGB).
      4. Detect face bounding boxes using face_recognition (HOG model by
         default; fast enough for per-request use).
         - 0 faces → no subject in frame.
         - >1 face → ambiguous; we cannot know which person to register.

    Returns:
        (True, "")          — image passes all checks.
        (False, reason_str) — image fails; reason_str is TTS-ready.
    """
    # --- Blur detection ---
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    laplacian_variance = cv2.Laplacian(gray, cv2.CV_64F).var()
    logger.info(f"Laplacian variance (blur score): {laplacian_variance:.2f}")

    if laplacian_variance < BLUR_THRESHOLD:
        return (False,
                "The image is too blurry. Please hold still and try again.")

    # --- Face count validation ---
    image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    face_locations = face_recognition.face_locations(image_rgb)
    face_count = len(face_locations)
    logger.info(f"Faces detected in quality check: {face_count}")

    if face_count == 0:
        return (False,
                "No face was detected in the image. Please position the camera "
                "so that the person's face is clearly visible and try again.")

    if face_count > 1:
        return (False,
                f"{face_count} faces detected. For registration, please make "
                "sure only one person is in front of the camera and try again.")

    return (True, "")


# =============================================================================
# HELPER — Load / Save encodings PKL
# =============================================================================

def load_encodings() -> dict:
    """Loads the face encodings dict from disk. Returns {} if not found."""
    if os.path.exists(ENCODINGS_PATH):
        with open(ENCODINGS_PATH, "rb") as f:
            return pickle.load(f)
    return {}


def save_encodings(encodings: dict) -> None:
    """Persists the face encodings dict to disk."""
    with open(ENCODINGS_PATH, "wb") as f:
        pickle.dump(encodings, f)


# =============================================================================
# NGROK TUNNEL
# =============================================================================

def start_ngrok():
    """Starts ngrok tunnel on port 5000 and returns the public HTTPS URL."""
    global public_url
    try:
        if os.name == 'nt':
            os.system("taskkill /f /im ngrok.exe >nul 2>&1")

        tunnel = ngrok.connect(5000)
        public_url = tunnel.public_url.replace("http://", "https://")
        logger.info(f" * Ngrok Tunnel Started: {public_url}")
        return public_url
    except Exception as e:
        logger.error(f"Failed to start ngrok: {e}")
        return None


# =============================================================================
# ROUTE — GET /server-url
# =============================================================================

@app.route('/server-url', methods=['GET'])
def get_server_url():
    """Returns the current ngrok public URL so the Flutter app can discover it."""
    global public_url
    if public_url:
        return jsonify({"url": public_url})
    return jsonify({"error": "Ngrok not running"}), 500



# =============================================================================
# ROUTE — POST /analyze   (General Vision + OCR — powered by Gemini)
# =============================================================================

@app.route('/analyze', methods=['POST'])
def analyze_image():
    """
    Analyses the image using Google Gemini 1.5 Flash.
    - OCR intent (keywords: read, text, say, word, letter) → raw text extraction.
    - Default → concise object/scene description.

    Image pipeline:
        base64 string → bytes → io.BytesIO → PIL.Image → Gemini generate_content()
    """
    try:
        data = request.json
        if not data or 'image' not in data:
            return jsonify({"error": "No image provided"}), 400

        base64_image = data['image']
        user_query   = data.get('query', '').lower()

        # Detect OCR vs general-vision intent via query keywords
        is_ocr_request = any(
            word in user_query
            for word in ['read', 'text', 'say', 'word', 'letter', 'written', 'sign']
        )

        if is_ocr_request:
            logger.info("[ANALYZE] Intent: OCR")
            prompt_text = (
                "Read the text in this image exactly as it appears. "
                "Output ONLY the raw text found. Do not summarize, explain, "
                "or add conversational filler. If there is no text, say 'No text found'."
            )
        else:
            logger.info("[ANALYZE] Intent: General Vision")
            prompt_text = (
                "Identify the main objects in front of the user. "
                "List them simply like 'I see a [object], a [object], and [object] "
                "in front of you.' Do not describe colors, background, or details "
                "unless asked. Keep it extremely concise."
            )

        print(f"[ANALYZE] Prompt: {prompt_text[:80]}...")
        logger.info(f"[ANALYZE] Sending to Gemini model={GEMINI_MODEL}")

        # Decode base64 → bytes → PIL Image (SDK accepts PIL objects directly)
        image_bytes = base64.b64decode(base64_image)
        img = Image.open(io.BytesIO(image_bytes))

        # ── QUOTA SAFETY NET ────────────────────────────────────────────────
        # Catches 429 Quota Exceeded and any other Gemini API errors.
        # Returns a clean 200 OK with an error message instead of crashing.
        try:
            response = gemini_client.models.generate_content(
                model=GEMINI_MODEL,
                contents=[prompt_text, img],
            )
            response_text = response.text
            print(f"[ANALYZE] Gemini response: {response_text}")
            logger.info(f"[ANALYZE] Response: {response_text}")
            return jsonify({"response": response_text})

        except Exception as gemini_err:
            logger.error(f"[ANALYZE] Gemini API error: {gemini_err}")
            print(f"[ANALYZE] ⚠ Gemini quota/API error: {gemini_err}")
            return jsonify({
                "response": "The AI is currently busy or rate-limited. "
                            "Please wait a moment and try again."
            })
        # ────────────────────────────────────────────────────────────

    except Exception as e:
        logger.error(f"[ANALYZE] Unexpected error: {e}", exc_info=True)
        return jsonify({"error": str(e)}), 500


# =============================================================================
# PHASE 3 — ROUTE: POST /register_face
# =============================================================================

@app.route('/register_face', methods=['POST'])
def register_face():
    """
    Registers a new face encoding + description to the persistent knowledge base.

    Expected JSON body:
        {
            "image_base64": "<base64-encoded JPEG>",
            "name": "David",
            "description": "Tall man with glasses"  # optional
        }

    Workflow:
        1. Decode the base64 image to a numpy array.
        2. Run image quality checks (blur + single-face validation).
        3. Extract the 128-dimensional face encoding with face_recognition.
        4. Append the encoding to face_encodings.pkl (keyed by name).
        5. Save a cropped face chip to dataset/<Name>/ for visual debugging.
        6. Update faces_database.json with name, description, and image path.
        7. Return success / descriptive error JSON.
    """
    try:
        data = request.json
        if not data or 'image_base64' not in data or 'name' not in data:
            return jsonify({
                "status": "error",
                "message": "Missing image_base64 or name in request."
            }), 400

        name        = data['name'].strip().title()          # "david" → "David"
        description = data.get('description', '').strip()   # Optional spoken description
        b64_string  = data['image_base64']

        print(f"[REGISTER] Starting registration — name='{name}', description='{description}'")
        logger.info(f"[REGISTER] name='{name}', description='{description}'")

        # ---- Step 1: Decode -------------------------------------------------
        image_bgr = decode_base64_image(b64_string)
        if image_bgr is None:
            return jsonify({
                "status": "error",
                "message": "Failed to decode the image. Please try again."
            }), 400

        # ---- Step 2: Image Quality Check ------------------------------------
        passed, reason = check_image_quality(image_bgr)
        if not passed:
            logger.warning(f"[REGISTER] Quality check failed for '{name}': {reason}")
            return jsonify({"status": "error", "message": reason}), 400

        # ---- Step 3: Extract Face Encoding ----------------------------------
        image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        face_locs = face_recognition.face_locations(image_rgb)
        face_encs = face_recognition.face_encodings(image_rgb, face_locs)

        if not face_encs:
            return jsonify({
                "status": "error",
                "message": "Could not generate a face encoding. "
                           "Please ensure the face is clearly visible and try again."
            }), 400

        encoding = face_encs[0]  # Validated exactly 1 face in quality check

        # ---- Step 4: Save Encoding to PKL -----------------------------------
        known_encodings = load_encodings()
        if name in known_encodings:
            known_encodings[name].append(encoding)
        else:
            known_encodings[name] = [encoding]
        save_encodings(known_encodings)
        print(f"[REGISTER] PKL updated — '{name}' now has {len(known_encodings[name])} encoding(s).")
        logger.info(f"[REGISTER] PKL updated — '{name}' has {len(known_encodings[name])} encoding(s).")

        # ---- Step 5: Save Cropped Face Image --------------------------------
        top, right, bottom, left = face_locs[0]
        face_crop_bgr = image_bgr[top:bottom, left:right]

        person_dir = os.path.join(DATASET_DIR, name)
        os.makedirs(person_dir, exist_ok=True)

        timestamp = int(time.time())
        crop_filename = f"face_{timestamp}.jpg"
        crop_path = os.path.join(person_dir, crop_filename)
        cv2.imwrite(crop_path, face_crop_bgr)
        print(f"[REGISTER] Face crop saved — {crop_path}")
        logger.info(f"[REGISTER] Face crop saved — {crop_path}")

        # ---- Step 6: Update Central JSON Database ---------------------------
        from datetime import datetime
        registered_at = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        faces_db = load_faces_db()

        if name in faces_db:
            faces_db[name]["images"].append(crop_path)
            if description:
                faces_db[name]["description"] = description
            faces_db[name]["registered_at"] = registered_at  # update timestamp
            print(f"[REGISTER] JSON DB updated (existing) — '{name}' now has "
                  f"{len(faces_db[name]['images'])} image(s).")
        else:
            faces_db[name] = {
                "description": description,
                "images": [crop_path],
                "registered_at": registered_at,
            }
            print(f"[REGISTER] JSON DB created new entry for '{name}' at {registered_at}.")

        save_faces_db(faces_db)
        logger.info(f"[REGISTER] JSON DB saved. Total people: {len(faces_db)}. registered_at={registered_at}")
        # ---- Step 7: Return success -----------------------------------------
        desc_msg = f" Description saved: {description}." if description else ""
        return jsonify({
            "status": "success",
            "message": f"Successfully registered {name}.{desc_msg}"
        })

    except Exception as e:
        logger.error(f"[REGISTER] Unexpected error: {e}", exc_info=True)
        return jsonify({
            "status": "error",
            "message": "An internal server error occurred. Please try again."
        }), 500



# =============================================================================
# PHASE 4 — ROUTE: POST /recognize_face
# =============================================================================

@app.route('/recognize_face', methods=['POST'])
def recognize_face():
    """
    Identifies who is in the camera frame by comparing against stored encodings.

    Expected JSON body:
        { "image_base64": "<base64-encoded JPEG>" }

    Matching algorithm:
        1. Extract encoding from live image.
        2. Load all known encodings from face_encodings.pkl.
        3. Flatten the per-person encoding lists into parallel lists of
           (name, encoding) pairs for vectorised comparison.
        4. face_recognition.face_distance() returns a float per known encoding
           (lower = more similar). The minimum distance determines the best match.
        5. face_recognition.compare_faces() with FACE_RECOGNITION_TOLERANCE
           gives a boolean mask; we require the best-distance encoding to also
           pass this boolean check to avoid borderline false positives.

    Responses:
        {"status": "success", "message": "You are speaking to David."}
        {"status": "unknown", "message": "I see a person, but I do not recognise them."}
        {"status": "empty",   "message": "I see a person, but I do not recognise them."}
        {"status": "error",   "message": "<reason>"}
    """
    try:
        data = request.json
        if not data or 'image_base64' not in data:
            return jsonify({
                "status": "error",
                "message": "Missing image_base64 in request."
            }), 400

        b64_string = data['image_base64']

        # ---- Step 1: Decode & extract live encoding -----------------------
        image_bgr = decode_base64_image(b64_string)
        if image_bgr is None:
            return jsonify({
                "status": "error",
                "message": "Failed to decode the image. Please try again."
            }), 400

        image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        live_locs = face_recognition.face_locations(image_rgb)
        live_encs = face_recognition.face_encodings(image_rgb, live_locs)

        if not live_encs:
            # No face detected in the live frame at all.
            return jsonify({
                "status": "empty",
                "message": "I see a person, but I do not recognise them."
            })

        live_encoding = live_encs[0]  # Compare only the first/primary face

        # ---- Step 2: Load known encodings ---------------------------------
        known_encodings = load_encodings()

        if not known_encodings:
            return jsonify({
                "status": "unknown",
                "message": "No faces have been registered yet. "
                           "Please register a face first."
            })

        # ---- Step 3: Flatten to parallel lists ----------------------------
        # known_names[i] and known_encs[i] correspond to the same person
        # (multiple photos per person are each their own entry).
        known_names: list[str] = []
        known_encs: list[np.ndarray] = []

        for person_name, enc_list in known_encodings.items():
            for enc in enc_list:
                known_names.append(person_name)
                known_encs.append(enc)

        # ---- Step 4: Compute distances & boolean matches ------------------
        # face_distance returns an array of float32 distances.
        # Smaller distance = more similar face.
        distances = face_recognition.face_distance(known_encs, live_encoding)

        # compare_faces applies the tolerance threshold and returns a bool array.
        matches = face_recognition.compare_faces(
            known_encs, live_encoding, tolerance=FACE_RECOGNITION_TOLERANCE
        )

        best_idx = int(np.argmin(distances))
        best_distance = distances[best_idx]

        logger.info(
            f"Best match: '{known_names[best_idx]}' "
            f"(distance={best_distance:.4f}, matched={matches[best_idx]})"
        )

        # ---- Step 5: Determine result -------------------------------------
        if matches[best_idx]:
            matched_name = known_names[best_idx]
            return jsonify({
                "status": "success",
                "message": f"You are speaking to {matched_name}."
            })
        else:
            return jsonify({
                "status": "unknown",
                "message": "I see a person, but I do not recognise them."
            })

    except Exception as e:
        logger.error(f"Error during /recognize_face: {e}", exc_info=True)
        return jsonify({
            "status": "error",
            "message": "An internal server error occurred. Please try again."
        }), 500


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if __name__ == '__main__':
    # Ensure dataset directory exists at boot
    os.makedirs(DATASET_DIR, exist_ok=True)

    # Start ngrok before Flask (only on the parent process in debug mode)
    if not os.environ.get("WERKZEUG_RUN_MAIN"):
        start_ngrok()

    # Run Flask — use_reloader=False prevents double ngrok startup
    app.run(host='0.0.0.0', port=5000, debug=True, use_reloader=False)
