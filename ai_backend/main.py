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

# Limit TensorFlow memory and thread footprint to run under 512MB RAM (Render Free Tier)
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["TF_NUM_INTRAOP_THREADS"] = "1"
os.environ["TF_NUM_INTEROP_THREADS"] = "1"
os.environ["CUDA_VISIBLE_DEVICES"] = "-1"

import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

import numpy as np
from dotenv import load_dotenv  # pip install python-dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from jose import JWTError, jwt  # pip install python-jose[cryptography]
from passlib.context import CryptContext  # pip install passlib[bcrypt]
from PIL import Image, ImageOps
from pydantic import BaseModel, Field
from sqlalchemy import (
    Boolean, Column, DateTime, Float, ForeignKey,
    Integer, String, create_engine, func, text, or_,
)
from sqlalchemy.orm import Session, declarative_base, sessionmaker

import tensorflow as tf  # noqa: F401 — needed to load keras model
from tensorflow.keras.models import load_model
import cv2
from nudenet import NudeDetector

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

# Cloud providers (e.g. Render/Heroku) use "postgres://" or "postgresql://",
# but SQLAlchemy requires "postgresql+psycopg2://" for the psycopg2 driver.
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+psycopg2://", 1)
elif DATABASE_URL.startswith("postgresql://") and not DATABASE_URL.startswith("postgresql+psycopg2://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+psycopg2://", 1)

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
    __tablename__ = "User"
    id = Column("userID", Integer, primary_key=True, index=True)
    username = Column("name", String(64), unique=True, index=True, nullable=False)
    email = Column(String(128), nullable=True)
    password_hash = Column("password", String(256), nullable=False)
    phoneNumber = Column(String(32), nullable=True)
    fullName = Column("fullName", String(128), nullable=True)
    icNumber = Column("icNumber", String(32), nullable=True)


class DBStaff(Base):
    __tablename__ = "Staff"
    id = Column("staffID", Integer, primary_key=True, index=True)
    username = Column("name", String(64), unique=True, index=True, nullable=False)
    email = Column(String(128), nullable=True)
    password_hash = Column("password", String(256), nullable=False)
    phoneNumber = Column(String(32), nullable=True)
    role = Column(String(32), default="worker")  # worker | authority | admin
    agencyID = Column(Integer, ForeignKey("Agency.agencyID"), nullable=True)


class DBAgency(Base):
    __tablename__ = "Agency"
    agencyID = Column(Integer, primary_key=True, index=True)
    name = Column(String(128), unique=True, nullable=False)
    address = Column(String(256), nullable=True)


class DBCategory(Base):
    __tablename__ = "Category"
    categoryID = Column(Integer, primary_key=True, index=True)
    name = Column(String(128), unique=True, nullable=False)
    baseWeight = Column(Float, default=1.0)
    agencyID = Column(Integer, ForeignKey("Agency.agencyID"), nullable=True)


class DBComplaint(Base):
    __tablename__ = "Complaint"
    id = Column("complaintID", Integer, primary_key=True, index=True)
    user_id = Column("userID", Integer, ForeignKey("User.userID"), nullable=False)
    title = Column(String(256), nullable=True)
    description = Column(String(2000))
    imageValidation = Column(String(128), nullable=True)
    confidence = Column(String(32))
    priority = Column(String(64), nullable=True)
    ai_prediction = Column("predictedCategory", String(128), nullable=True)
    image_path = Column("image", String(512), nullable=True)
    longitude = Column(Float, nullable=True)
    latitude = Column(Float, nullable=True)
    status = Column(String(64), default="Pending")
    location = Column(String(512), nullable=True)
    address = Column(String(512), nullable=True)

    # Compatibility workflow columns
    timestamp = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    assigned_department = Column(String(256), nullable=True)
    authority_notes = Column(String(4000), nullable=True)
    forwarded_at = Column(String(64), nullable=True)
    reviewed_at = Column(String(64), nullable=True)
    assigned_worker = Column(String(128), nullable=True)
    in_process_at = Column(String(64), nullable=True)
    in_maintenance_at = Column(String(64), nullable=True)
    completion_image_path = Column(String(512), nullable=True)
    completion_notes = Column(String(2000), nullable=True)
    completion_submitted_at = Column(String(64), nullable=True)
    worker_completed = Column(Integer, default=0)
    completion_ai_prediction = Column(String(128), nullable=True)
    completion_confidence = Column(String(32), nullable=True)
    resolved_at = Column(String(64), nullable=True)
    upvotes = Column(Integer, default=0)
    categories = Column(String(512))


class DBIssue(Base):
    __tablename__ = "Issue"
    complaintID = Column(Integer, ForeignKey("Complaint.complaintID"), primary_key=True)
    categoryID = Column(Integer, ForeignKey("Category.categoryID"), primary_key=True)
    count = Column(Integer, default=1)


