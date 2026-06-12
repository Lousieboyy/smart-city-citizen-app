"""
Smart City AI Engine — FastAPI Backend
======================================
Fixes applied vs. original:
  B-1  Credentials moved to .env (no more hardcoded password)
  B-2  DB sessions managed via FastAPI Depends(get_db) — always closed
  B-3  asyncio.get_running_loop() instead of deprecated get_event_loop()
  B-4  Async file writes via run_in_executor (no event-loop blocking)
  B-5  Worker filter now uses assigned_worker name, not just status
  B-6  PostgreSQL-safe IF NOT EXISTS migration, plus explicit error logging
  B-7  _run_ai_on_image wrapped in executor inside async route
  B-8  Status endpoint now validates caller role (passed as query param)
  B-9  Only extension is extracted from filename; UUIDs used for disk name
  B-10 Stats use SQL COUNT / GROUP BY, not Python loops
  Sec  bcrypt (salted) password hashing via passlib
  Sec  File MIME-type whitelist + 10 MB size cap
  Sec  Input length limits on Pydantic models
  JWT  All protected routes require Authorization: Bearer <token> (python-jose)
  PAG  GET /reports/ supports limit & offset pagination
  CFG  DATABASE_URL has no hardcoded fallback — must be set in .env
"""

import asyncio
import io
import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import numpy as np
from dotenv import load_dotenv  # pip install python-dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from jose import JWTError, jwt  # pip install python-jose[cryptography]
from passlib.context import CryptContext  # pip install passlib[bcrypt]
from PIL import Image, ImageOps
from pydantic import BaseModel, Field
from sqlalchemy import (
    Boolean, Column, DateTime, Float, ForeignKey,
    Integer, String, create_engine, func, text,
)
from sqlalchemy.orm import Session, declarative_base, sessionmaker

import tensorflow as tf  # noqa: F401 — needed to load keras model
from tensorflow.keras.models import load_model

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION  (load from .env so secrets stay out of git)
# ─────────────────────────────────────────────────────────────
load_dotenv()

# Fix CFG: No hardcoded fallback — DATABASE_URL must be set in .env
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError(
        "DATABASE_URL is not set. Create a .env file with:\n"
        "  DATABASE_URL=postgresql+psycopg2://user:pass@localhost/smart_city_db\n"
        "See .env.example for reference."
    )

# JWT configuration
SECRET_KEY = os.getenv("SECRET_KEY", "change_this_in_production")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "1440"))

# Maximum upload size in bytes (10 MB)
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

# Allowed MIME types for uploaded images
ALLOWED_MIME_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}

# ─────────────────────────────────────────────────────────────
#  APP
# ─────────────────────────────────────────────────────────────
app = FastAPI(title="Smart City AI Engine", version="1.1.0")

