"""
Retrain the classifier on the base dataset plus collected feedback samples.

Runs OFFLINE, on a machine with TensorFlow. The deployed backend ships only
ai-edge-litert (main.py hard-disables TF to avoid AVX crashes on cloud CPUs), so
training cannot and should not happen inside the API process.

Two things here that train_model.py never had:
  1. A promotion gate. The new model is only exported if it beats the current one
     on a held-out set. An unattended pipeline that always ships whatever it just
     trained will eventually ship a regression.
  2. The .h5 -> .tflite conversion. Nothing in the repo did this, so retraining
     could never actually reach the serving path.

Usage:
    python retrain_model.py                 # train, evaluate, promote if better
    python retrain_model.py --dry-run       # report what would be trained on
    python retrain_model.py --force         # promote even if the model is worse
    python retrain_model.py --pull          # git pull the dataset repo first
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "ai_data"
FEEDBACK_DIR = BASE_DIR / "dataset_feedback"
DATASET_REPO_DIR = BASE_DIR / "dataset_repo"     # clone of the private dataset repo
MERGED_DIR = BASE_DIR / "ai_data_merged"
HOLDOUT_DIR = BASE_DIR / "ai_data_holdout"

KERAS_MODEL_PATH = BASE_DIR / "keras_Model.h5"
TFLITE_MODEL_PATH = BASE_DIR / "model.tflite"
LABELS_PATH = BASE_DIR / "labels.txt"
METRICS_PATH = BASE_DIR / "retrain_metrics.json"

IMAGE_SIZE = (224, 224)
BATCH_SIZE = 32
HOLDOUT_FRACTION = 0.15
WARMUP_EPOCHS = 6
FINETUNE_EPOCHS = 10

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp")


def log(message):
    print(f"[retrain] {message}", flush=True)


# ─────────────────────────────────────────────────────────────
#  Dataset assembly
# ─────────────────────────────────────────────────────────────
def pull_dataset_repo():
    """Refresh the local clone of the dataset repo, if one is configured."""
    if not DATASET_REPO_DIR.exists():
        log(f"No dataset clone at {DATASET_REPO_DIR}; skipping pull.")
        log("Clone it first:  git clone <your-private-dataset-repo> dataset_repo")
        return False
    try:
        subprocess.run(["git", "-C", str(DATASET_REPO_DIR), "pull", "--ff-only"],
                       check=True, capture_output=True, text=True)
        log("Dataset repo updated.")
        return True
    except subprocess.CalledProcessError as e:
        log(f"git pull failed: {e.stderr.strip()}")
        return False


def _iter_source_dirs():
    """
    Yield (label, directory) pairs for every approved image source.

    Only 'approved' feedback is used. Pending samples are unreviewed and
    rejected ones were excluded on purpose -- training on either would defeat
    the entire review mechanism.
    """
    if DATA_DIR.exists():
        for class_dir in sorted(DATA_DIR.iterdir()):
            if class_dir.is_dir():
                yield class_dir.name, class_dir

    for root in (FEEDBACK_DIR / "approved", DATASET_REPO_DIR / "dataset" / "approved"):
        if not root.exists():
            continue
        for class_dir in sorted(root.iterdir()):
            if class_dir.is_dir():
                yield class_dir.name, class_dir


def assemble_dataset():
    """
    Build a merged training tree and a disjoint holdout tree.

    The holdout is carved out deterministically (every Nth file by sorted name)
    so that repeated runs evaluate against a stable set. Comparing two models on
    different holdouts would make the promotion gate meaningless.
    """
    for path in (MERGED_DIR, HOLDOUT_DIR):
        if path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True)

    counts = {}
    holdout_counts = {}
    stride = max(2, int(1 / HOLDOUT_FRACTION))

    for label, directory in _iter_source_dirs():
        files = sorted(
            f for f in directory.iterdir()
            if f.is_file() and f.suffix.lower() in IMAGE_EXTENSIONS
        )
        if not files:
            continue

        train_dir = MERGED_DIR / label
        hold_dir = HOLDOUT_DIR / label
        train_dir.mkdir(parents=True, exist_ok=True)
        hold_dir.mkdir(parents=True, exist_ok=True)

        for index, source in enumerate(files):
            # Prefix with the source folder so same-named files never collide.
            target_name = f"{directory.parent.name}_{source.name}"
            # Take every stride-th file, offset to the END of each group rather
            # than index 0. Selecting index 0 would send the only image of a
            # freshly-collected class straight to holdout, contributing nothing
            # to training -- exactly the case this pipeline exists to serve.
            if index % stride == stride - 1:
                _link_or_copy(source, hold_dir / target_name)
                holdout_counts[label] = holdout_counts.get(label, 0) + 1
            else:
                _link_or_copy(source, train_dir / target_name)
                counts[label] = counts.get(label, 0) + 1

    return counts, holdout_counts


def _link_or_copy(source, target):
    """
    Hard-link the image into the merged tree, copying only if that fails.

    ai_data/ alone is ~550 MB; copying it on every run would be minutes of I/O
    and a duplicate of the whole dataset on disk. Hard links are instant and
    consume no extra space, and these files are only ever read.
    """
    try:
        os.link(source, target)
    except (OSError, NotImplementedError):
        shutil.copy2(source, target)


def report_balance(counts):
    """Print the class distribution and warn when it is badly skewed."""
    if not counts:
        return
    log("Class balance:")
    largest = max(counts.values())
    smallest = min(counts.values())
    for label in sorted(counts):
        bar = "#" * int(30 * counts[label] / largest)
        log(f"  {label:24} {counts[label]:5}  {bar}")

    if largest >= 3 * smallest:
        log("")
        log(f"  WARNING: imbalance is {largest / smallest:.1f}x "
            f"(largest {largest}, smallest {smallest}).")
        log("  The model will be biased toward over-represented classes.")


# ─────────────────────────────────────────────────────────────
#  Training
# ─────────────────────────────────────────────────────────────
def build_datasets(tf):
    train_ds = tf.keras.utils.image_dataset_from_directory(
        MERGED_DIR, validation_split=0.2, subset="training", seed=123,
        image_size=IMAGE_SIZE, batch_size=BATCH_SIZE, label_mode="categorical",
    )
    val_ds = tf.keras.utils.image_dataset_from_directory(
        MERGED_DIR, validation_split=0.2, subset="validation", seed=123,
        image_size=IMAGE_SIZE, batch_size=BATCH_SIZE, label_mode="categorical",
    )
    class_names = train_ds.class_names

    augment = tf.keras.Sequential([
        tf.keras.layers.RandomFlip("horizontal"),
        tf.keras.layers.RandomRotation(0.1),
        tf.keras.layers.RandomZoom(0.1),
    ])

    # Must match inference in main.py::_ai_inference_sync exactly: (x/127.5)-1
    def prep_train(img, label):
        return (augment(img, training=True) / 127.5) - 1, label

    def prep_eval(img, label):
        return (img / 127.5) - 1, label

    return (train_ds.map(prep_train), val_ds.map(prep_eval), class_names)


def build_model(tf, num_classes):
    """MobileNetV2 + sigmoid head, matching the architecture Grad-CAM expects."""
    base = tf.keras.applications.MobileNetV2(
        weights="imagenet", include_top=False, input_shape=(*IMAGE_SIZE, 3)
    )
    base.trainable = False

    inputs = tf.keras.Input(shape=(*IMAGE_SIZE, 3))
    x = base(inputs, training=False)
    x = tf.keras.layers.GlobalAveragePooling2D()(x)
    x = tf.keras.layers.Dense(128, activation="relu")(x)
    x = tf.keras.layers.Dropout(0.2)(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="sigmoid")(x)
    return tf.keras.Model(inputs, outputs), base


def evaluate_holdout(tf, model, class_names):
    """Accuracy of the argmax prediction against the frozen holdout set."""
    if not HOLDOUT_DIR.exists() or not any(HOLDOUT_DIR.iterdir()):
        return None

    ds = tf.keras.utils.image_dataset_from_directory(
        HOLDOUT_DIR, image_size=IMAGE_SIZE, batch_size=BATCH_SIZE,
        label_mode="categorical", shuffle=False, class_names=class_names,
    )
    ds = ds.map(lambda img, label: ((img / 127.5) - 1, label))

    correct = total = 0
    import numpy as np
    for images, labels in ds:
        preds = model.predict(images, verbose=0)
        correct += int((np.argmax(preds, axis=1) == np.argmax(labels.numpy(), axis=1)).sum())
        total += len(labels)

    return (correct / total) if total else None


def evaluate_existing_tflite(class_names):
    """
    Score the currently-served model on the same holdout, for the promotion gate.

    Returns None when there is no current model or it cannot be scored, in which
    case promotion proceeds unconditionally.
    """
    if not TFLITE_MODEL_PATH.exists() or not HOLDOUT_DIR.exists():
        return None

    try:
        import numpy as np
        from PIL import Image, ImageOps
        try:
            import ai_edge_litert.interpreter as tflite
        except ImportError:
            import tensorflow.lite as tflite

        interpreter = tflite.Interpreter(model_path=str(TFLITE_MODEL_PATH))
        interpreter.allocate_tensors()
        inp = interpreter.get_input_details()
        out = interpreter.get_output_details()

        # The old model's own label order, which may differ from the new one.
        old_labels = []
        if LABELS_PATH.exists():
            with open(LABELS_PATH, "r", encoding="utf-8") as f:
                for line in f:
                    parts = line.strip().split(" ", 1)
                    if len(parts) > 1:
                        old_labels.append(parts[1].strip())

        correct = total = 0
        for class_dir in sorted(HOLDOUT_DIR.iterdir()):
            if not class_dir.is_dir():
                continue
            truth = class_dir.name
            for image_file in class_dir.iterdir():
                if image_file.suffix.lower() not in IMAGE_EXTENSIONS:
                    continue
                try:
                    img = Image.open(image_file).convert("RGB")
                    img = ImageOps.fit(img, IMAGE_SIZE, Image.Resampling.LANCZOS)
                    data = np.expand_dims(
                        (np.asarray(img).astype(np.float32) / 127.5) - 1, axis=0
                    )
                    interpreter.set_tensor(inp[0]["index"], data)
                    interpreter.invoke()
                    prediction = interpreter.get_tensor(out[0]["index"])[0]
                    index = int(np.argmax(prediction))
                    predicted = old_labels[index] if index < len(old_labels) else ""
                    if predicted.replace(" ", "_") == truth.replace(" ", "_"):
                        correct += 1
                    total += 1
                except Exception:
                    continue

        return (correct / total) if total else None
    except Exception as e:
        log(f"Could not score the existing model: {e}")
        return None


def export_tflite(tf, model):
    """
    Convert the trained Keras model to TFLite -- the format main.py actually loads.

    This step was missing entirely, which is why retraining could never affect
    what the API served.
    """
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    return converter.convert()


# ─────────────────────────────────────────────────────────────
#  Entry point
# ─────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Retrain the classifier on collected feedback.")
    parser.add_argument("--dry-run", action="store_true", help="report the dataset and exit")
    parser.add_argument("--force", action="store_true", help="promote even if accuracy regresses")
    parser.add_argument("--pull", action="store_true", help="git pull the dataset repo first")
    args = parser.parse_args()

    if args.pull:
        pull_dataset_repo()

    log("Assembling dataset...")
    counts, holdout_counts = assemble_dataset()
    total_train = sum(counts.values())
    total_hold = sum(holdout_counts.values())

    if not total_train:
        log("No training images found. Nothing to do.")
        return 1

    report_balance(counts)
    log(f"Training images: {total_train} | holdout: {total_hold} | classes: {len(counts)}")

    if args.dry_run:
        log("Dry run - stopping before training.")
        return 0

    try:
        import tensorflow as tf
    except ImportError:
        log("TensorFlow is not installed in this environment.")
        log("Retraining must run on a machine with TF (not the deployed backend).")
        return 1

    train_ds, val_ds, class_names = build_datasets(tf)
    log(f"Classes: {class_names}")

    model, base = build_model(tf, len(class_names))

    log(f"Phase 1: warm-up head ({WARMUP_EPOCHS} epochs)")
    model.compile(optimizer=tf.keras.optimizers.Adam(1e-3),
                  loss="binary_crossentropy", metrics=["accuracy"])
    model.fit(train_ds, validation_data=val_ds, epochs=WARMUP_EPOCHS)

    log(f"Phase 2: fine-tune top layers ({FINETUNE_EPOCHS} epochs)")
    base.trainable = True
    for layer in base.layers[:-30]:
        layer.trainable = False
    model.compile(optimizer=tf.keras.optimizers.Adam(1e-5),
                  loss="binary_crossentropy", metrics=["accuracy"])
    model.fit(train_ds, validation_data=val_ds, epochs=FINETUNE_EPOCHS)

    log("Scoring against the frozen holdout set...")
    new_accuracy = evaluate_holdout(tf, model, class_names)
    old_accuracy = evaluate_existing_tflite(class_names)

    log("")
    log("=" * 52)
    log(f"  current model : {f'{old_accuracy:.2%}' if old_accuracy is not None else 'n/a'}")
    log(f"  new model     : {f'{new_accuracy:.2%}' if new_accuracy is not None else 'n/a'}")
    log("=" * 52)

    promote = True
    reason = "No baseline to compare against; promoting."
    if old_accuracy is not None and new_accuracy is not None:
        if new_accuracy >= old_accuracy:
            reason = f"New model improves on the current one by {new_accuracy - old_accuracy:+.2%}."
        elif args.force:
            promote = True
            reason = f"REGRESSION of {new_accuracy - old_accuracy:+.2%}, promoted anyway via --force."
        else:
            promote = False
            reason = (f"New model is {old_accuracy - new_accuracy:.2%} worse. "
                      f"Not promoting. Re-run with --force to override.")

    log(reason)

    metrics = {
        "timestamp": datetime.now().isoformat(),
        "training_images": total_train,
        "holdout_images": total_hold,
        "classes": class_names,
        "class_counts": counts,
        "previous_accuracy": old_accuracy,
        "new_accuracy": new_accuracy,
        "promoted": promote,
        "reason": reason,
    }
    METRICS_PATH.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    if not promote:
        log(f"Metrics written to {METRICS_PATH.name}. Serving model left untouched.")
        return 2

    log("Exporting model...")
    model.save(KERAS_MODEL_PATH)

    tflite_bytes = export_tflite(tf, model)
    TFLITE_MODEL_PATH.write_bytes(tflite_bytes)
    log(f"Wrote {TFLITE_MODEL_PATH.name} ({len(tflite_bytes) / 1_000_000:.2f} MB)")

    with open(LABELS_PATH, "w", encoding="utf-8") as f:
        for index, name in enumerate(class_names):
            f.write(f"{index} {name}\n")
    log(f"Wrote {LABELS_PATH.name} with {len(class_names)} classes")

    log("Done. Restart the backend to serve the new model.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