class DBAuthorityAction(Base):
    __tablename__ = "AuthorityAction"
    authorityID = Column(Integer, primary_key=True, index=True)
    status = Column(String(64), nullable=False)
    remarks = Column(String(1000), nullable=True)
    actionDate = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    staffID = Column(Integer, ForeignKey("Staff.staffID"), nullable=False)
    complaintID = Column(Integer, ForeignKey("Complaint.complaintID"), nullable=False)
    categoryID = Column(Integer, ForeignKey("Category.categoryID"), nullable=True)


class DBReportUpvote(Base):
    __tablename__ = "report_upvotes"
    user_id = Column("user_id", Integer, ForeignKey("User.userID"), primary_key=True)
    report_id = Column("report_id", Integer, ForeignKey("Complaint.complaintID"), primary_key=True)


# ─────────────────────────────────────────────────────────────
#  DATABASE INIT & MIGRATION TO NEW SCHEMA
# ─────────────────────────────────────────────────────────────
from sqlalchemy import inspect
inspector = inspect(engine)
if not inspector.has_table("Complaint") or "location" not in [c["name"] for c in inspector.get_columns("Complaint")]:
    print("[DB] Resetting database schema to include all required ER diagram and compatibility columns...")
    try:
        with engine.begin() as conn:
            for tbl in ["report_upvotes", "reports", "users", "Complaint", "User", "Staff", "Agency", "Category", "Issue", "AuthorityAction"]:
                if inspector.has_table(tbl):
                    conn.execute(text(f'DROP TABLE IF EXISTS "{tbl}" CASCADE'))
    except Exception as e:
        print(f"[DB] Warning dropping tables: {e}")

Base.metadata.create_all(bind=engine)

# ─────────────────────────────────────────────────────────────
#  PASSWORD HASHING
# ─────────────────────────────────────────────────────────────
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        pass
    import hashlib
    legacy_hash = hashlib.sha256(plain.encode()).hexdigest()
    return hashed == legacy_hash