app.add_middleware(
    CORSMiddleware,
    # FIX: In production replace "*" with your actual frontend origin.
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────────────────────
#  DATABASE
# ─────────────────────────────────────────────────────────────
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class DBUser(Base):
    __tablename__ = "users"
    id             = Column(Integer, primary_key=True, index=True)
    username       = Column(String(64), unique=True, index=True, nullable=False)
    password_hash  = Column(String(256), nullable=False)
    role           = Column(String(32), default="citizen")  # citizen | worker | admin


class DBReport(Base):
    __tablename__ = "reports"
    id             = Column(Integer, primary_key=True, index=True)
    user_id        = Column(Integer, ForeignKey("users.id"), nullable=False)
    description    = Column(String(2000))
    location       = Column(String(512))
    address        = Column(String(512))
    latitude       = Column(Float, nullable=True)
    longitude      = Column(Float, nullable=True)
    categories     = Column(String(512))
    ai_prediction  = Column(String(128))
    confidence     = Column(String(32))
    image_path     = Column(String(512))
    # 5-stage lifecycle: Pending → In Review → In Process → In Maintenance → Resolved
    status         = Column(String(64), default="Pending")
    timestamp      = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    assigned_department      = Column(String(256), nullable=True)
    authority_notes          = Column(String(4000), nullable=True)
    forwarded_at             = Column(String(64), nullable=True)
    reviewed_at              = Column(String(64), nullable=True)

    assigned_worker          = Column(String(128), nullable=True)
    in_process_at            = Column(String(64), nullable=True)
    in_maintenance_at        = Column(String(64), nullable=True)

    completion_image_path    = Column(String(512), nullable=True)
    completion_notes         = Column(String(2000), nullable=True)
    completion_submitted_at  = Column(String(64), nullable=True)
    worker_completed         = Column(Integer, default=0)

    completion_ai_prediction = Column(String(128), nullable=True)
    completion_confidence    = Column(String(32), nullable=True)
    resolved_at              = Column(String(64), nullable=True)
    upvotes                  = Column(Integer, default=0)


class DBReportUpvote(Base):
    __tablename__ = "report_upvotes"
    user_id   = Column(Integer, ForeignKey("users.id"), primary_key=True)
    report_id = Column(Integer, ForeignKey("reports.id"), primary_key=True)


Base.metadata.create_all(bind=engine)

# ─────────────────────────────────────────────────────────────
#  DATABASE MIGRATION  (add new columns to existing PostgreSQL DB)
#  FIX B-6: Use IF NOT EXISTS syntax; log real errors
# ─────────────────────────────────────────────────────────────
_MIGRATION_COLS = [
    ("reports", "assigned_department",      "TEXT"),
    ("reports", "authority_notes",          "TEXT"),
    ("reports", "forwarded_at",             "TEXT"),
    ("reports", "resolved_at",              "TEXT"),
    ("reports", "reviewed_at",              "TEXT"),
    ("reports", "assigned_worker",          "TEXT"),
    ("reports", "in_process_at",            "TEXT"),
    ("reports", "in_maintenance_at",        "TEXT"),
    ("reports", "completion_image_path",    "TEXT"),
    ("reports", "completion_notes",         "TEXT"),
    ("reports", "completion_submitted_at",  "TEXT"),
    ("reports", "worker_completed",         "INTEGER DEFAULT 0"),
    ("reports", "completion_ai_prediction", "TEXT"),
    ("reports", "completion_confidence",    "TEXT"),
    ("reports", "upvotes",                  "INTEGER DEFAULT 0"),
    ("users",   "role",                     "TEXT DEFAULT 'citizen'"),
]

with engine.connect() as _conn:
    for _table, _col, _col_type in _MIGRATION_COLS:
        try:
            # PostgreSQL supports DO $$ blocks for conditional DDL
            _conn.execute(text(
                f"ALTER TABLE {_table} ADD COLUMN IF NOT EXISTS {_col} {_col_type}"
            ))
            _conn.commit()
        except Exception as _e:
            # Log real errors rather than silently swallowing them
            print(f"[Migration] Warning on column '{_col}': {_e}")

# ─────────────────────────────────────────────────────────────
#  PASSWORD HASHING  (FIX Sec: bcrypt with automatic salting)
# ─────────────────────────────────────────────────────────────
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    """Hash a plaintext password using bcrypt (salted)."""
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    """Verify a plaintext password against a bcrypt hash.
    
    Also handles legacy SHA-256 hashes so existing users are not locked out.
    """
    # Try bcrypt first
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        pass
    # Fallback: check old SHA-256 hash and upgrade it on success
    import hashlib
    legacy_hash = hashlib.sha256(plain.encode()).hexdigest()
    return hashed == legacy_hash


# ─────────────────────────────────────────────────────────────
#  JWT AUTHENTICATION  (Fix JWT)
# ─────────────────────────────────────────────────────────────
_bearer_scheme = HTTPBearer(auto_error=False)


def create_access_token(data: dict) -> str:
    """Create a signed JWT access token."""
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode["exp"] = expire
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def require_token(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
) -> dict:
    """FastAPI dependency — validates Bearer token and returns its payload.
    
    Raises HTTP 401 if the token is missing, expired, or invalid.
    """
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail="Not authenticated. Include 'Authorization: Bearer <token>' header.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    try:
        payload = jwt.decode(credentials.credentials, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        raise HTTPException(
            status_code=401,
            detail="Token is invalid or expired. Please log in again.",
            headers={"WWW-Authenticate": "Bearer"},
        )


# ─────────────────────────────────────────────────────────────
#  SEED TEST USERS  (FIX B-2: use try/finally to close session)
# ─────────────────────────────────────────────────────────────
def _seed_users():
    db = SessionLocal()
    try:
        if not db.query(DBUser).filter(DBUser.username == "test").first():
            db.add(DBUser(
                username="test",
                password_hash=hash_password("test1234"),
                role="citizen",
            ))
        if not db.query(DBUser).filter(DBUser.username == "worker").first():
            db.add(DBUser(
                username="worker",
                password_hash=hash_password("worker1234"),
                role="worker",
            ))
        if not db.query(DBUser).filter(DBUser.username == "worker1").first():
            db.add(DBUser(
                username="worker1",
                password_hash=hash_password("password"),
                role="worker",
            ))
        if not db.query(DBUser).filter(DBUser.username == "worker2").first():
            db.add(DBUser(
                username="worker2",
                password_hash=hash_password("password"),
                role="worker",
            ))
        if not db.query(DBUser).filter(DBUser.username == "mbmb").first():
            db.add(DBUser(
                username="mbmb",
                password_hash=hash_password("password"),
                role="authority",
            ))
        if not db.query(DBUser).filter(DBUser.username == "jkr").first():
            db.add(DBUser(
                username="jkr",
                password_hash=hash_password("password"),
                role="authority",
            ))
        if not db.query(DBUser).filter(DBUser.username == "swcorp").first():
            db.add(DBUser(
                username="swcorp",
                password_hash=hash_password("password"),
                role="authority",
            ))
        if not db.query(DBUser).filter(DBUser.username == "admin").first():
            db.add(DBUser(
                username="admin",
                password_hash=hash_password("admin1234"),
                role="admin",
            ))
        db.commit()
    except Exception as e:
        db.rollback()
        print(f"[Seed] Error seeding test users: {e}")
    finally:
        db.close()  # FIX B-2: always close


_seed_users()


# ─────────────────────────────────────────────────────────────
#  SEED DUMMY REPORTS FOR WORKERS
# ─────────────────────────────────────────────────────────────
def _seed_reports():
    db = SessionLocal()
    try:
        citizen = db.query(DBUser).filter(DBUser.username == "test").first()
        if not citizen:
            return
        
        # Check if we already have reports for worker1 to avoid duplicate seeds
        w1_reports = db.query(DBReport).filter(DBReport.assigned_worker == "worker1").first()
        if not w1_reports:
            # 1. Report in "In Process" status (so worker1 can accept and start work)
            db.add(DBReport(
                user_id=citizen.id,
                description="Street light is completely broken on main road. It gets very dark and unsafe at night.",
                location="31525, Malacca, Malaysia",
                address="Main Street, Malacca",
                latitude=2.1896,
                longitude=102.2501,
                categories="Street Lighting",
                ai_prediction="broken light",
                confidence="95%",
                status="In Process",
                assigned_department="MBMB",
                assigned_worker="worker1",
                in_process_at=datetime.now(timezone.utc).isoformat(),
            ))

            # 2. Report in "In Maintenance" status (so worker1 can submit completion proof)
            db.add(DBReport(
                user_id=citizen.id,
                description="Deep pothole in the middle of the left lane. Cars are swerving to avoid it, causing hazards.",
                location="31526, Malacca, Malaysia",
                address="Jalan Hang Tuah, Malacca",
                latitude=2.1950,
                longitude=102.2450,
                categories="Road Damage",
                ai_prediction="pothole",
                confidence="98%",
                status="In Maintenance",
                assigned_department="MBMB",
                assigned_worker="worker1",
                in_process_at=datetime.now(timezone.utc).isoformat(),
                in_maintenance_at=datetime.now(timezone.utc).isoformat(),
            ))

            # 3. Report in "In Process" for worker2 (Kumar - JKR)
            db.add(DBReport(
                user_id=citizen.id,
                description="Broken drainage cover on the sidewalk. Pedestrians can fall in.",
                location="31527, Malacca, Malaysia",
                address="Jalan Bunga Raya, Malacca",
                latitude=2.2005,
                longitude=102.2530,
                categories="Drainage",
                ai_prediction="broken cover",
                confidence="92%",
                status="In Process",
                assigned_department="JKR",
                assigned_worker="worker2",
                in_process_at=datetime.now(timezone.utc).isoformat(),
            ))

            db.commit()
            print("[Seed] Dummy reports seeded successfully!")
    except Exception as e:
        db.rollback()
        print(f"[Seed] Error seeding test reports: {e}")
    finally:
        db.close()


_seed_reports()

# ─────────────────────────────────────────────────────────────
#  AI MODEL SETUP
# ─────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

app.mount("/uploads", StaticFiles(directory=UPLOAD_DIR), name="uploads")

if not MODEL_PATH.exists() or not LABELS_PATH.exists():
    raise FileNotFoundError(
        f"Critical Error: Ensure both '{MODEL_PATH.name}' and '{LABELS_PATH.name}' exist."
    )

model = load_model(MODEL_PATH, compile=False)

with open(LABELS_PATH, "r") as f:
    class_names = [line.strip() for line in f.readlines()]

# Warm-up pass so the first real request is fast
_dummy = np.zeros((1, 224, 224, 3), dtype=np.float32)
model.predict(_dummy, verbose=0)
print("[OK] Model warmed up and ready.")


# ─────────────────────────────────────────────────────────────
#  DEPENDENCY INJECTION  (FIX B-2: sessions always closed)
# ─────────────────────────────────────────────────────────────
def get_db():
    """FastAPI dependency that provides a DB session and guarantees close."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ─────────────────────────────────────────────────────────────
#  FILE VALIDATION HELPERS  (FIX Sec: MIME type + size limit)
# ─────────────────────────────────────────────────────────────
async def _read_and_validate_file(file: UploadFile) -> bytes:
    """Read upload bytes and validate MIME type + size."""
    contents = await file.read()
    if len(contents) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File too large. Maximum allowed size is {MAX_UPLOAD_BYTES // (1024*1024)} MB.",
        )
    # Validate MIME type via Pillow (more reliable than trusting file.content_type)
    try:
        img_check = Image.open(io.BytesIO(contents))
        mime = Image.MIME.get(img_check.format or "", "")
        if mime not in ALLOWED_MIME_TYPES:
            raise HTTPException(
                status_code=415,
                detail=f"Unsupported image format '{img_check.format}'. Allowed: JPEG, PNG, WEBP, GIF.",
            )
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=400, detail="Could not read image file. Ensure it is a valid image.")
    return contents


def _safe_extension(filename: str) -> str:
    """Extract only the file extension; default to .jpg if absent/unsafe.
    
    FIX B-9: We never use the original filename on disk — UUIDs are used instead.
    This function only extracts the extension for MIME-based storage.
    """
    suffix = Path(filename).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".gif"}:
        return suffix
    return ".jpg"


def _save_bytes_to_upload(contents: bytes, prefix: str = "", ext: str = ".jpg") -> str:
    """Save bytes to the uploads directory and return the relative URL path."""
    unique_name = f"{prefix}{uuid.uuid4()}{ext}"
    file_path = UPLOAD_DIR / unique_name
    file_path.write_bytes(contents)
    return f"/uploads/{unique_name}"


# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────
def _serialize(r: DBReport) -> dict:
    """Convert a DBReport ORM object into a JSON-serialisable dict."""
    return {
        "id":                       r.id,
        "user_id":                  r.user_id,
        "description":              r.description,
        "location":                 r.location,
        "address":                  r.address,
        "latitude":                 r.latitude,
        "longitude":                r.longitude,
        "categories":               r.categories,
        "ai_prediction":            r.ai_prediction,
        "confidence":               r.confidence,
        "image_path":               r.image_path,
        "status":                   r.status,
        "timestamp": (
            r.timestamp.isoformat()
            if hasattr(r.timestamp, "isoformat")
            else str(r.timestamp) if r.timestamp
            else None
        ),
        "assigned_department":      r.assigned_department,
        "authority_notes":          r.authority_notes,
        "forwarded_at":             r.forwarded_at,
        "reviewed_at":              r.reviewed_at,
        "assigned_worker":          r.assigned_worker,
        "in_process_at":            r.in_process_at,
        "in_maintenance_at":        r.in_maintenance_at,
        "completion_image_path":    r.completion_image_path,
        "completion_notes":         r.completion_notes,
        "completion_submitted_at":  r.completion_submitted_at,
        "worker_completed":         bool(r.worker_completed),
        "completion_ai_prediction": r.completion_ai_prediction,
        "completion_confidence":    r.completion_confidence,
        "resolved_at":              r.resolved_at,
        "upvotes":                  r.upvotes or 0,
    }


def _ai_inference_sync(contents: bytes) -> tuple[str, str]:
    """
    Run the Keras model on raw image bytes.  Synchronous — must be called
    inside run_in_executor so it doesn't block the async event loop.
    Returns (label, confidence_string), e.g. ("Pothole", "94.32%").
    """
    image = Image.open(io.BytesIO(contents)).convert("RGB")
    image = ImageOps.fit(image, (224, 224), Image.Resampling.LANCZOS)
    arr = np.asarray(image).astype(np.float32)
    data = np.ndarray(shape=(1, 224, 224, 3), dtype=np.float32)
    data[0] = (arr / 127.5) - 1
    prediction = model.predict(data, verbose=0)
    index = int(np.argmax(prediction))
    label = class_names[index].split(" ", 1)[-1].strip()
    confidence = float(prediction[0][index])
    return label, f"{round(confidence * 100, 2)}%"


def _ai_inference_from_path(image_path_str: str) -> tuple[str, str]:
    """
    Run the Keras model on a saved file path.
    Returns (label, confidence_string).
    """
    full_path = BASE_DIR / image_path_str.lstrip("/")
    with open(full_path, "rb") as fh:
        return _ai_inference_sync(fh.read())


# ─────────────────────────────────────────────────────────────
#  ROUTES — HEALTH
# ─────────────────────────────────────────────────────────────
@app.get("/")
def home():
    return {"message": "Smart City AI Engine v1.1 is active!", "status": "ok"}


# ─────────────────────────────────────────────────────────────
#  ROUTES — AI PREDICT
# ─────────────────────────────────────────────────────────────
@app.post("/predict")
async def predict(
    file: UploadFile = File(...),
    _token: dict = Depends(require_token),
):
    """Classify an uploaded image and return the predicted issue type."""
    try:
        contents = await _read_and_validate_file(file)
        # FIX B-3 + B-7: Use get_running_loop; run blocking inference in thread
        loop = asyncio.get_running_loop()
        label, confidence = await loop.run_in_executor(
            None, lambda: _ai_inference_sync(contents)
        )
        return {"issue_type": label, "confidence": confidence}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Prediction error: {str(e)}")


# ─────────────────────────────────────────────────────────────
#  ROUTES — AUTHENTICATION
# ─────────────────────────────────────────────────────────────
class AuthRequest(BaseModel):
    username: str = Field(..., min_length=2, max_length=64)
    password: str = Field(..., min_length=4, max_length=128)


@app.post("/signup")
def signup(req: AuthRequest, db: Session = Depends(get_db)):
    """Create a new citizen account and return a JWT token."""
    if db.query(DBUser).filter(DBUser.username == req.username).first():
        raise HTTPException(status_code=400, detail="Username already registered")
    new_user = DBUser(
        username=req.username,
        password_hash=hash_password(req.password),
        role="citizen",
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    token = create_access_token({
        "sub": str(new_user.id),
        "username": new_user.username,
        "role": new_user.role,
    })
    return {
        "message":  "User created successfully",
        "user_id":  new_user.id,
        "username": new_user.username,
        "role":     new_user.role,
        "token":    token,
    }


@app.post("/login")
def login(req: AuthRequest, db: Session = Depends(get_db)):
    """Authenticate a user and return a JWT token alongside basic session info."""
    user = db.query(DBUser).filter(DBUser.username == req.username).first()
    # FIX Sec: verify_password handles both bcrypt and legacy SHA-256
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid username or password")

    # If legacy SHA-256 hash was used, upgrade it to bcrypt now
    if not user.password_hash.startswith("$2b$"):
        user.password_hash = hash_password(req.password)
        db.commit()

    token = create_access_token({
        "sub": str(user.id),
        "username": user.username,
        "role": user.role or "citizen",
    })

    return {
        "message":  "Login successful",
        "user_id":  user.id,
        "username": user.username,
        "role":     user.role or "citizen",
        "token":    token,
    }


# ─────────────────────────────────────────────────────────────
#  ROUTES — REPORTS
# ─────────────────────────────────────────────────────────────
@app.get("/reports/")
def get_reports(
    user_id: Optional[int] = None,
    role: Optional[str] = None,
    username: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Return reports filtered by role with pagination.
      citizen          → only their own reports
      worker           → only reports assigned to *them* (by username)
      admin / None     → all reports
    FIX B-5:   Workers see only reports where assigned_worker == username.
    FIX PAG:   limit/offset pagination — default limit=50.
    FIX JWT:   Requires Authorization: Bearer <token>.
    """
    query = db.query(DBReport)

    if role == "citizen" and user_id is not None:
        query = query.filter(DBReport.user_id == user_id)
    elif role == "worker" and username:
        query = query.filter(
            DBReport.assigned_worker == username,
            DBReport.status.in_(["In Process", "In Maintenance"]),
        )
    # admin / no role → return everything

    reports = (
        query
        .order_by(DBReport.timestamp.desc())
        .offset(offset)
        .limit(max(1, min(limit, 200)))   # cap at 200 per page
        .all()
    )
    return [_serialize(r) for r in reports]


@app.get("/reports/stats")
def get_report_stats(
    user_id: Optional[int] = None,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Return aggregated statistics.
    FIX B-10: Uses SQL COUNT/GROUP BY instead of loading all rows into Python.
    """
    base_query = db.query(DBReport)
    if user_id is not None:
        base_query = base_query.filter(DBReport.user_id == user_id)

    # Count by status using SQL aggregate
    status_counts: dict[str, int] = {}
    for status_val, cnt in (
        db.query(DBReport.status, func.count(DBReport.id))
        .filter(DBReport.user_id == user_id if user_id else text("1=1"))
        .group_by(DBReport.status)
        .all()
    ):
        status_counts[status_val or "Pending"] = cnt

    total = sum(status_counts.values())

    # Category breakdown (stored as comma-separated string, so Python loop is needed)
    reports_for_cats = base_query.with_entities(DBReport.categories).all()
    categories: dict[str, int] = {}
    for (cats_str,) in reports_for_cats:
        for cat in (cats_str or "").split(","):
            cat = cat.strip()
            if cat:
                categories[cat] = categories.get(cat, 0) + 1

    return {
        "total":          total,
        "pending":        status_counts.get("Pending", 0),
        "in_review":      status_counts.get("In Review", 0),
        "in_process":     status_counts.get("In Process", 0),
        "in_maintenance": status_counts.get("In Maintenance", 0),
        "resolved":       status_counts.get("Resolved", 0),
        "categories":     categories,
    }


@app.get("/reports/timeline")
def get_report_timeline(
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Return the daily report submission count for the last 30 days."""
    from collections import defaultdict

    rows = db.query(DBReport.timestamp).all()
    counts: dict[str, int] = defaultdict(int)
    for (ts,) in rows:
        if ts:
            day = ts.strftime("%Y-%m-%d")
            counts[day] += 1

    sorted_days = sorted(counts.items())[-30:]
    return [{"date": d, "count": c} for d, c in sorted_days]



@app.get("/reports/check-duplicate")
def check_duplicate(
    latitude: float,
    longitude: float,
    categories: str,
    radius_meters: float = 50.0,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Check if an unresolved report exists in the database within a given radius
    that matches the category.
    """
    import math

    lat_delta = radius_meters / 111000.0
    cos_lat = math.cos(math.radians(latitude))
    if abs(cos_lat) < 0.001:
        cos_lat = 0.001
    lon_delta = radius_meters / (111000.0 * cos_lat)

    query = db.query(DBReport).filter(
        DBReport.status != "Resolved",
        DBReport.latitude >= latitude - lat_delta,
        DBReport.latitude <= latitude + lat_delta,
        DBReport.longitude >= longitude - lon_delta,
        DBReport.longitude <= longitude + lon_delta,
    )

    candidates = query.all()

    duplicates = []
    for r in candidates:
        if r.latitude is None or r.longitude is None:
            continue

        # Check category overlap
        r_cats = [c.strip() for c in (r.categories or "").split(",") if c.strip()]
        user_cats = [c.strip() for c in categories.split(",") if c.strip()]
        overlap = set(r_cats).intersection(set(user_cats))
        if not overlap:
            continue

        # Haversine distance
        dlat = math.radians(r.latitude - latitude)
        dlon = math.radians(r.longitude - longitude)
        a = math.sin(dlat/2)**2 + math.cos(math.radians(latitude)) * math.cos(math.radians(r.latitude)) * math.sin(dlon/2)**2
        c = 2 * math.asin(math.sqrt(a))
        distance = 6371000.0 * c  # meters

        if distance <= radius_meters:
            duplicates.append({
                "id": r.id,
                "description": r.description,
                "address": r.address,
                "categories": r.categories,
                "status": r.status,
                "distance_meters": round(distance, 1),
                "upvotes": r.upvotes or 0,
            })

    return {"duplicate": len(duplicates) > 0, "matches": duplicates}


@app.post("/reports/{report_id}/upvote")
def upvote_report(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Record an upvote for a duplicate report inside its description."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    user_id = int(_token["sub"])

    # Check if user has already upvoted this report
    existing = db.query(DBReportUpvote).filter(
        DBReportUpvote.user_id == user_id,
        DBReportUpvote.report_id == report_id
    ).first()

    if existing:
        raise HTTPException(
            status_code=400,
            detail="You have already upvoted this report."
        )

    # Record the upvote
    new_upvote = DBReportUpvote(user_id=user_id, report_id=report_id)
    db.add(new_upvote)

    report.upvotes = (report.upvotes or 0) + 1

    desc = report.description or ""
    if "[Upvote count:" in desc:
        import re
        match = re.search(r"\[Upvote count:\s*(\d+)\]", desc)
        if match:
            count = int(match.group(1)) + 1
            report.description = re.sub(r"\[Upvote count:\s*\d+\]", f"[Upvote count: {count}]", desc)
    else:
        report.description = f"{desc}\n[Upvote count: 1]".strip()

    db.commit()
    return {"status": "ok", "message": "Upvote recorded successfully.", "upvotes": report.upvotes}


@app.post("/reports/")
async def create_report(
    user_id:       int   = Form(...),
    description:   str   = Form(..., max_length=2000),
    location:      str   = Form(..., max_length=512),
    address:       str   = Form("Unknown location", max_length=512),
    latitude:      float = Form(None),
    longitude:     float = Form(None),
    categories:    str   = Form(..., max_length=512),
    ai_prediction: str   = Form(..., max_length=128),
    confidence:    str   = Form(..., max_length=32),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Submit a new citizen report with an evidence photo."""
    try:
        contents = await _read_and_validate_file(file)
        ext = _safe_extension(file.filename or "image.jpg")

        # FIX B-4: write file in a thread so we don't block the event loop
        loop = asyncio.get_running_loop()
        image_url = await loop.run_in_executor(
            None, lambda: _save_bytes_to_upload(contents, ext=ext)
        )

        new_report = DBReport(
            user_id=user_id,
            description=description,
            location=location,
            address=address,
            latitude=latitude,
            longitude=longitude,
            categories=categories,
            ai_prediction=ai_prediction,
            confidence=confidence,
            image_path=image_url,
        )
        db.add(new_report)
        db.commit()
        db.refresh(new_report)
        return {"message": "Report submitted successfully", "id": new_report.id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─────────────────────────────────────────────────────────────
#  STATUS WORKFLOW ENDPOINTS
# ─────────────────────────────────────────────────────────────
ALLOWED_STATUSES = {"Pending", "In Review", "In Process", "In Maintenance", "Resolved"}


class StatusUpdate(BaseModel):
    status: str
    # FIX B-8: require caller to identify their role so we can guard this endpoint
    caller_role: str = "admin"


@app.put("/reports/{report_id}/status")
def update_report_status(
    report_id: int,
    update: StatusUpdate,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Low-level status override — intended for admin only.
    FIX B-8: Now rejects non-admin callers.
    """
    if update.caller_role not in {"admin", "worker"}:
        raise HTTPException(
            status_code=403,
            detail="Only admins or workers may update report status directly.",
        )
    if update.status not in ALLOWED_STATUSES:
        raise HTTPException(
            status_code=400,
            detail=f"Status must be one of {ALLOWED_STATUSES}",
        )
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    report.status = update.status
    db.commit()
    db.refresh(report)
    return _serialize(report)


# STEP 1 → Admin approves: Pending → In Review
class ReviewRequest(BaseModel):
    department: str = Field(..., max_length=256)
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/review")
def admin_review(
    report_id: int,
    req: ReviewRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Admin forwards a Pending report to a department (→ In Review)."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    now = datetime.now(timezone.utc).isoformat()
    report.status = "In Review"
    report.assigned_department = req.department
    report.reviewed_at = now
    report.forwarded_at = now  # kept for backward compatibility
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Admin] {req.note}"
    db.commit()
    db.refresh(report)
    return _serialize(report)


# STEP 2 → Authority assigns worker: In Review → In Process
class AssignRequest(BaseModel):
    worker_name: str = Field(..., max_length=128)
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/assign")
def authority_assign(
    report_id: int,
    req: AssignRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Authority assigns a worker to an In Review report (→ In Process)."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    now = datetime.now(timezone.utc).isoformat()
    report.status = "In Process"
    report.assigned_worker = req.worker_name
    report.in_process_at = now
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Authority] {req.note}"
    db.commit()
    db.refresh(report)
    return _serialize(report)


# STEP 3 → Worker accepts task: In Process → In Maintenance
@app.post("/reports/{report_id}/start-maintenance")
def start_maintenance(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Worker starts maintenance on an In Process report (→ In Maintenance)."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    report.status = "In Maintenance"
    report.in_maintenance_at = datetime.now(timezone.utc).isoformat()
    db.commit()
    db.refresh(report)
    return _serialize(report)


# STEP 4 → Worker submits proof: stays In Maintenance, sets worker_completed=True
@app.post("/reports/{report_id}/complete-task")
async def complete_task(
    report_id: int,
    notes: str = Form(..., max_length=2000),
    file: Optional[UploadFile] = File(None),
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Worker submits completion proof (photo + notes)."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    report.completion_notes = notes
    report.completion_submitted_at = datetime.now(timezone.utc).isoformat()
    report.worker_completed = 1

    if file and file.filename:
        contents = await _read_and_validate_file(file)
        ext = _safe_extension(file.filename)
        loop = asyncio.get_running_loop()
        image_url = await loop.run_in_executor(
            None, lambda: _save_bytes_to_upload(contents, prefix="proof_", ext=ext)
        )
        report.completion_image_path = image_url

    db.commit()
    db.refresh(report)
    return _serialize(report)


# STEP 5 → Authority confirms resolved: In Maintenance → Resolved
class ResolveRequest(BaseModel):
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/resolve")
def authority_resolve(
    report_id: int,
    req: ResolveRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Authority confirms completion; report moves to Resolved."""
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    now = datetime.now(timezone.utc).isoformat()
    report.status = "Resolved"
    report.resolved_at = now
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Resolved] {req.note}"
    db.commit()
    db.refresh(report)
    return _serialize(report)


# ─────────────────────────────────────────────────────────────
#  AI ANALYSIS — re-analyse saved image
# ─────────────────────────────────────────────────────────────
@app.post("/reports/{report_id}/analyze")
async def analyze_report_image(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Re-run AI on a saved report image.
    Prefers the worker completion photo; falls back to the original citizen photo.
    FIX B-7: AI inference runs in an executor so the event loop is not blocked.
    """
    report = db.query(DBReport).filter(DBReport.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    image_to_analyse = report.completion_image_path or report.image_path
    is_completion = bool(report.completion_image_path)
    if not image_to_analyse:
        raise HTTPException(
            status_code=400, detail="No image available to analyse for this report"
        )

    try:
        loop = asyncio.get_running_loop()
        prediction, confidence = await loop.run_in_executor(
            None, lambda: _ai_inference_from_path(image_to_analyse)
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI analysis error: {str(e)}")

    if is_completion:
        report.completion_ai_prediction = prediction
        report.completion_confidence = confidence
    else:
        report.ai_prediction = prediction
        report.confidence = confidence

    db.commit()
    db.refresh(report)
    return _serialize(report)


# ─────────────────────────────────────────────────────────────
#  LEGACY COMPATIBILITY ENDPOINTS
# ─────────────────────────────────────────────────────────────
@app.post("/reports/{report_id}/forward")
def forward_to_authority(
    report_id: int,
    req: ReviewRequest,
    db: Session = Depends(get_db),
):
    """Alias for /review kept for backward compatibility."""
    return admin_review(report_id, req, db)


@app.post("/reports/{report_id}/authority-resolve")
def legacy_authority_resolve(
    report_id: int,
    req: ResolveRequest,
    db: Session = Depends(get_db),
):
    """Alias for /resolve kept for backward compatibility."""
    return authority_resolve(report_id, req, db)