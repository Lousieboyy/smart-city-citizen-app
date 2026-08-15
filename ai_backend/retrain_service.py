"""
Retraining status reporting for the API process.

The previous version of this module returned "Successfully fine-tuned model on N
samples" without training anything at all -- the work was a comment. That is
worse than doing nothing, because an admin reading the dashboard would believe
the model had learned from the queue.

Actual training lives in retrain_model.py and runs offline. It cannot run here:
the deployed image ships ai-edge-litert rather than TensorFlow, and main.py
disables TF outright to avoid AVX crashes on cloud CPUs.
"""

import json
import logging
import os
from datetime import datetime

logger = logging.getLogger("retrain_service")

BASE_DIR = os.path.dirname(__file__)
METRICS_PATH = os.path.join(BASE_DIR, "retrain_metrics.json")


def tensorflow_available():
    """True when this process could actually train."""
    try:
        import tensorflow  # noqa: F401
        return True
    except ImportError:
        return False


def get_retrain_status(pending_samples=0, approved_samples=0):
    """
    Report what the last real training run produced and whether one is warranted.

    Never claims training happened. Returns the metrics written by
    retrain_model.py, or an explicit "never run" state.
    """
    last_run = None
    if os.path.exists(METRICS_PATH):
        try:
            with open(METRICS_PATH, "r", encoding="utf-8") as f:
                last_run = json.load(f)
        except Exception as e:
            logger.error(f"Could not read retrain metrics: {e}")

    can_train_here = tensorflow_available()

    return {
        "status": "ready" if approved_samples else "no_new_samples",
        "can_train_in_this_process": can_train_here,
        "approved_samples": approved_samples,
        "pending_samples": pending_samples,
        "last_run": last_run,
        "instructions": (
            "Run `python retrain_model.py --pull` on a machine with TensorFlow. "
            "It merges ai_data/ with the approved feedback samples, trains, and "
            "only replaces model.tflite if the new model beats the current one "
            "on a held-out set."
        ) if not can_train_here else (
            "TensorFlow is available here. Run `python retrain_model.py` to train."
        ),
        "checked_at": datetime.now().isoformat(),
    }