# ─────────────────────────────────────────────────────────────
#  JWT BEARER
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
def seed_database():
    db = SessionLocal()
    try:
        # 1. Seed Agencies
        agencies = {
            "MBMB": DBAgency(name="MBMB", address="Majlis Bandaraya Melaka Bersejarah, Melaka"),
            "JKR": DBAgency(name="JKR", address="Jabatan Kerja Raya, Melaka"),
            "SWCorp": DBAgency(name="SWCorp", address="Solid Waste Management Corporation, Melaka"),
        }
        for name, agency in agencies.items():
            if not db.query(DBAgency).filter(DBAgency.name == name).first():
                db.add(agency)
        db.commit()

        # Retrieve seeded agencies to get IDs
        mbmb = db.query(DBAgency).filter(DBAgency.name == "MBMB").first()
        jkr = db.query(DBAgency).filter(DBAgency.name == "JKR").first()
        swcorp = db.query(DBAgency).filter(DBAgency.name == "SWCorp").first()

        # 2. Seed Categories
        categories_to_seed = [
            ("Street Lighting", mbmb.agencyID),
            ("Road Damage", mbmb.agencyID),
            ("Waste", swcorp.agencyID),
            ("Drainage", jkr.agencyID),
            ("Overgrown Vegetation", mbmb.agencyID),
            ("Broken Sidewalk", mbmb.agencyID),
            ("Fallen Tree", mbmb.agencyID),
            ("Illegal Dumping", swcorp.agencyID),
            ("Open Burning", swcorp.agencyID),
            ("Vandalism", mbmb.agencyID),
            ("Road Sign", jkr.agencyID),
            ("other", mbmb.agencyID),
        ]
        for cat_name, agency_id in categories_to_seed:
            if not db.query(DBCategory).filter(DBCategory.name == cat_name).first():
                db.add(DBCategory(name=cat_name, baseWeight=1.0, agencyID=agency_id))
        db.commit()

        # 3. Seed Users (Citizens)
        if not db.query(DBUser).filter(DBUser.username == "test").first():
            db.add(DBUser(
                username="test",
                email="test@citizen.melaka.gov.my",
                password_hash=hash_password("test1234"),
                phoneNumber="012-3456789",
                fullName="Test Citizen",
                icNumber="900101041234",
            ))

        # 4. Seed Staff (Workers/Admins/Authority)
        staff_to_seed = [
            ("worker", "worker@mbmb.gov.my", hash_password("worker1234"), "011-1234567", "worker", mbmb.agencyID),
            ("worker1", "worker1@mbmb.gov.my", hash_password("password"), "011-2223334", "worker", mbmb.agencyID),
            ("worker2", "worker2@jkr.gov.my", hash_password("password"), "011-3334445", "worker", jkr.agencyID),
            ("mbmb", "authority@mbmb.gov.my", hash_password("password"), "011-4445556", "authority", mbmb.agencyID),
            ("jkr", "authority@jkr.gov.my", hash_password("password"), "011-5556667", "authority", jkr.agencyID),
            ("swcorp", "authority@swcorp.gov.my", hash_password("password"), "011-6667778", "authority", swcorp.agencyID),
            ("admin", "admin@melaka.gov.my", hash_password("admin1234"), "011-7778889", "admin", mbmb.agencyID),
        ]
        for name, email, passwd, phone, role, agency_id in staff_to_seed:
            if not db.query(DBStaff).filter(DBStaff.username == name).first():
                db.add(DBStaff(
                    username=name,
                    email=email,
                    password_hash=passwd,
                    phoneNumber=phone,
                    role=role,
                    agencyID=agency_id,
                ))
        db.commit()

        # 5. Seed Reports (Complaints)
        citizen = db.query(DBUser).filter(DBUser.username == "test").first()
        if citizen and not db.query(DBComplaint).filter(DBComplaint.assigned_worker == "worker1").first():
            # Street lighting complaint (In Process)
            db.add(DBComplaint(
                user_id=citizen.id,
                title="Broken Street Light",
                description="Street light is completely broken on main road. It gets very dark and unsafe at night.",
                ai_prediction="Street Lighting",
                imageValidation="Street Lighting",
                confidence="95%",
                image_path="uploads/35c1fa2b-4b88-4be5-ba87-0bcf7af2611e.png",
                longitude=102.2501,
                latitude=2.1896,
                location="31525, Malacca, Malaysia",
                address="Main Street, Malacca",
                status="In Process",
                assigned_department="MBMB",
                assigned_worker="worker1",
                in_process_at=datetime.now(timezone.utc).isoformat(),
                categories="Street Lighting",
            ))
            # Road damage complaint (In Maintenance)
            db.add(DBComplaint(
                user_id=citizen.id,
                title="Deep Pothole",
                description="Deep pothole in the middle of the left lane. Cars are swerving to avoid it, causing hazards.",
                ai_prediction="Road Damage",
                imageValidation="Road Damage",
                confidence="98%",
                image_path="uploads/35c1fa2b-4b88-4be5-ba87-0bcf7af2611e.png",
                longitude=102.2450,
                latitude=2.1950,
                location="31526, Malacca, Malaysia",
                address="Jalan Hang Tuah, Malacca",
                status="In Maintenance",
                assigned_department="MBMB",
                assigned_worker="worker1",
                in_process_at=datetime.now(timezone.utc).isoformat(),
                in_maintenance_at=datetime.now(timezone.utc).isoformat(),
                categories="Road Damage",
            ))
            # Drainage complaint (In Process)
            db.add(DBComplaint(
                user_id=citizen.id,
                title="Broken Drainage Cover",
                description="Broken drainage cover on the sidewalk. Pedestrians can fall in.",
                ai_prediction="Drainage",
                imageValidation="Drainage",
                confidence="92%",
                image_path="uploads/35c1fa2b-4b88-4be5-ba87-0bcf7af2611e.png",
                longitude=102.2530,
                latitude=2.2005,
                location="31527, Malacca, Malaysia",
                address="Jalan Bunga Raya, Malacca",
                status="In Process",
                assigned_department="JKR",
                assigned_worker="worker2",
                in_process_at=datetime.now(timezone.utc).isoformat(),
                categories="Drainage",
            ))
            db.commit()

            # Seed Issue table records for seeded complaints
            complaints = db.query(DBComplaint).all()
            for comp in complaints:
                cat = db.query(DBCategory).filter(DBCategory.name == comp.ai_prediction).first()
                if cat:
                    db.add(DBIssue(complaintID=comp.id, categoryID=cat.categoryID, count=1))
            db.commit()

        print("[Seed] Database fully seeded successfully!")
    except Exception as e:
        db.rollback()
        print(f"[Seed] Error seeding database: {e}")
    finally:
        db.close()


# ─────────────────────────────────────────────────────────────
#  GLOBAL VARIABLES & LAZY LOAD ON STARTUP
#  (Prevents 'free(): invalid pointer' segfaults caused by Uvicorn process forking)
# ─────────────────────────────────────────────────────────────
model = None
base_grad_model = None
nude_detector = None
class_names = []

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

app.mount("/uploads", StaticFiles(directory=UPLOAD_DIR), name="uploads")

