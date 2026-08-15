"""
Self-growing training dataset.

Turns accepted citizen reports into training samples without an admin having to
feed the dataset by hand. Every candidate is deduplicated, downscaled, stripped
of location metadata, and gated on how much the label can be trusted.

Replaces feedback_engine.py, which wrote full-resolution duplicates into
contradictory label folders (109 MB on disk holding 2 distinct images).
"""

import io
import json
import logging
import os
from datetime import datetime

from PIL import Image, ImageOps

logger = logging.getLogger("dataset_collector")

BASE_DIR = os.path.dirname(__file__)
FEEDBACK_DIR = os.path.join(BASE_DIR, "dataset_feedback")
INDEX_FILE = os.path.join(BASE_DIR, "dataset_feedback_index.jsonl")
LABELS_PATH = os.path.join(BASE_DIR, "labels.txt")

# --- Tunables --------------------------------------------------------------
AUTO_ACCEPT_CONFIDENCE = 0.85   # below this, a sample goes to admin review
DUPLICATE_MAX_DISTANCE = 8      # Hamming distance over a 64-bit dHash
TRAINING_IMAGE_MAX_DIM = 512    # model trains at 224x224; 512 leaves crop headroom
TRAINING_JPEG_QUALITY = 88

STATUS_APPROVED = "approved"
STATUS_PENDING = "pending"
STATUS_REJECTED = "rejected"
STATUS_SKIPPED = "skipped"

SOURCE_AUTO = "auto"
SOURCE_USER_CORRECTION = "user_correction"
SOURCE_ADMIN = "admin"

# --- Vocabulary reconciliation ---------------------------------------------
# Three naming schemes exist in this project and none of them match:
#   labels.txt      -> "Street_Light", "Pothole"          (what the model trains on)
#   DBCategory.name -> "Street Lighting", "Road Damage"   (what the app submits)
#   old folders     -> "normal", "fake_false_alarms"      (junk, discarded)
# Everything is normalised to the labels.txt vocabulary, because that is what
# train_model.py reads off the directory names.
DB_CATEGORY_TO_CLASS = {
    "street lighting": "Street_Light",
    "road damage": "Pothole",
    "waste": "Illegal_Dumping",
    "drainage": "Drainage",
    "overgrown vegetation": "Overgrown_Vegetation",
    "broken sidewalk": "Broken_Sidewalk",
    "fallen tree": "Fallen_Tree",
    "illegal dumping": "Illegal_Dumping",
    "open burning": "Open_Burning",
    "vandalism": "Vandalism",
    "road sign": "Road_Sign",
    "pothole": "Pothole",
    "street light": "Street_Light",
    "normal": "Normal",
    # "other" is deliberately absent -- it is not a trainable class.
}

_hash_index = []


