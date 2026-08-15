"""
Persistent storage for collected training samples, backed by a private GitHub repo.

Why GitHub and not the local filesystem: this backend runs on Vercel, where the
deployment bundle is read-only and /tmp is per-instance and wiped on every cold
start. Nothing written to disk survives, on any plan tier. A git repo gives
durable storage, a full history (so a bad batch can be reverted), and a working
tree that the offline retraining script can simply clone.

Uses stdlib urllib rather than requests, because requests is not in
requirements.txt and must not become a production dependency.
"""

import base64
import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime

logger = logging.getLogger("dataset_store")

GITHUB_API = "https://api.github.com"
REQUEST_TIMEOUT = 30

GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "").strip()
DATASET_REPO = os.getenv("DATASET_REPO", "").strip()      # "owner/repo"
DATASET_BRANCH = os.getenv("DATASET_BRANCH", "main").strip()

# Commit in batches. One commit per image would burn the rate limit and produce
# an unreadable history.
SYNC_BATCH_SIZE = int(os.getenv("DATASET_SYNC_BATCH_SIZE", "25"))


def is_configured():
    """True when a token and target repo are available."""
    return bool(GITHUB_TOKEN and DATASET_REPO)


def _request(method, path, payload=None):
    """Issue an authenticated GitHub API call. Returns parsed JSON or raises."""
    url = path if path.startswith("http") else f"{GITHUB_API}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None

    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {GITHUB_TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "smart-city-dataset-collector")
    if data:
        req.add_header("Content-Type", "application/json")

    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body) if body else {}


def _sample_path(sample):
    """dataset/<status>/<Class_Name>/<hash>.jpg -- hash-named so writes are idempotent."""
    status = sample.get("status", "pending")
    class_label = sample.get("class_label") or "Unsorted"
    name = f"{sample.get('image_hash') or 'nohash'}{sample.get('extension') or '.jpg'}"
    return f"dataset/{status}/{class_label}/{name}"


def push_samples(samples, message=None):
    """
    Commit a batch of prepared samples to the dataset repo in a single commit.

    Uses the Git Data API (blobs -> tree -> commit -> ref) rather than the
    Contents API, which can only write one file per commit.

    Args:
        samples: dicts from dataset_collector.build_sample, each carrying
            image_bytes, image_hash, class_label and status.

    Returns:
        {"status": "success"|"skipped"|"error", "committed": int, ...}
    """
    if not is_configured():
        return {
            "status": "skipped",
            "committed": 0,
            "message": "GITHUB_TOKEN / DATASET_REPO not configured; kept samples on local disk",
        }

    payload_samples = [s for s in samples if s.get("image_bytes")]
    if not payload_samples:
        return {"status": "skipped", "committed": 0, "message": "No samples with image data to push"}

    try:
        # 1. Where the branch currently points.
        ref = _request("GET", f"/repos/{DATASET_REPO}/git/ref/heads/{DATASET_BRANCH}")
        base_commit_sha = ref["object"]["sha"]
        base_commit = _request("GET", f"/repos/{DATASET_REPO}/git/commits/{base_commit_sha}")
        base_tree_sha = base_commit["tree"]["sha"]

        # 2. Upload each image as a blob.
        tree_entries = []
        for sample in payload_samples:
            blob = _request("POST", f"/repos/{DATASET_REPO}/git/blobs", {
                "content": base64.b64encode(sample["image_bytes"]).decode("ascii"),
                "encoding": "base64",
            })
            tree_entries.append({
                "path": _sample_path(sample),
                "mode": "100644",
                "type": "blob",
                "sha": blob["sha"],
            })

        # 3. Index shard for this batch.
        #
        # Sharded rather than appended to one index.jsonl on purpose: appending
        # would mean read-modify-write, and two concurrent syncs would silently
        # drop one another's records. The retrain script concatenates the shards.
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        index_lines = "\n".join(
            json.dumps({k: v for k, v in s.items() if k != "image_bytes"})
            for s in payload_samples
        )
        index_blob = _request("POST", f"/repos/{DATASET_REPO}/git/blobs", {
            "content": base64.b64encode((index_lines + "\n").encode("utf-8")).decode("ascii"),
            "encoding": "base64",
        })
        tree_entries.append({
            "path": f"dataset/index/{stamp}.jsonl",
            "mode": "100644",
            "type": "blob",
            "sha": index_blob["sha"],
        })

        # 4. Tree -> commit -> move the branch.
        tree = _request("POST", f"/repos/{DATASET_REPO}/git/trees", {
            "base_tree": base_tree_sha,
            "tree": tree_entries,
        })

        approved = sum(1 for s in payload_samples if s.get("status") == "approved")
        pending = sum(1 for s in payload_samples if s.get("status") == "pending")
        commit_message = message or (
            f"dataset: add {len(payload_samples)} samples "
            f"({approved} approved, {pending} pending)"
        )

        commit = _request("POST", f"/repos/{DATASET_REPO}/git/commits", {
            "message": commit_message,
            "tree": tree["sha"],
            "parents": [base_commit_sha],
        })

        _request("PATCH", f"/repos/{DATASET_REPO}/git/refs/heads/{DATASET_BRANCH}", {
            "sha": commit["sha"],
            "force": False,
        })

        logger.info(f"Pushed {len(payload_samples)} samples in commit {commit['sha'][:8]}")
        return {
            "status": "success",
            "committed": len(payload_samples),
            "approved": approved,
            "pending": pending,
            "commit_sha": commit["sha"],
            "commit_url": commit.get("html_url"),
            "message": commit_message,
        }

    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:400]
        logger.error(f"GitHub sync failed ({e.code}): {detail}")
        return {"status": "error", "committed": 0,
                "message": f"GitHub API error {e.code}: {detail}"}
    except Exception as e:
        logger.error(f"GitHub sync failed: {e}")
        return {"status": "error", "committed": 0, "message": str(e)}