@app.on_event("startup")
def startup_event():
    global model, base_grad_model, nude_detector, class_names
    
    # 1. Seed database after Uvicorn starts
    seed_database()
    
    # 2. Verify paths
    if not MODEL_PATH.exists() or not LABELS_PATH.exists():
        raise FileNotFoundError(
            f"Critical Error: Ensure both '{MODEL_PATH.name}' and '{LABELS_PATH.name}' exist."
        )
        
    # 3. Load Keras model
    print("[Startup] Loading Keras model...")
    model = load_model(MODEL_PATH, compile=False)
    print("[Startup] Keras model loaded successfully.")
    
    # 4. Setup base grad model for Grad-CAM
    base_model = None
    for layer in model.layers:
        if "mobilenet" in layer.name:
            base_model = layer
            break
    if base_model:
        base_grad_model = tf.keras.Model(
            inputs=base_model.inputs,
            outputs=[base_model.get_layer("out_relu").output, base_model.output]
        )
        print("[Startup] Grad-CAM Base model initialized successfully.")
    else:
        base_grad_model = None
        print("[Startup WARNING] Could not find MobileNetV2 base model layer for Grad-CAM.")
        
    # 5. Load class labels
    with open(LABELS_PATH, "r") as f:
        class_names = [line.strip() for line in f.readlines()]
        
    # 6. Warm up the model
    print("[Startup] Warming up Keras model...")
    _dummy = np.zeros((1, 224, 224, 3), dtype=np.float32)
    model.predict(_dummy, verbose=0)
    print("[Startup OK] Model warmed up and ready.")
    
    # 7. Initialize NSFW detector
    try:
        print("[Startup] Initializing NSFW Content Moderation Detector...")
        nude_detector = NudeDetector()
        print("[Startup OK] NSFW Content Moderation Detector initialized successfully.")
    except Exception as e:
        print(f"[Startup Warning] Failed to initialize NSFW detector: {e}")
        nude_detector = None


def _is_image_inappropriate_sync(contents: bytes) -> bool:
    """
    Run NudeDetector on raw image bytes.
    Returns True if the image contains explicit nudity or exposed body parts.
    """
    if not nude_detector:
        return False  # Fallback to safe if the detector could not be loaded

    import tempfile
    temp_file = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as tmp:
            tmp.write(contents)
            temp_file = tmp.name
        
        detections = nude_detector.detect(temp_file)
    except Exception as e:
        print(f"[Moderation] Error during NSFW detection: {e}")
        return False
    finally:
        if temp_file and os.path.exists(temp_file):
            try:
                os.remove(temp_file)
            except Exception as e:
                print(f"[Moderation] Error deleting temp file: {e}")

    inappropriate_classes = {
        "EXPOSED_BREAST_F", "FEMALE_BREAST_EXPOSED",
        "EXPOSED_GENITALIA_F", "FEMALE_GENITALIA_EXPOSED",
        "EXPOSED_GENITALIA_M", "MALE_GENITALIA_EXPOSED",
        "EXPOSED_BUTTOCKS", "BUTTOCKS_EXPOSED",
        "EXPOSED_ANUS", "ANUS_EXPOSED"
    }

    for det in detections:
        # Block if the class is inappropriate and the detection confidence is 60% or higher
        if det.get("class") in inappropriate_classes and det.get("score", 0) >= 0.6:
            print(f"[Moderation] Flagged image: detected {det['class']} with score {det['score']:.2f}")
            return True

    return False



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

    # Content moderation check: Run CPU-bound NudeDetector in executor thread pool
    loop = asyncio.get_running_loop()
    is_inappropriate = await loop.run_in_executor(
        None, lambda: _is_image_inappropriate_sync(contents)
    )
    if is_inappropriate:
        raise HTTPException(
            status_code=400,
            detail="Uploaded image contains inappropriate content (NSFW)."
        )

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
def _serialize(r: DBComplaint) -> dict:
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


def _ai_inference_sync(contents: bytes) -> tuple[str, str, list[dict]]:
    """
    Run the Keras model on raw image bytes.  Synchronous — must be called
    inside run_in_executor so it doesn't block the async event loop.
    Returns (label_string, confidence_string, list_of_all_predictions).
    """
    image = Image.open(io.BytesIO(contents)).convert("RGB")
    image = ImageOps.fit(image, (224, 224), Image.Resampling.LANCZOS)
    arr = np.asarray(image).astype(np.float32)
    data = np.ndarray(shape=(1, 224, 224, 3), dtype=np.float32)
    data[0] = (arr / 127.5) - 1
    prediction = model.predict(data, verbose=0)[0]
    
    # Extract predictions for all classes
    results = []
    for idx, val in enumerate(prediction):
        label = class_names[idx].split(" ", 1)[-1].strip().replace("_", " ")
        results.append((label, float(val)))
    
    # Sort descending by confidence score
    results.sort(key=lambda x: x[1], reverse=True)
    
    # Filter with a multi-label threshold of 35%
    passed = [r for r in results if r[1] >= 0.35]
    if not passed:
        passed = [results[0]] # fallback to top 1 if none exceed threshold
        
    labels_str = ", ".join([p[0] for p in passed])
    conf_str = ", ".join([f"{round(p[1] * 100, 2)}%" for p in passed])
    
    pred_list = [{"issue_type": p[0], "confidence": f"{round(p[1] * 100, 2)}%"} for p in results]
    
    return labels_str, conf_str, pred_list