def load_class_names():
    """Read the canonical class list from labels.txt so it tracks retraining."""
    names = []
    try:
        with open(LABELS_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split(" ", 1)
                names.append(parts[1].strip() if len(parts) > 1 else parts[0])
    except Exception as e:
        logger.error(f"Could not read labels.txt: {e}")
    return names


def to_training_class(label):
    """
    Map any of the project's label vocabularies onto a trainable class name.

    Returns None when the label is not trainable ("other", "Uncategorized", a
    multi-label string with no clear winner). Callers must treat None as
    "do not store" rather than inventing a bucket.
    """
    if not label:
        return None

    # The app submits multi-label strings like "Pothole, Drainage" -- take the
    # first, which inference orders by confidence.
    primary = str(label).split(",")[0].strip()
    if not primary:
        return None

    key = primary.lower().replace("_", " ").strip()
    if key in ("other", "uncategorized", "unknown", ""):
        return None

    mapped = DB_CATEGORY_TO_CLASS.get(key)
    if mapped:
        return mapped

    # Fall back to an exact match against labels.txt (case/space insensitive).
    for name in load_class_names():
        if name.lower().replace("_", " ") == key:
            return name.replace(" ", "_")

    logger.info(f"Unmapped label '{label}' -- not stored")
    return None


def parse_confidence(confidence):
    """
    Normalise the confidence field to a 0.0-1.0 float.

    Inference emits strings like "91.2%, 44.0%" (one entry per passing label);
    the first value corresponds to the primary class.
    """
    if confidence is None:
        return 0.0
    if isinstance(confidence, (int, float)):
        value = float(confidence)
        return value / 100.0 if value > 1.0 else value
    try:
        first = str(confidence).split(",")[0].strip().rstrip("%").strip()
        return float(first) / 100.0
    except (ValueError, IndexError):
        return 0.0


# --- Perceptual hashing ----------------------------------------------------
def _compute_dhash(image, hash_size=8):
    """Difference hash: compares horizontally adjacent pixels in a 9x8 grayscale grid."""
    resized = image.convert("L").resize((hash_size + 1, hash_size), Image.Resampling.LANCZOS)
    pixels = list(resized.getdata())

    bits = []
    for row in range(hash_size):
        for col in range(hash_size):
            left = pixels[row * (hash_size + 1) + col]
            right = pixels[row * (hash_size + 1) + col + 1]
            bits.append(left > right)

    value = 0
    out = []
    for i, bit in enumerate(bits):
        if bit:
            value += 2 ** (i % 4)
        if i % 4 == 3:
            out.append(hex(value)[2:])
            value = 0
    return "".join(out)


def compute_image_hash(image_bytes):
    """Return a 64-bit dHash as a 16-character hex string, or "" on failure."""
    try:
        return _compute_dhash(Image.open(io.BytesIO(image_bytes)))
    except Exception as e:
        logger.error(f"dHash failed: {e}")
        return ""


def hamming_distance(hash1, hash2):
    """Bit distance between two equal-length hex hashes. Returns 64 when incomparable."""
    if not hash1 or not hash2 or len(hash1) != len(hash2):
        return 64
    try:
        return bin(int(hash1, 16) ^ int(hash2, 16)).count("1")
    except ValueError:
        return 64


def check_duplicate_image(image_bytes, max_distance=DUPLICATE_MAX_DISTANCE, known_hashes=None):
    """
    Look for a near-identical image already in the dataset.

    Args:
        known_hashes: optional list of {"hash", "report_id"} dicts. Pass the DB
            rows in production; falls back to the local JSONL index otherwise.

    Returns:
        (is_duplicate, matching_report_id, similarity_percent)
    """
    new_hash = compute_image_hash(image_bytes)
    entries = known_hashes if known_hashes is not None else _hash_index
    if not new_hash or not entries:
        return False, None, 0.0

    best_id = None
    best_distance = 64
    for entry in entries:
        distance = hamming_distance(new_hash, entry.get("hash", ""))
        if distance < best_distance:
            best_distance = distance
            best_id = entry.get("report_id")

    similarity = round((1.0 - (best_distance / 64.0)) * 100.0, 1)
    is_duplicate = best_distance <= max_distance
    return is_duplicate, (best_id if is_duplicate else None), similarity


# --- Image preparation -----------------------------------------------------
def prepare_training_image(image_bytes, max_dim=TRAINING_IMAGE_MAX_DIM):
    """
    Produce a compact, metadata-free copy suitable for training.

    Three things happen here, all deliberate:
      1. EXIF orientation is baked into the pixels, then dropped -- otherwise
         sideways phone photos train the model on rotated features.
      2. The image is downscaled. Training runs at 224x224, so storing 8 MB
         originals wastes ~99% of the space.
      3. Re-encoding drops all metadata, which strips the GPS coordinates. Citizen
         photos are taken at homes and workplaces; their locations must not travel
         into a dataset repo.

    Returns (bytes, extension) or (None, None).
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img = ImageOps.exif_transpose(img)
        img = img.convert("RGB")

        if max(img.size) > max_dim:
            img.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)

        out = io.BytesIO()
        img.save(out, format="JPEG", quality=TRAINING_JPEG_QUALITY, optimize=True)
        return out.getvalue(), ".jpg"
    except Exception as e:
        logger.error(f"Could not prepare training image: {e}")
        return None, None


# --- Gating ----------------------------------------------------------------
def decide_disposition(class_label, confidence, authenticity, is_duplicate,
                       user_corrected=False):
    """
    Decide whether a sample is trusted enough to train on unattended.

    The model's own high-confidence guesses are allowed in, because requiring a
    human for every sample defeats the purpose. But anything uncertain, anything
    whose image provenance looks wrong, and anything the model was unsure about
    goes to a review queue instead of silently teaching the model its own
    mistakes.

    Returns (status, reason).
    """
    if is_duplicate:
        return STATUS_SKIPPED, "Near-identical image is already in the dataset"

    if not class_label:
        return STATUS_SKIPPED, "Label does not map to a trainable class"

    verdict = (authenticity or {}).get("verdict", "metadata_stripped")

    if verdict in ("ai_confirmed", "likely_ai_generated"):
        return STATUS_REJECTED, f"Image provenance flagged as synthetic ({verdict})"

    # A human disagreeing with the model is the most valuable label available --
    # it is exactly the case the model got wrong.
    if user_corrected:
        return STATUS_APPROVED, "Category corrected by the reporting citizen"

    if confidence < AUTO_ACCEPT_CONFIDENCE:
        return STATUS_PENDING, (
            f"Model confidence {confidence:.0%} is below the "
            f"{AUTO_ACCEPT_CONFIDENCE:.0%} auto-accept threshold"
        )

    if verdict not in ("camera_verified", "likely_camera"):
        return STATUS_PENDING, (
            f"No camera provenance to corroborate the image ({verdict})"
        )

    return STATUS_APPROVED, (
        f"Confident prediction ({confidence:.0%}) on a verified camera capture"
    )


def build_sample(report_id, image_bytes, class_label, confidence, authenticity,
                 known_hashes=None, user_corrected=False):
    """
    Evaluate one upload and return a sample descriptor.

    Does not persist anything -- dataset_store.py owns persistence. The caller
    gets back everything needed to write a DatasetSample row.
    """
    normalised = to_training_class(class_label)
    conf = parse_confidence(confidence)

    is_duplicate, match_id, similarity = check_duplicate_image(
        image_bytes, known_hashes=known_hashes
    )
    status, reason = decide_disposition(
        normalised, conf, authenticity, is_duplicate, user_corrected
    )

    sample = {
        "report_id": report_id,
        "image_hash": compute_image_hash(image_bytes),
        "class_label": normalised,
        "confidence": round(conf, 4),
        "status": status,
        "reason": reason,
        "source": SOURCE_USER_CORRECTION if user_corrected else SOURCE_AUTO,
        "authenticity_verdict": (authenticity or {}).get("verdict"),
        "authenticity_score": (authenticity or {}).get("authenticity_score"),
        "duplicate_of": match_id,
        "similarity": similarity,
        "created_at": datetime.now().isoformat(),
        "image_bytes": None,
        "extension": None,
    }

    if status in (STATUS_APPROVED, STATUS_PENDING):
        prepared, ext = prepare_training_image(image_bytes)
        if prepared:
            sample["image_bytes"] = prepared
            sample["extension"] = ext
            sample["stored_size"] = len(prepared)
        else:
            sample["status"] = STATUS_SKIPPED
            sample["reason"] = "Image could not be prepared for training"

    return sample


# --- Local persistence (fallback when GitHub sync is unavailable) -----------
def save_sample_locally(sample):
    """Write a prepared sample under dataset_feedback/<status>/<Class>/<hash>.jpg."""
    if not sample.get("image_bytes") or not sample.get("class_label"):
        return ""

    try:
        target_dir = os.path.join(FEEDBACK_DIR, sample["status"], sample["class_label"])
        os.makedirs(target_dir, exist_ok=True)

        # Hash-named so the same image can never be written twice.
        name = f"{sample['image_hash'] or 'nohash'}{sample['extension']}"
        path = os.path.join(target_dir, name)

        if os.path.exists(path):
            logger.info(f"Sample already on disk, skipping write: {path}")
            return path

        with open(path, "wb") as f:
            f.write(sample["image_bytes"])
        append_index(sample)
        logger.info(f"Stored training sample: {path}")
        return path
    except Exception as e:
        logger.error(f"Could not store sample locally: {e}")
        return ""


def relocate_sample_file(current_path, new_status, class_label):
    """
    Move a stored sample into the folder matching its new status/label.

    Necessary because retraining reads the *filesystem* (dataset_feedback/approved/
    ...), not the database. Without this, an admin approving a sample would
    update its row while the image stayed in pending/ and never reached training.

    Returns the new path, or the original path if the move was not possible.
    """
    if not current_path or not os.path.exists(current_path):
        return current_path
    if not class_label:
        return current_path

    try:
        target_dir = os.path.join(FEEDBACK_DIR, new_status, class_label)
        os.makedirs(target_dir, exist_ok=True)
        target_path = os.path.join(target_dir, os.path.basename(current_path))

        if os.path.abspath(target_path) == os.path.abspath(current_path):
            return current_path

        if os.path.exists(target_path):
            os.remove(current_path)
            return target_path

        os.replace(current_path, target_path)
        logger.info(f"Moved sample to {target_path}")
        return target_path
    except Exception as e:
        logger.error(f"Could not relocate sample: {e}")
        return current_path


def discard_sample_file(current_path):
    """
    Remove a rejected sample's image from disk.

    The database row survives so its hash still blocks re-submission of the same
    image; only the pixels go.
    """
    if not current_path or not os.path.exists(current_path):
        return
    try:
        os.remove(current_path)
        logger.info(f"Discarded rejected sample: {current_path}")
    except Exception as e:
        logger.error(f"Could not discard sample: {e}")


def append_index(sample):
    """
    Append one record to the JSONL index.

    Append-only on purpose: the old code rewrote a whole JSON array on every
    write, so two concurrent uploads could clobber each other.
    """
    record = {k: v for k, v in sample.items() if k != "image_bytes"}
    try:
        with open(INDEX_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except Exception as e:
        logger.error(f"Could not append to index: {e}")


def load_index():
    """Load the local JSONL index into the in-memory hash cache."""
    global _hash_index
    _hash_index = []
    if not os.path.exists(INDEX_FILE):
        return _hash_index
    try:
        with open(INDEX_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    _hash_index.append(json.loads(line))
        logger.info(f"Loaded {len(_hash_index)} dataset samples into the hash index")
    except Exception as e:
        logger.error(f"Could not load index: {e}")
    return _hash_index


def get_dataset_stats():
    """Count stored samples per status and class, for the admin dashboard."""
    stats = {"total": 0, "by_status": {}, "by_class": {}}
    if not os.path.exists(FEEDBACK_DIR):
        return stats

    try:
        for status in os.listdir(FEEDBACK_DIR):
            status_path = os.path.join(FEEDBACK_DIR, status)
            if not os.path.isdir(status_path):
                continue
            for class_name in os.listdir(status_path):
                class_path = os.path.join(status_path, class_name)
                if not os.path.isdir(class_path):
                    continue
                count = len([
                    f for f in os.listdir(class_path)
                    if f.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
                ])
                if not count:
                    continue
                stats["total"] += count
                stats["by_status"][status] = stats["by_status"].get(status, 0) + count
                if status == STATUS_APPROVED:
                    stats["by_class"][class_name] = stats["by_class"].get(class_name, 0) + count
    except Exception as e:
        logger.error(f"Could not scan dataset stats: {e}")

    return stats


load_index()
