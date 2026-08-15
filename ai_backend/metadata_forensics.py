"""
Image metadata forensics.

Inspects an upload's embedded metadata to decide whether it came from a real
camera, was edited, or was produced by a generative model.

Design note: absence of metadata is NOT evidence of AI generation. Screenshots,
WhatsApp forwards, social-media downloads and any re-encoding pipeline all strip
EXIF. Those cases return "metadata_stripped" (an admission of ignorance) rather
than accusing the upload of being synthetic.

Replaces the earlier fake_detector.py, which penalised missing EXIF and so
flagged its own mobile client.
"""

import io
import logging
import re

from PIL import Image, ExifTags

logger = logging.getLogger("metadata_forensics")

# --- Verdicts, ordered most-synthetic to most-authentic --------------------
AI_CONFIRMED = "ai_confirmed"
LIKELY_AI = "likely_ai_generated"
LIKELY_EDITED = "likely_edited"
METADATA_STRIPPED = "metadata_stripped"
LIKELY_CAMERA = "likely_camera"
CAMERA_VERIFIED = "camera_verified"

# --- Software signatures, split by what they actually imply ----------------
# Generators: presence means the pixels were synthesised.
AI_GENERATOR_KEYWORDS = [
    "midjourney", "dall-e", "dall e", "dalle", "stable diffusion", "stablediffusion",
    "automatic1111", "comfyui", "invokeai", "novelai", "leonardo.ai", "firefly",
    "adobe firefly", "imagen", "flux.1", "black forest labs", "civitai",
    "ai-generated", "ai generated", "generative", "text-to-image", "txt2img",
]

# Editors: presence means the image was touched up. Editing is NOT generation --
# the old detector scored these the same as Midjourney, which was wrong.
IMAGE_EDITOR_KEYWORDS = [
    "photoshop", "gimp", "lightroom", "snapseed", "picsart", "paint.net",
    "affinity photo", "capture one", "luminar", "photoscape", "canva",
    "pixlr", "darktable", "rawtherapee",
]

# Phone/camera processing pipelines: positive evidence of a real capture.
CAMERA_PIPELINE_KEYWORDS = [
    "samsung", "apple", "google", "huawei", "xiaomi", "oppo", "vivo", "oneplus",
    "realme", "sony", "canon", "nikon", "fujifilm", "panasonic", "gopro",
    "motorola", "nothing phone", "honor",
]

# --- EXIF tags a genuine camera emits as a cluster -------------------------
CAMERA_TAG_CLUSTER = [
    "Make", "Model", "LensModel", "LensMake", "ExposureTime", "FNumber",
    "ISOSpeedRatings", "PhotographicSensitivity", "DateTimeOriginal",
    "FocalLength", "ExposureProgram", "MeteringMode", "WhiteBalance",
    "MakerNote", "BodySerialNumber", "ShutterSpeedValue", "ApertureValue",
]

# --- PNG/text chunk keys used by generation tooling ------------------------
# Automatic1111 writes "parameters"; ComfyUI writes "prompt" and "workflow";
# InvokeAI writes "sd-metadata"; older forks wrote "Dream".
AI_TEXT_CHUNK_KEYS = {
    "parameters": "Automatic1111 / WebUI generation parameters",
    "prompt": "ComfyUI prompt graph",
    "workflow": "ComfyUI workflow graph",
    "sd-metadata": "InvokeAI metadata block",
    "dream": "Stable Diffusion 'Dream' command block",
    "generation_data": "Generic generation-parameter block",
    "aigc": "AIGC provenance marker",
}

# Canvas sizes typical of diffusion models. Circumstantial only -- lightly weighted.
AI_CANVAS_SIZES = {
    (512, 512), (768, 768), (1024, 1024), (1536, 1536), (2048, 2048),
    (512, 768), (768, 512), (832, 1216), (1216, 832), (896, 1152), (1152, 896),
    (1024, 1792), (1792, 1024), (1344, 768), (768, 1344),
}

# Byte markers findable without a full decode (works on truncated head slices).
C2PA_BYTE_MARKERS = [b"c2pa", b"jumbf", b"caBX", b"contentauth"]
XMP_AI_MARKERS = [
    b"trainedAlgorithmicMedia",
    b"compositeWithTrainedAlgorithmicMedia",
    b"algorithmicMedia",
]

MAX_SCAN_BYTES = 512 * 1024


def _add(signals, name, weight, detail):
    """Record one forensic signal. Positive weight = authentic, negative = synthetic."""
    signals.append({"name": name, "weight": weight, "detail": detail})