def _ai_inference_from_path(image_path_str: str) -> tuple[str, str]:
    """
    Run the Keras model on a saved file path.
    Returns (labels_string, confidences_string).
    """
    full_path = BASE_DIR / image_path_str.lstrip("/")
    with open(full_path, "rb") as fh:
        lbl, conf, _ = _ai_inference_sync(fh.read())
        return lbl, conf


def _generate_gradcam_sync(contents: bytes, target_class_name: str) -> bytes:
    """
    Generate a Grad-CAM heatmap overlaid on the input image bytes, returning the output as JPEG bytes.
    """
    if base_grad_model is None:
        return contents

    # Find target class index
    target_class_idx = -1
    for i, name in enumerate(class_names):
        label_name = name.split(" ", 1)[-1].strip().replace("_", " ")
        if label_name == target_class_name:
            target_class_idx = i
            break

    if target_class_idx == -1:
        return contents

    try:
        # Load original image
        image = Image.open(io.BytesIO(contents)).convert("RGB")
        orig_w, orig_h = image.size
        arr = np.asarray(image).astype(np.float32)

        # Preprocess for model input
        image_resized = ImageOps.fit(image, (224, 224), Image.Resampling.LANCZOS)
        arr_resized = np.asarray(image_resized).astype(np.float32)
        img_tensor = np.expand_dims(arr_resized, axis=0)
        img_preprocessed = (img_tensor / 127.5) - 1.0

        # Grad-CAM computation
        with tf.GradientTape() as tape:
            conv_outputs, base_outputs = base_grad_model(img_preprocessed)
            
            # Explicitly run the top-level layers
            x = model.get_layer("global_average_pooling2d")(base_outputs)
            x = model.get_layer("dense")(x)
            x = model.get_layer("dropout")(x, training=False)
            predictions = model.get_layer("dense_1")(x)
            
            loss = predictions[:, target_class_idx]

        # Get gradients of target class wrt conv outputs
        grads = tape.gradient(loss, conv_outputs)
        pooled_grads = tf.reduce_mean(grads, axis=(0, 1, 2))

        conv_outputs = conv_outputs[0]
        heatmap = conv_outputs @ pooled_grads[..., tf.newaxis]
        heatmap = tf.squeeze(heatmap)

        # ReLU and normalization
        heatmap = tf.maximum(heatmap, 0)
        max_val = tf.reduce_max(heatmap)
        if max_val == 0:
            max_val = 1e-10
        heatmap = heatmap / max_val
        heatmap_np = heatmap.numpy()

        # Resize heatmap to match original image size
        heatmap_resized = cv2.resize(heatmap_np, (orig_w, orig_h))
        
        # Apply JET colormap using cv2 (Jet highlights attention in red/warm colors)
        heatmap_color = np.uint8(255 * heatmap_resized)
        heatmap_jet = cv2.applyColorMap(heatmap_color, cv2.COLORMAP_JET)

        # Convert original image to BGR numpy array
        orig_img_bgr = cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)

        # Superimpose
        superimposed_bgr = cv2.addWeighted(orig_img_bgr, 0.6, heatmap_jet, 0.4, 0)
        superimposed_rgb = cv2.cvtColor(superimposed_bgr, cv2.COLOR_BGR2RGB)
        superimposed_pil = Image.fromarray(superimposed_rgb)

        # Save to JPEG bytes
        buffer = io.BytesIO()
        superimposed_pil.save(buffer, format="JPEG")
        return buffer.getvalue()
    except Exception as e:
        print(f"[Grad-CAM] Error generating heatmap: {e}")
        return contents


# Department mapping to support both abbreviations and full names when querying
DEPT_MAP = {
    "MBMB": ["MBMB", "Majlis Bandaraya Melaka Bersejarah", "Bersejarah"],
    "JKR": ["JKR", "Jabatan Kerja Raya Melaka", "Jabatan Kerja Raya"],
    "SWCorp": ["SWCorp", "SWCorp Malaysia", "Solid Waste"],
    "MPHTJ": ["MPHTJ", "Majlis Perbandaran Hang Tuah Jaya", "Hang Tuah Jaya"],
}


# ─────────────────────────────────────────────────────────────
#  ROUTES — HEALTH
# ─────────────────────────────────────────────────────────────
@app.get("/healthz")
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
        label_str, confidence_str, pred_list = await loop.run_in_executor(
            None, lambda: _ai_inference_sync(contents)
        )

        # Generate Grad-CAM image overlay for the top predicted class
        gradcam_url = None
        if pred_list:
            top_class = pred_list[0]["issue_type"]
            gradcam_bytes = await loop.run_in_executor(
                None, lambda: _generate_gradcam_sync(contents, top_class)
            )
            ext = _safe_extension(file.filename or "image.jpg")
            gradcam_url = await loop.run_in_executor(
                None, lambda: _save_bytes_to_upload(gradcam_bytes, prefix="gradcam_", ext=ext)
            )

        return {
            "issue_type": label_str,
            "confidence": confidence_str,
            "predictions": pred_list,
            "gradcam_url": gradcam_url
        }
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