def move_sample(sample, new_status):
    """
    Reflect an admin decision by moving a sample between status folders.

    Deletes the old path and writes the blob at the new one in a single commit.
    """
    if not is_configured():
        return {"status": "skipped", "message": "GitHub storage not configured"}

    old_path = _sample_path(sample)
    updated = dict(sample)
    updated["status"] = new_status
    new_path = _sample_path(updated)

    if old_path == new_path:
        return {"status": "skipped", "message": "Sample is already in that state"}

    try:
        existing = _request("GET", f"/repos/{DATASET_REPO}/contents/{old_path}?ref={DATASET_BRANCH}")
        blob_sha = existing["sha"]

        ref = _request("GET", f"/repos/{DATASET_REPO}/git/ref/heads/{DATASET_BRANCH}")
        base_commit_sha = ref["object"]["sha"]
        base_commit = _request("GET", f"/repos/{DATASET_REPO}/git/commits/{base_commit_sha}")

        tree = _request("POST", f"/repos/{DATASET_REPO}/git/trees", {
            "base_tree": base_commit["tree"]["sha"],
            "tree": [
                {"path": new_path, "mode": "100644", "type": "blob", "sha": blob_sha},
                # A null sha removes the path from the tree.
                {"path": old_path, "mode": "100644", "type": "blob", "sha": None},
            ],
        })

        commit = _request("POST", f"/repos/{DATASET_REPO}/git/commits", {
            "message": f"dataset: mark {sample.get('image_hash', '')[:8]} as {new_status}",
            "tree": tree["sha"],
            "parents": [base_commit_sha],
        })
        _request("PATCH", f"/repos/{DATASET_REPO}/git/refs/heads/{DATASET_BRANCH}", {
            "sha": commit["sha"], "force": False,
        })

        return {"status": "success", "from": old_path, "to": new_path,
                "commit_sha": commit["sha"]}

    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:300]
        logger.error(f"Could not move sample ({e.code}): {detail}")
        return {"status": "error", "message": f"GitHub API error {e.code}: {detail}"}
    except Exception as e:
        logger.error(f"Could not move sample: {e}")
        return {"status": "error", "message": str(e)}


def get_remote_stats():
    """Summarise what is actually stored in the dataset repo."""
    if not is_configured():
        return {"configured": False, "message": "GitHub storage not configured"}

    try:
        ref = _request("GET", f"/repos/{DATASET_REPO}/git/ref/heads/{DATASET_BRANCH}")
        tree = _request(
            "GET",
            f"/repos/{DATASET_REPO}/git/trees/{ref['object']['sha']}?recursive=1",
        )

        by_status = {}
        by_class = {}
        for node in tree.get("tree", []):
            path = node.get("path", "")
            if node.get("type") != "blob" or not path.startswith("dataset/"):
                continue
            parts = path.split("/")
            if len(parts) < 4 or parts[1] == "index":
                continue
            status, class_label = parts[1], parts[2]
            by_status[status] = by_status.get(status, 0) + 1
            if status == "approved":
                by_class[class_label] = by_class.get(class_label, 0) + 1

        return {
            "configured": True,
            "repo": DATASET_REPO,
            "branch": DATASET_BRANCH,
            "truncated": tree.get("truncated", False),
            "total": sum(by_status.values()),
            "by_status": by_status,
            "by_class": by_class,
        }
    except Exception as e:
        logger.error(f"Could not read remote stats: {e}")
        return {"configured": True, "error": str(e)}