def _collect_exif(img):
    """
    Flatten IFD0 + the Exif SubIFD into one tag dict.

    The SubIFD matters: ExposureTime, FNumber, ISO and DateTimeOriginal all live
    there, and the old detector never read it -- it only ever saw Make/Model.
    """
    tags = {}
    has_gps = False
    has_thumbnail = False

    try:
        exif = img.getexif()
    except Exception as e:
        logger.debug(f"EXIF read failed: {e}")
        return tags, has_gps, has_thumbnail

    if not exif:
        return tags, has_gps, has_thumbnail

    for tag_id, value in exif.items():
        tags[ExifTags.TAGS.get(tag_id, str(tag_id))] = value

    try:
        sub = exif.get_ifd(ExifTags.IFD.Exif)
        for tag_id, value in (sub or {}).items():
            tags[ExifTags.TAGS.get(tag_id, str(tag_id))] = value
    except Exception:
        pass

    try:
        gps = exif.get_ifd(ExifTags.IFD.GPSInfo)
        has_gps = bool(gps)
    except Exception:
        pass

    try:
        has_thumbnail = bool(exif.get_ifd(ExifTags.IFD.IFD1))
    except Exception:
        pass

    return tags, has_gps, has_thumbnail


def _scan_raw_markers(raw, signals):
    """
    Byte-level scan for provenance blocks. Deliberately decode-free so it works
    on a truncated head slice of the original file.

    Returns True if a conclusive generative-provenance marker was found.
    """
    head = raw[:MAX_SCAN_BYTES]
    lowered = head.lower()
    conclusive = False

    # C2PA / Content Credentials -- embedded by DALL-E 3, Firefly and Midjourney.
    c2pa_hit = next((m for m in C2PA_BYTE_MARKERS if m.lower() in lowered), None)
    if c2pa_hit:
        # A manifest proves provenance was recorded; whether it says "AI" depends
        # on the claim generator named alongside it.
        generator = next(
            (kw for kw in AI_GENERATOR_KEYWORDS if kw.encode() in lowered), None
        )
        if generator:
            _add(signals, "c2pa_ai_manifest", -60,
                 f"C2PA provenance manifest naming '{generator}'")
            conclusive = True
        else:
            _add(signals, "c2pa_manifest", 0,
                 "C2PA provenance manifest present (issuer not identified as a generator)")

    # IPTC digitalSourceType -- the standard marker for synthetic media.
    xmp_hit = next((m for m in XMP_AI_MARKERS if m.lower() in lowered), None)
    if xmp_hit:
        _add(signals, "xmp_digital_source_type", -60,
             f"XMP digitalSourceType declares '{xmp_hit.decode(errors='replace')}'")
        conclusive = True

    return conclusive


def _scan_text_chunks(img, signals):
    """
    Inspect PNG tEXt/iTXt chunks. This is where Stable Diffusion tooling stores
    the full prompt, and it is the single most reliable local signal.
    """
    conclusive = False
    try:
        info = img.info or {}
    except Exception:
        return conclusive

    for key, value in info.items():
        label = AI_TEXT_CHUNK_KEYS.get(str(key).strip().lower())
        if not label:
            continue
        # ComfyUI's "prompt" key is distinctive, but guard against a stray
        # unrelated field by requiring it to look like structured data.
        text = str(value)[:400]
        if str(key).strip().lower() in ("prompt", "workflow") and not text.strip().startswith(("{", "[")):
            continue
        _add(signals, "generation_text_chunk", -60, f"{label} embedded in image")
        conclusive = True

    return conclusive


def _classify_software(tags, signals):
    """Bucket the Software/Artist/UserComment strings into generator vs editor vs camera."""
    blob = " ".join(
        str(tags.get(k, "")) for k in ("Software", "Artist", "UserComment", "ImageDescription", "HostComputer")
    ).lower()

    if not blob.strip():
        return False, False

    generator = next((kw for kw in AI_GENERATOR_KEYWORDS if kw in blob), None)
    if generator:
        _add(signals, "ai_software_tag", -55, f"Software metadata names '{generator}'")
        return True, False

    editor = next((kw for kw in IMAGE_EDITOR_KEYWORDS if kw in blob), None)
    if editor:
        # Edited, not generated. Worth surfacing, barely worth penalising.
        _add(signals, "editor_software_tag", -8,
             f"Image was processed with '{editor}' (editing, not generation)")
        return False, True

    pipeline = next((kw for kw in CAMERA_PIPELINE_KEYWORDS if kw in blob), None)
    if pipeline:
        _add(signals, "camera_pipeline_tag", 10, f"Camera processing pipeline '{pipeline}'")

    return False, False