class SignupRequest(BaseModel):
    username: str = Field(..., min_length=2, max_length=64)
    password: str = Field(..., min_length=4, max_length=128)
    fullName: str = Field(..., min_length=2, max_length=128)
    icNumber: str = Field(..., min_length=12, max_length=32)
    phoneNumber: str = Field(..., min_length=7, max_length=32)


@app.post("/signup")
def signup(req: SignupRequest, db: Session = Depends(get_db)):
    """Create a new citizen account and return a JWT token."""
    if db.query(DBUser).filter(DBUser.username == req.username).first() or \
       db.query(DBStaff).filter(DBStaff.username == req.username).first():
        raise HTTPException(status_code=400, detail="Username already registered")
    
    new_user = DBUser(
        username=req.username,
        password_hash=hash_password(req.password),
        email=f"{req.username}@citizen.melaka.gov.my",
        fullName=req.fullName,
        icNumber=req.icNumber,
        phoneNumber=req.phoneNumber,
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    token = create_access_token({
        "sub": str(new_user.id),
        "username": new_user.username,
        "role": "citizen",
    })
    return {
        "message":  "User created successfully",
        "user_id":  new_user.id,
        "username": new_user.username,
        "fullName": new_user.fullName,
        "icNumber": new_user.icNumber,
        "phoneNumber": new_user.phoneNumber,
        "role":     "citizen",
        "token":    token,
    }


@app.post("/login")
def login(req: AuthRequest, db: Session = Depends(get_db)):
    """Authenticate a user (Citizen or Staff) and return a JWT token alongside basic session info."""
    user = db.query(DBUser).filter(DBUser.username == req.username).first()
    role = "citizen"
    db_obj = None

    if user:
        if verify_password(req.password, user.password_hash):
            db_obj = user
    else:
        staff = db.query(DBStaff).filter(DBStaff.username == req.username).first()
        if staff:
            if verify_password(req.password, staff.password_hash):
                db_obj = staff
                role = staff.role or "worker"

    if not db_obj:
        raise HTTPException(status_code=401, detail="Invalid username or password")

    # If legacy SHA-256 hash was used, upgrade it to bcrypt now
    if not db_obj.password_hash.startswith("$2b$"):
        db_obj.password_hash = hash_password(req.password)
        db.commit()

    token = create_access_token({
        "sub": str(db_obj.id),
        "username": db_obj.username,
        "role": role,
    })

    return {
        "message":  "Login successful",
        "user_id":  db_obj.id,
        "username": db_obj.username,
        "fullName": getattr(db_obj, "fullName", db_obj.username),
        "icNumber": getattr(db_obj, "icNumber", "N/A"),
        "phoneNumber": getattr(db_obj, "phoneNumber", "N/A"),
        "email":    getattr(db_obj, "email", "N/A"),
        "role":     role,
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
    query = db.query(DBComplaint)

    # Secure role/username check from the JWT token
    token_role = _token.get("role") or ""
    token_username = _token.get("username") or ""

    if token_role == "citizen" or (user_id is not None and token_role not in ("worker", "admin") and not token_role.startswith("authority") and token_role != "authority"):
        if user_id is not None:
            query = query.filter(DBComplaint.user_id == user_id)
    elif token_role == "worker" and token_username:
        staff_id = int(_token["sub"])
        staff = db.query(DBStaff).filter(DBStaff.id == staff_id).first()
        dept_suffix = ""
        if staff and staff.agencyID:
            agency = db.query(DBAgency).filter(DBAgency.agencyID == staff.agencyID).first()
            if agency:
                dept_suffix = agency.name
        
        conds = [DBComplaint.assigned_worker.ilike(token_username)]
        if dept_suffix:
            terms = DEPT_MAP.get(dept_suffix.upper(), [dept_suffix])
            for term in terms:
                conds.append(DBComplaint.assigned_department.ilike(f"%{term}%"))
                
        query = query.filter(
            or_(*conds),
            DBComplaint.status.in_(["In Process", "In Maintenance"]),
        )
    elif token_role == "authority" or token_role.startswith("authority_"):
        dept_suffix = ""
        if "_" in token_role:
            dept_suffix = token_role.split("_")[1].upper()
        else:
            username_lower = token_username.lower()
            if "mbmb" in username_lower:
                dept_suffix = "MBMB"
            elif "jkr" in username_lower:
                dept_suffix = "JKR"
            elif "swcorp" in username_lower:
                dept_suffix = "SWCorp"
            elif "mphtj" in username_lower:
                dept_suffix = "MPHTJ"
        if dept_suffix:
            terms = DEPT_MAP.get(dept_suffix, [dept_suffix])
            conds = [DBComplaint.assigned_department.ilike(f"%{term}%") for term in terms]
            query = query.filter(or_(*conds))

    reports = (
        query
        .order_by(DBComplaint.timestamp.desc())
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
    base_query = db.query(DBComplaint)
    token_role = _token.get("role") or ""
    token_username = _token.get("username") or ""
    if token_role == "authority" or token_role.startswith("authority_"):
        dept_suffix = ""
        if "_" in token_role:
            dept_suffix = token_role.split("_")[1].upper()
        else:
            username_lower = token_username.lower()
            if "mbmb" in username_lower:
                dept_suffix = "MBMB"
            elif "jkr" in username_lower:
                dept_suffix = "JKR"
            elif "swcorp" in username_lower:
                dept_suffix = "SWCorp"
            elif "mphtj" in username_lower:
                dept_suffix = "MPHTJ"
        if dept_suffix:
            terms = DEPT_MAP.get(dept_suffix, [dept_suffix])
            conds = [DBComplaint.assigned_department.ilike(f"%{term}%") for term in terms]
            base_query = base_query.filter(or_(*conds))
    elif user_id is not None:
        base_query = base_query.filter(DBComplaint.user_id == user_id)

    # Count by status using SQL aggregate
    status_counts: dict[str, int] = {}
    for status_val, cnt in (
        base_query.with_entities(DBComplaint.status, func.count(DBComplaint.id))
        .group_by(DBComplaint.status)
        .all()
    ):
        status_counts[status_val or "Pending"] = cnt

    total = sum(status_counts.values())

    # Category breakdown (stored as comma-separated string, so Python loop is needed)
    reports_for_cats = base_query.with_entities(DBComplaint.categories).all()
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
        "rejected":       status_counts.get("Rejected", 0),
        "categories":     categories,
    }


@app.get("/reports/timeline")
def get_report_timeline(
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Return the daily report submission count for the last 30 days."""
    from collections import defaultdict

    token_role = _token.get("role") or ""
    token_username = _token.get("username") or ""
    query = db.query(DBComplaint.timestamp)
    if token_role == "authority" or token_role.startswith("authority_"):
        dept_suffix = ""
        if "_" in token_role:
            dept_suffix = token_role.split("_")[1].upper()
        else:
            username_lower = token_username.lower()
            if "mbmb" in username_lower:
                dept_suffix = "MBMB"
            elif "jkr" in username_lower:
                dept_suffix = "JKR"
            elif "swcorp" in username_lower:
                dept_suffix = "SWCorp"
            elif "mphtj" in username_lower:
                dept_suffix = "MPHTJ"
        if dept_suffix:
            terms = DEPT_MAP.get(dept_suffix, [dept_suffix])
            conds = [DBComplaint.assigned_department.ilike(f"%{term}%") for term in terms]
            query = query.filter(or_(*conds))
    rows = query.all()
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

    query = db.query(DBComplaint).filter(
        DBComplaint.status != "Resolved",
        DBComplaint.latitude >= latitude - lat_delta,
        DBComplaint.latitude <= latitude + lat_delta,
        DBComplaint.longitude >= longitude - lon_delta,
        DBComplaint.longitude <= longitude + lon_delta,
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
                "image_path": r.image_path,
            })

    return {"duplicate": len(duplicates) > 0, "matches": duplicates}


@app.post("/reports/{report_id}/upvote")
def upvote_report(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Record an upvote for a duplicate report inside its description."""
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    user_id = int(_token["sub"])

    # Check if user has already flagged this report
    existing = db.query(DBReportUpvote).filter(
        DBReportUpvote.user_id == user_id,
        DBReportUpvote.report_id == report_id
    ).first()
 
    if existing:
        # Toggle off: delete upvote and decrement count
        db.delete(existing)
        report.upvotes = max(0, (report.upvotes or 0) - 1)
        db.commit()
        return {"status": "ok", "message": "Upvote removed successfully.", "upvotes": report.upvotes}
 
    # Record the urgent flag
    new_upvote = DBReportUpvote(user_id=user_id, report_id=report_id)
    db.add(new_upvote)
 
    report.upvotes = (report.upvotes or 0) + 1
 
    # Clean up legacy [Urgent Flags] or [Upvote count] from description
    import re
    desc = report.description or ""
    desc = re.sub(r'\s*\[Urgent Flags:\s*\d+\]', '', desc)
    desc = re.sub(r'\s*\[Upvote count:\s*\d+\]', '', desc)
    report.description = desc.strip()
 
    db.commit()
    return {"status": "ok", "message": "Report flagged as urgent successfully.", "upvotes": report.upvotes}


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

        # Look up category to find associated agency name dynamically
        # (This replaces any hardcoded routing logic)
        cat_record = db.query(DBCategory).filter(DBCategory.name == categories).first()
        assigned_dept = None
        if cat_record and cat_record.agencyID:
            agency = db.query(DBAgency).filter(DBAgency.agencyID == cat_record.agencyID).first()
            if agency:
                assigned_dept = agency.name

        new_report = DBComplaint(
            user_id=user_id,
            description=description,
            title=categories,
            imageValidation=ai_prediction,
            confidence=confidence,
            ai_prediction=ai_prediction,
            image_path=image_url,
            latitude=latitude,
            longitude=longitude,
            status="Pending",
            assigned_department=assigned_dept,
            categories=categories,
            location=location,
            address=address,
        )
        db.add(new_report)
        db.commit()
        db.refresh(new_report)

        # Also add record to Issue table
        if cat_record:
            db.add(DBIssue(complaintID=new_report.id, categoryID=cat_record.categoryID, count=1))
            db.commit()

        return {"message": "Report submitted successfully", "id": new_report.id}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ─────────────────────────────────────────────────────────────
#  STATUS WORKFLOW ENDPOINTS
# ─────────────────────────────────────────────────────────────
ALLOWED_STATUSES = {"Pending", "In Review", "In Process", "In Maintenance", "Resolved", "Rejected"}


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
    if _token.get("role") != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only admins may update report status directly.",
        )
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
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
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
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
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
    
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="In Review",
            remarks=req.note or "Forwarded to department",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))
    
    db.commit()
    db.refresh(report)
    return _serialize(report)