def inspect_image_authenticity(image_bytes, filename="image.jpg", metadata_bytes=None):
    """
    Assess whether an upload is a genuine camera capture or synthetic.

    Args:
        image_bytes: the image actually being stored/classified.
        filename: original filename, used only for logging.
        metadata_bytes: optional head slice of the *original* file, sent by the
            client before any downscaling. All forensic metadata (EXIF APP1, XMP,
            C2PA APP11) lives at the front of the file, so a partial read is
            enough -- and it survives client-side resizing that would otherwise
            destroy the evidence.

    Returns:
        dict with verdict, authenticity_score (0-100), confidence, and a
        human-readable signals list for the admin UI.
    """
    signals = []

    try:
        forensic_bytes = metadata_bytes if metadata_bytes else image_bytes

        # Pillow reads headers lazily, so a truncated slice still yields EXIF and
        # the true original dimensions.
        img = None
        for candidate in (forensic_bytes, image_bytes):
            try:
                img = Image.open(io.BytesIO(candidate))
                break
            except Exception:
                continue

        if img is None:
            return _result(METADATA_STRIPPED, 50, "low", signals, False, False,
                           "Image could not be parsed for metadata")

        conclusive_ai = _scan_raw_markers(forensic_bytes, signals)
        if _scan_text_chunks(img, signals):
            conclusive_ai = True

        tags, has_gps, has_thumbnail = _collect_exif(img)
        generator_tag, editor_tag = _classify_software(tags, signals)
        if generator_tag:
            conclusive_ai = True

        # Camera evidence: a genuine capture emits a *cluster* of tags, not one.
        present = [t for t in CAMERA_TAG_CLUSTER if tags.get(t) not in (None, "")]
        cluster_size = len(present)
        has_camera_exif = bool(tags.get("Make") or tags.get("Model"))

        if cluster_size >= 5:
            _add(signals, "camera_tag_cluster", 40,
                 f"{cluster_size} camera EXIF tags present ({', '.join(present[:5])}...)")
        elif cluster_size >= 3:
            _add(signals, "camera_tag_cluster", 25,
                 f"{cluster_size} camera EXIF tags present ({', '.join(present)})")
        elif cluster_size >= 1:
            _add(signals, "camera_tag_partial", 10,
                 f"Only {cluster_size} camera EXIF tag(s) present ({', '.join(present)})")
        else:
            _add(signals, "no_camera_metadata", 0,
                 "No camera EXIF found -- consistent with a screenshot, download or "
                 "re-encode, and not evidence of AI generation on its own")

        if has_gps:
            _add(signals, "gps_present", 15, "GPS coordinates embedded by the capturing device")
        if has_thumbnail:
            _add(signals, "exif_thumbnail", 8, "EXIF thumbnail present (typical of camera firmware)")

        # Circumstantial: diffusion-model canvas sizes. Only meaningful when
        # there is no camera evidence to explain the image.
        size = getattr(img, "size", (0, 0))
        if size in AI_CANVAS_SIZES and cluster_size == 0:
            _add(signals, "generator_canvas_size", -15,
                 f"Dimensions {size[0]}x{size[1]} match a common image-generator canvas")

        score = max(0, min(100, 50 + sum(s["weight"] for s in signals)))
        verdict, confidence = _decide(conclusive_ai, cluster_size, editor_tag, score, signals)

        return _result(verdict, score, confidence, signals, has_camera_exif, has_gps, None)

    except Exception as e:
        logger.error(f"Authenticity inspection failed for {filename}: {e}")
        # Fail open: an inspection crash must not brand a citizen's report as fake.
        return _result(METADATA_STRIPPED, 50, "low", signals, False, False,
                       f"Metadata parsing error: {e}")


def _decide(conclusive_ai, cluster_size, editor_tag, score, signals):
    """Map accumulated evidence onto a verdict. Conclusive markers outrank the score."""
    if conclusive_ai:
        return AI_CONFIRMED, "high"

    ai_weight = sum(-s["weight"] for s in signals if s["weight"] < 0)
    if ai_weight >= 30 and cluster_size == 0:
        return LIKELY_AI, "medium"

    if editor_tag:
        return LIKELY_EDITED, "medium" if cluster_size else "low"

    if cluster_size >= 5:
        return CAMERA_VERIFIED, "high"
    if cluster_size >= 3:
        return CAMERA_VERIFIED, "medium"
    if cluster_size >= 1:
        return LIKELY_CAMERA, "low"

    # No evidence either way. Say so plainly.
    return METADATA_STRIPPED, "low"


def _result(verdict, score, confidence, signals, has_camera_exif, has_gps, note):
    if note:
        _add(signals, "note", 0, note)

    return {
        "verdict": verdict,
        "authenticity_score": int(score),
        "confidence": confidence,
        "signals": signals,
        "has_camera_exif": bool(has_camera_exif),
        "has_exif_gps": bool(has_gps),
        # Retained so callers can branch without knowing the verdict vocabulary.
        "is_suspicious": verdict in (AI_CONFIRMED, LIKELY_AI),
        "requires_review": verdict not in (CAMERA_VERIFIED, LIKELY_CAMERA),
        "reason": signals[0]["detail"] if signals else "No metadata signals found",
    }


def is_trusted_capture(result):
    """True when the image looks like a genuine camera capture -- the gate for auto-accept."""
    return result.get("verdict") in (CAMERA_VERIFIED, LIKELY_CAMERA)