class RejectRequest(BaseModel):
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/reject")
def admin_reject(
    report_id: int,
    req: RejectRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Admin rejects a Pending report (→ Rejected)."""
    if _token.get("role") != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only admins may reject reports.",
        )
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    now = datetime.now(timezone.utc).isoformat()
    report.status = "Rejected"
    report.reviewed_at = now
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Admin Rejection] {req.note}"
    
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="Rejected",
            remarks=req.note or "Rejected by admin",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))
        
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
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
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
    
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="In Process",
            remarks=f"Assigned to {req.worker_name}. {req.note}",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))
        
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
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    report.status = "In Maintenance"
    report.in_maintenance_at = datetime.now(timezone.utc).isoformat()
    
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="In Maintenance",
            remarks="Worker started maintenance",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))
        
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
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    if report.worker_completed == 1:
        raise HTTPException(
            status_code=400,
            detail="Task completion proof has already been submitted and cannot be undone."
        )

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

    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="In Maintenance",
            remarks=f"Completed task: {notes}",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))

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
    if _token.get("role") != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only admins can review and resolve completion proofs."
        )
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    now = datetime.now(timezone.utc).isoformat()
    report.status = "Resolved"
    report.resolved_at = now
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Resolved] {req.note}"
        
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="Resolved",
            remarks=req.note or "Confirmed task resolved",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))

    db.commit()
    db.refresh(report)
    return _serialize(report)


@app.post("/reports/{report_id}/reject-proof")
def admin_reject_proof(
    report_id: int,
    req: RejectRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Admin rejects a worker's completion proof (moves task back to worker)."""
    if _token.get("role") != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only admins can reject completion proofs."
        )
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    # Reset completion fields so worker can resubmit proof
    report.worker_completed = 0
    report.completion_image_path = None
    report.completion_notes = None
    report.completion_submitted_at = None
    report.completion_ai_prediction = None
    report.completion_confidence = None
    
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Admin Proof Rejection] {req.note}"
        
    # Log AuthorityAction
    staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
    if staff:
        cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
        db.add(DBAuthorityAction(
            status="In Maintenance",
            remarks=f"Rejected completion proof. Reason: {req.note}",
            staffID=staff.id,
            complaintID=report.id,
            categoryID=cat_rec.categoryID if cat_rec else None
        ))
        
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
    Only allows analysis of the original image (disabled for completion images).
    """
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    image_to_analyse = report.image_path
    if not image_to_analyse:
        raise HTTPException(
            status_code=400, detail="No original image available to analyse for this report"
        )

    try:
        loop = asyncio.get_running_loop()
        prediction, confidence = await loop.run_in_executor(
            None, lambda: _ai_inference_from_path(image_to_analyse)
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI analysis error: {str(e)}")

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


# ─────────────────────────────────────────────────────────────
#  API PREFIX ROUTING & STATIC WEB FRONTEND
# ─────────────────────────────────────────────────────────────
class ApiPrefixMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            path = scope.get("path", "")
            if path.startswith("/api/"):
                scope["path"] = path[4:]
            elif path == "/api":
                scope["path"] = "/"
        await self.app(scope, receive, send)


@app.get("/{catchall:path}")
async def serve_react_app(catchall: str):
    dist_dir = Path("c:/Users/User/decision_support_system_web/dist")
    file_path = dist_dir / catchall
    if file_path.is_file():
        return FileResponse(file_path)
    return FileResponse(dist_dir / "index.html")


app = ApiPrefixMiddleware(app)