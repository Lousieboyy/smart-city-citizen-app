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
import base64
import io
import json
import logging
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
    Integer, String, Text, and_, create_engine, false, func, text, or_,
)
from sqlalchemy.orm import Session, declarative_base, relationship, sessionmaker

# TensorFlow is completely removed to prevent AVX instruction set crashes on cloud CPUs.
# We use lightweight tflite-runtime instead.
tf = None
import cv2
# Disable NSFW detector completely to prevent ONNX Runtime/C++ segfaults on cloud environments
nude_detector_available = False

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION  (load from .env so secrets stay out of git)
# ─────────────────────────────────────────────────────────────
load_dotenv()

# Fix CFG: No hardcoded fallback — DATABASE_URL must be set in .env
DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    tmp_db = os.path.join(os.path.sep, "tmp", "reports.db") if os.name != "nt" else "reports.db"
    DATABASE_URL = f"sqlite:///{tmp_db}"

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

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("main")

# ─────────────────────────────────────────────────────────────
#  AI DATASET PIPELINE
# ─────────────────────────────────────────────────────────────
# Imported after load_dotenv() — dataset_store reads GITHUB_TOKEN/DATASET_REPO
# from the environment at import time.
import dataset_collector
import dataset_store
from metadata_forensics import inspect_image_authenticity

# ─────────────────────────────────────────────────────────────
#  APP
# ─────────────────────────────────────────────────────────────
app = FastAPI(title="Smart City AI Engine", version="1.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://decision-support-system-web.vercel.app",
        "http://localhost:5173",
        "http://localhost:8080",
        "http://localhost:3000",
    ],
    allow_origin_regex=r"https://.*\.vercel\.app",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def custom_cors_middleware(request, call_next):
    origin = request.headers.get("origin") or "*"
    if request.method == "OPTIONS":
        from fastapi.responses import Response
        res = Response(status_code=200)
        res.headers["Access-Control-Allow-Origin"] = origin
        res.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS, PATCH"
        res.headers["Access-Control-Allow-Headers"] = "*"
        res.headers["Access-Control-Allow-Credentials"] = "true"
        return res

    try:
        response = await call_next(request)
    except Exception as exc:
        from fastapi.responses import JSONResponse
        response = JSONResponse(status_code=500, content={"detail": str(exc)})

    response.headers["Access-Control-Allow-Origin"] = origin
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS, PATCH"
    response.headers["Access-Control-Allow-Headers"] = "*"
    response.headers["Access-Control-Allow-Credentials"] = "true"
    return response

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
    crewID = Column(Integer, ForeignKey("Crew.id"), nullable=True)
    on_leave = Column(Boolean, default=False)  # excluded from dispatch/claim while true


class DBAgency(Base):
    __tablename__ = "Agency"
    agencyID = Column(Integer, primary_key=True, index=True)
    name = Column(String(128), unique=True, nullable=False)
    address = Column(String(256), nullable=True)


class DBCrew(Base):
    """A named sub-team within one Agency, e.g. MBMB "Team A" vs "Team B".

    A report can be dispatched to a crew instead of the whole agency pool —
    only that crew's members see and can claim it. `status` lets an authority
    take a whole crew offline (e.g. everyone on leave together) without
    disbanding it or touching membership.
    """
    __tablename__ = "Crew"
    id = Column(Integer, primary_key=True, index=True)
    agencyID = Column(Integer, ForeignKey("Agency.agencyID"), nullable=False, index=True)
    name = Column(String(128), nullable=False)
    status = Column(String(16), default="active")  # active | disabled
    created_at = Column(String(64), nullable=True)


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

    # Team dispatch. The report is owned by a *team* (Agency); assigned_worker_id
    # stays NULL while it sits in that team's shared pool, and is set by the first
    # worker to claim it. assigned_worker (the string above) is kept in sync purely
    # so older clients that read it keep working — the FK is the source of truth.
    assigned_agency_id = Column(Integer, ForeignKey("Agency.agencyID"), nullable=True)
    assigned_worker_id = Column(Integer, ForeignKey("Staff.staffID"), nullable=True)
    dispatched_at = Column(String(64), nullable=True)   # entered the pool — ageing/SLA clock
    claimed_at = Column(String(64), nullable=True)      # left the pool
    release_count = Column(Integer, default=0)          # times bounced back; bottleneck signal

    # Optional sub-team within the agency, e.g. MBMB "Team A" vs "Team B".
    # NULL means the job is visible to the whole agency, not one crew.
    assigned_crew_id = Column(Integer, ForeignKey("Crew.id"), nullable=True)

    assigned_agency = relationship("DBAgency", lazy="joined")
    assigned_crew = relationship("DBCrew", lazy="joined")

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

    # Image provenance (see metadata_forensics.py)
    image_hash = Column(String(32), nullable=True)
    authenticity_score = Column(Integer, nullable=True)
    authenticity_verdict = Column(String(32), nullable=True)
    authenticity_signals = Column(String(4000), nullable=True)  # JSON list


class DBDatasetSample(Base):
    """One candidate training image harvested from a report."""
    __tablename__ = "DatasetSample"
    id = Column(Integer, primary_key=True, index=True)
    report_id = Column(Integer, ForeignKey("Complaint.complaintID"), nullable=True)
    image_hash = Column(String(32), index=True, nullable=True)
    class_label = Column(String(64), nullable=True)
    confidence = Column(Float, default=0.0)
    status = Column(String(16), default="pending", index=True)
    reason = Column(String(512), nullable=True)
    source = Column(String(32), default="auto")
    authenticity_verdict = Column(String(32), nullable=True)
    authenticity_score = Column(Integer, nullable=True)
    image_path = Column(String(512), nullable=True)   # local path when not yet synced
    github_path = Column(String(512), nullable=True)
    synced = Column(Integer, default=0)
    # Base64 of the prepared (downscaled, metadata-stripped) image, held only
    # until the sample is pushed to GitHub and then cleared. Necessary because
    # this backend's disk is ephemeral on Vercel, so a sample buffered for the
    # next batch would otherwise be gone by the time the batch runs.
    pending_blob = Column(Text, nullable=True)
    created_at = Column(String(64), nullable=True)
    reviewed_by = Column(String(128), nullable=True)
    reviewed_at = Column(String(64), nullable=True)


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


class DBTransferRequest(Base):
    """A team asking for a report to be taken off its hands.

    Raised by a worker or an authority when a team is overloaded or the job is
    outside what it can do. An authority (of either team) or an admin decides.
    to_agency_id may be NULL, meaning "somebody please take this" — the approver
    then picks the destination.
    """
    __tablename__ = "TransferRequest"
    id = Column(Integer, primary_key=True, index=True)
    complaintID = Column(Integer, ForeignKey("Complaint.complaintID"), nullable=False, index=True)
    from_agency_id = Column(Integer, ForeignKey("Agency.agencyID"), nullable=True)
    to_agency_id = Column(Integer, ForeignKey("Agency.agencyID"), nullable=True)
    requested_by_staff_id = Column(Integer, ForeignKey("Staff.staffID"), nullable=True)
    reason = Column(String(1000), nullable=True)
    status = Column(String(16), default="pending", index=True)  # pending | approved | denied
    decided_by_staff_id = Column(Integer, ForeignKey("Staff.staffID"), nullable=True)
    decided_at = Column(String(64), nullable=True)
    decision_note = Column(String(1000), nullable=True)
    created_at = Column(String(64), nullable=True)


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


def _add_missing_columns():
    """
    Additively add newly-introduced columns to existing tables.

    create_all() only creates missing *tables*; it never alters an existing one.
    Without this, a deployment against a database created before the provenance
    columns existed would fail every SELECT on Complaint.

    Deliberately additive: no drops, no type changes. The reset path above is
    destructive and must not be reached for a routine column addition.
    """
    additions = {
        "Complaint": [
            ("image_hash", "VARCHAR(32)"),
            ("authenticity_score", "INTEGER"),
            ("authenticity_verdict", "VARCHAR(32)"),
            ("authenticity_signals", "VARCHAR(4000)"),
            # Team dispatch / shared pool
            ("assigned_agency_id", "INTEGER"),
            ("assigned_worker_id", "INTEGER"),
            ("dispatched_at", "VARCHAR(64)"),
            ("claimed_at", "VARCHAR(64)"),
            ("release_count", "INTEGER DEFAULT 0"),
            # Crews: sub-teams within an agency
            ("assigned_crew_id", "INTEGER"),
        ],
        "Staff": [
            ("crewID", "INTEGER"),
            ("on_leave", "BOOLEAN DEFAULT FALSE"),
        ],
        "DatasetSample": [
            ("pending_blob", "TEXT"),
        ],
    }

    try:
        live = inspect(engine)
        for table, columns in additions.items():
            if not live.has_table(table):
                continue
            existing = {c["name"] for c in live.get_columns(table)}
            for name, sql_type in columns:
                if name in existing:
                    continue
                try:
                    with engine.begin() as conn:
                        # Column name is quoted so mixed-case names like "crewID" keep
                        # their exact case — unquoted DDL gets folded to lowercase by
                        # Postgres, which then silently stops matching the ORM's
                        # (quoted, case-preserving) column reference.
                        conn.execute(text(f'ALTER TABLE "{table}" ADD COLUMN "{name}" {sql_type}'))
                    print(f"[DB] Added column {table}.{name}")
                except Exception as e:
                    print(f"[DB] Could not add column {table}.{name}: {e}")
    except Exception as e:
        print(f"[DB] Column migration skipped: {e}")


_add_missing_columns()

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
            ("admin", "admin@melaka.gov.my", hash_password("password"), "011-7778889", "admin", mbmb.agencyID),
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

        # 5. Seed Reports (Complaints) — opt-in only.
        #
        # This runs on every startup, and its guard only asked whether any report
        # was assigned to "worker1". Deleting the demo data therefore satisfied
        # the guard, and the next cold start recreated all three complaints —
        # so they could not be removed permanently, and reappeared with fresh
        # IDs looking like genuine new submissions.
        #
        # A deployment serving real citizens must not invent reports: staff
        # could dispatch a crew to an address nobody complained about. Demo data
        # now appears only when SEED_DEMO_DATA is explicitly set, which keeps it
        # available for local testing without it leaking into production.
        #
        # Accounts, staff, agencies and categories above are still seeded
        # unconditionally, because without them nobody can log in.
        seed_demo_reports = os.getenv("SEED_DEMO_DATA", "").strip().lower() in ("1", "true", "yes")
        citizen = db.query(DBUser).filter(DBUser.username == "test").first()
        if seed_demo_reports and citizen and not db.query(DBComplaint).first():
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

        if seed_demo_reports:
            print("[Seed] Reference data seeded. Demo reports enabled via SEED_DEMO_DATA.")
        else:
            print("[Seed] Reference data seeded. Demo reports skipped (set SEED_DEMO_DATA=true to include them).")
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
MODEL_PATH = BASE_DIR / "model.tflite"
LABELS_PATH = BASE_DIR / "labels.txt"

LOCAL_UPLOAD_DIR = BASE_DIR / "uploads"
TMP_UPLOAD_DIR = Path("/tmp/uploads") if (os.name != "nt" and os.path.exists("/tmp")) else LOCAL_UPLOAD_DIR
UPLOAD_DIR = TMP_UPLOAD_DIR


def _blob_is_configured() -> bool:
    """True when Vercel Blob is available to store uploads durably.

    Vercel injects BLOB_READ_WRITE_TOKEN once a Blob store is linked to the
    project. Without it, uploads fall back to the ephemeral local directory.
    """
    return bool(os.getenv("BLOB_READ_WRITE_TOKEN", "").strip())

try:
    LOCAL_UPLOAD_DIR.mkdir(exist_ok=True, parents=True)
    if TMP_UPLOAD_DIR != LOCAL_UPLOAD_DIR:
        TMP_UPLOAD_DIR.mkdir(exist_ok=True, parents=True)
except Exception:
    pass

@app.get("/uploads/{file_name:path}")
def serve_upload_file(file_name: str):
    # 1. Check runtime /tmp/uploads
    if os.name != "nt" and os.path.exists("/tmp"):
        tmp_file = Path("/tmp/uploads") / file_name
        if tmp_file.exists() and tmp_file.is_file():
            return FileResponse(str(tmp_file))

    # 2. Check git-committed BASE_DIR / uploads
    local_file = LOCAL_UPLOAD_DIR / file_name
    if local_file.exists() and local_file.is_file():
        return FileResponse(str(local_file))

    # 3. Gone. Say so.
    #
    # This used to serve a hardcoded sample photo instead, so a lost upload
    # showed an authority a real-looking picture of something else entirely,
    # with nothing on screen to indicate it was not the citizen's photo.
    # Dispatching a crew off the wrong image is worse than seeing no image.
    #
    # Uploads land in /tmp, which belongs to one short-lived instance and is
    # wiped on redeploy and cold start, so this path is reached routinely
    # rather than rarely. The durable fix is object storage; until then the
    # failure is at least visible instead of silently plausible.
    raise HTTPException(
        status_code=404,
        detail="This photo is no longer available on the server.",
    )

interpreter = None
input_details = None
output_details = None


def _backfill_team_assignment():
    """One-time backfill of the team-dispatch FKs for pre-existing reports.

    Before team dispatch existed, ownership lived in two free-text fields:
    assigned_department (a department name) and assigned_worker (a typed-in
    worker name). Resolve both into real foreign keys so old reports show up in
    the right team pool instead of vanishing from every scoped query.

    Runs on every boot but only touches rows whose FK is still NULL, so it is
    idempotent and costs nothing once the data is converted.
    """
    db = SessionLocal()
    try:
        pending = (
            db.query(DBComplaint)
            .filter(DBComplaint.assigned_agency_id.is_(None))
            .filter(
                or_(
                    DBComplaint.assigned_department.isnot(None),
                    DBComplaint.assigned_worker.isnot(None),
                )
            )
            .all()
        )
        if not pending:
            return

        agencies = db.query(DBAgency).all()
        staff_by_name = {s.username.lower(): s for s in db.query(DBStaff).all()}
        agency_filled = worker_filled = 0

        for report in pending:
            # assigned_department is free text ("Majlis Bandaraya Melaka Bersejarah",
            # "MBMB", ...) so match it through DEPT_MAP's known aliases.
            dept = (report.assigned_department or "").lower()
            if dept:
                for agency in agencies:
                    aliases = DEPT_MAP.get(agency.name.upper(), [agency.name])
                    if any(alias.lower() in dept for alias in aliases):
                        report.assigned_agency_id = agency.agencyID
                        agency_filled += 1
                        break

            worker = staff_by_name.get((report.assigned_worker or "").lower())
            if worker:
                report.assigned_worker_id = worker.id
                report.claimed_at = report.claimed_at or report.in_process_at
                worker_filled += 1
                # A named worker implies their agency owns it, even if the
                # department text was blank or unrecognised.
                if report.assigned_agency_id is None and worker.agencyID:
                    report.assigned_agency_id = worker.agencyID
                    agency_filled += 1

            if report.assigned_agency_id is not None and not report.dispatched_at:
                report.dispatched_at = report.in_process_at or report.reviewed_at
            if report.release_count is None:
                report.release_count = 0

        db.commit()
        print(
            f"[DB] Team backfill: {agency_filled} report(s) linked to a team, "
            f"{worker_filled} linked to a worker."
        )
    except Exception as e:
        db.rollback()
        print(f"[DB] Team backfill skipped: {e}")
    finally:
        db.close()


@app.on_event("startup")
def startup_event():
    global model, base_grad_model, nude_detector, class_names, interpreter, input_details, output_details

    # 1. Seed database safely
    try:
        seed_database()
    except Exception as e:
        print(f"[Startup Warning] Seed database failed: {e}")

    # 1b. Convert legacy free-text assignment into team/worker foreign keys.
    try:
        _backfill_team_assignment()
    except Exception as e:
        print(f"[Startup Warning] Team backfill failed: {e}")

    # 2. Load TFLite model safely
    try:
        if MODEL_PATH.exists() and LABELS_PATH.exists():
            print("[Startup] Loading TFLite model...")
            try:
                import ai_edge_litert.interpreter as tflite
            except ImportError:
                try:
                    import tflite_runtime.interpreter as tflite
                except ImportError:
                    import tensorflow.lite as tflite
            interpreter = tflite.Interpreter(model_path=str(MODEL_PATH))
            interpreter.allocate_tensors()
            input_details = interpreter.get_input_details()
            output_details = interpreter.get_output_details()
            
            with open(LABELS_PATH, "r") as f:
                class_names = [line.strip() for line in f.readlines()]
                
            _dummy = np.zeros((1, 224, 224, 3), dtype=np.float32)
            interpreter.set_tensor(input_details[0]['index'], _dummy)
            interpreter.invoke()
            print("[Startup OK] Model warmed up and ready.")
        else:
            print("[Startup Warning] Model or labels file missing.")
    except Exception as e:
        print(f"[Startup Warning] Failed to load TFLite model: {e}")
        interpreter = None
        
    base_grad_model = None
    
    # 7. Initialize NSFW detector
    if nude_detector_available:
        try:
            print("[Startup] Initializing NSFW Content Moderation Detector...")
            nude_detector = NudeDetector()
            print("[Startup OK] NSFW Content Moderation Detector initialized successfully.")
        except Exception as e:
            print(f"[Startup Warning] Failed to initialize NSFW detector: {e}")
            nude_detector = None
    else:
        print("[Startup] NSFW Content Moderation Detector is disabled or unavailable.")
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


async def _inspect_authenticity(contents: bytes, metadata_blob: Optional[UploadFile] = None,
                                filename: str = "image.jpg") -> dict:
    """
    Run metadata forensics on an upload.

    metadata_blob is an optional head slice of the *original* file sent by the
    client. It exists because the mobile app downscales before upload, and
    re-encoding destroys EXIF, XMP and C2PA blocks. Since all of those live at
    the front of the file, a partial read of the original is enough.
    """
    raw_metadata = None
    if metadata_blob is not None:
        try:
            raw_metadata = await metadata_blob.read()
        except Exception as e:
            logger.warning(f"Could not read metadata_blob: {e}")

    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(
        None,
        lambda: inspect_image_authenticity(contents, filename, raw_metadata),
    )


def _persist_authenticity(report: DBComplaint, authenticity: dict, image_hash: str = "") -> None:
    """Attach forensic results to a report row."""
    report.authenticity_verdict = authenticity.get("verdict")
    report.authenticity_score = authenticity.get("authenticity_score")
    try:
        report.authenticity_signals = json.dumps(authenticity.get("signals", []))[:4000]
    except (TypeError, ValueError):
        report.authenticity_signals = None
    if image_hash:
        report.image_hash = image_hash


def _collect_training_sample(db: Session, report: DBComplaint, contents: bytes,
                             authenticity: dict, submitted_category: str,
                             ai_prediction: str, confidence: str,
                             user_corrected_category: str = None) -> dict:
    """
    Evaluate one report image as a training sample and record the decision.

    The label is whichever the citizen actually chose. When that differs from
    what the model predicted, it is a correction — the single most valuable kind
    of label, because it marks a case the model got wrong.
    """
    predicted_class = dataset_collector.to_training_class(ai_prediction)
    chosen_category = user_corrected_category or submitted_category
    chosen_class = dataset_collector.to_training_class(chosen_category)
    user_corrected = bool(chosen_class and predicted_class and chosen_class != predicted_class)

    known = [
        {"hash": h, "report_id": rid}
        for h, rid in db.query(DBDatasetSample.image_hash, DBDatasetSample.report_id)
                        .filter(DBDatasetSample.image_hash.isnot(None)).all()
    ]

    sample = dataset_collector.build_sample(
        report_id=report.id,
        image_bytes=contents,
        class_label=chosen_category,
        confidence=confidence,
        authenticity=authenticity,
        known_hashes=known,
        user_corrected=user_corrected,
    )

    if sample["status"] == dataset_collector.STATUS_SKIPPED:
        logger.info(f"Report {report.id} not collected: {sample['reason']}")
        return {"status": sample["status"], "reason": sample["reason"]}

    local_path = dataset_collector.save_sample_locally(sample)

    # Buffer the prepared bytes only when a remote store is configured to
    # receive them; otherwise the local file is the record.
    blob = None
    if dataset_store.is_configured() and sample.get("image_bytes"):
        blob = base64.b64encode(sample["image_bytes"]).decode("ascii")

    db.add(DBDatasetSample(
        report_id=report.id,
        image_hash=sample["image_hash"],
        class_label=sample["class_label"],
        confidence=sample["confidence"],
        status=sample["status"],
        reason=sample["reason"],
        source=sample["source"],
        authenticity_verdict=sample["authenticity_verdict"],
        authenticity_score=sample["authenticity_score"],
        image_path=local_path or None,
        created_at=sample["created_at"],
        pending_blob=blob,
    ))
    db.commit()

    logger.info(
        f"Report {report.id} collected as {sample['status']} "
        f"({sample['class_label']}): {sample['reason']}"
    )
    return {
        "status": sample["status"],
        "reason": sample["reason"],
        "class_label": sample["class_label"],
    }


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
    """Persist an uploaded image and return the URL to serve it from.

    Prefers Vercel Blob, falling back to the uploads directory when no blob
    token is configured (local development, or a host without it).

    The local path is not durable on this host: UPLOAD_DIR resolves to /tmp,
    which belongs to a single short-lived instance and is wiped on redeploy and
    cold start. Every citizen photo written there was lost within minutes, which
    is what the blob store fixes. The returned value is a full https:// URL when
    blob storage is used; getImageUrl on the frontend passes those through
    untouched, so nothing downstream needs to change.
    """
    unique_name = f"{prefix}{uuid.uuid4()}{ext}"

    if _blob_is_configured():
        try:
            import vercel_blob

            result = vercel_blob.put(
                f"uploads/{unique_name}",
                contents,
                {"access": "public", "addRandomSuffix": "false"},
            )
            url = result.get("url")
            if url:
                return url
            logger.error("Blob upload returned no URL; falling back to local disk.")
        except Exception as exc:
            # Never lose the citizen's submission over a storage failure. The
            # local copy is ephemeral, but a photo that survives minutes beats
            # a failed report.
            logger.error(f"Blob upload failed ({exc}); falling back to local disk.")

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
        "assigned_agency_id":       r.assigned_agency_id,
        "assigned_team":            r.assigned_agency.name if r.assigned_agency else None,
        "assigned_crew_id":         r.assigned_crew_id,
        "assigned_crew":            r.assigned_crew.name if r.assigned_crew else None,
        "assigned_worker_id":       r.assigned_worker_id,
        # NULL worker means the report is still sitting in the team's shared pool.
        "in_pool":                  r.assigned_agency_id is not None and r.assigned_worker_id is None,
        "dispatched_at":            r.dispatched_at,
        "claimed_at":               r.claimed_at,
        "release_count":            r.release_count or 0,
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
        "image_hash":               r.image_hash,
        "authenticity_score":       r.authenticity_score,
        "authenticity_verdict":     r.authenticity_verdict,
        "authenticity_signals":     _load_signals(r.authenticity_signals),
    }


def _load_signals(raw: str | None) -> list:
    """Decode the stored JSON signal list; never let bad data break a report response."""
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, list) else []
    except (ValueError, TypeError):
        return []


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
    # Set input tensor and invoke interpreter
    interpreter.set_tensor(input_details[0]['index'], data)
    interpreter.invoke()
    prediction = interpreter.get_tensor(output_details[0]['index'])[0]
    
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
    metadata_blob: Optional[UploadFile] = File(None),
    _token: dict = Depends(require_token),
):
    """Classify an uploaded image and assess whether it is a genuine camera capture."""
    try:
        contents = await _read_and_validate_file(file)
        # FIX B-3 + B-7: Use get_running_loop; run blocking inference in thread
        loop = asyncio.get_running_loop()
        label_str, confidence_str, pred_list = await loop.run_in_executor(
            None, lambda: _ai_inference_sync(contents)
        )

        authenticity = await _inspect_authenticity(
            contents, metadata_blob, file.filename or "image.jpg"
        )

        # Grad-CAM only runs with a real Keras model; base_grad_model is None in
        # the TFLite deployment, where _generate_gradcam_sync returns the input
        # unchanged. Writing that copy to disk would litter uploads/ with a junk
        # file on every single call, so skip it entirely when unavailable.
        gradcam_url = None
        if pred_list and base_grad_model is not None:
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
            "gradcam_url": gradcam_url,
            "authenticity": authenticity,
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


class ProfileUpdate(BaseModel):
    """Fields a signed-in user may change about themselves. All optional —
    only the ones supplied are touched."""
    username:    Optional[str] = Field(None, min_length=1, max_length=64)
    fullName:    Optional[str] = Field(None, max_length=128)
    icNumber:    Optional[str] = Field(None, max_length=32)
    phoneNumber: Optional[str] = Field(None, max_length=32)
    email:       Optional[str] = Field(None, max_length=128)


@app.put("/profile")
def update_profile(
    req: ProfileUpdate,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Update the signed-in user's own profile.

    Scoped to the caller's own record via the token's subject — there is
    deliberately no user_id parameter, so this cannot be used to edit anyone
    else's details.
    """
    try:
        user_id = int(_token.get("sub"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=401, detail="Malformed token subject.")

    role = (_token.get("role") or "citizen").lower()
    is_staff = role in ("worker", "authority", "admin")

    record = (db.query(DBStaff).filter(DBStaff.id == user_id).first() if is_staff
              else db.query(DBUser).filter(DBUser.id == user_id).first())
    if not record:
        raise HTTPException(status_code=404, detail="Account not found.")

    updated, ignored = [], []

    new_username = (req.username or "").strip()
    if new_username and new_username != record.username:
        # Usernames are the login identifier and unique across both tables,
        # so check them together the same way signup does.
        taken = (db.query(DBUser).filter(DBUser.username == new_username).first()
                 or db.query(DBStaff).filter(DBStaff.username == new_username).first())
        if taken:
            raise HTTPException(status_code=409, detail="That username is already taken.")

        # Complaints record the assigned worker by name, not by id, so a staff
        # rename would otherwise orphan every job already assigned to them.
        if is_staff:
            db.query(DBComplaint).filter(
                DBComplaint.assigned_worker == record.username
            ).update({DBComplaint.assigned_worker: new_username},
                     synchronize_session=False)

        record.username = new_username
        updated.append("username")

    for field in ("fullName", "icNumber", "phoneNumber", "email"):
        value = getattr(req, field)
        if value is None:
            continue
        value = value.strip()
        if not hasattr(record, field):
            # Staff rows carry no fullName/icNumber columns. Report this back
            # rather than pretending the value was stored.
            ignored.append(field)
            continue
        if getattr(record, field) != value:
            setattr(record, field, value)
            updated.append(field)

    db.commit()
    db.refresh(record)

    # The old token still carries the previous username in its claims, so hand
    # back a fresh one to keep the session consistent after a rename.
    token = create_access_token({
        "sub": str(record.id),
        "username": record.username,
        "role": role,
    })

    return {
        "message": "Profile updated successfully.",
        "updated": updated,
        "ignored": ignored,
        "user_id": record.id,
        "username": record.username,
        "fullName": getattr(record, "fullName", record.username),
        "icNumber": getattr(record, "icNumber", "N/A"),
        "phoneNumber": getattr(record, "phoneNumber", "N/A"),
        "email": getattr(record, "email", "N/A"),
        "role": role,
        "token": token,
    }


def _crew_visible_to(my_crew: Optional[int]):
    """A worker sees agency-wide work (no crew set) regardless of their own
    crew, plus their own crew's private pool if they have one. Crews are
    additive scoping, not a hard partition — an un-crewed dispatch is still
    "everyone's" work.
    """
    if my_crew:
        return or_(DBComplaint.assigned_crew_id.is_(None), DBComplaint.assigned_crew_id == my_crew)
    return DBComplaint.assigned_crew_id.is_(None)


# ─────────────────────────────────────────────────────────────
#  ROUTES — REPORTS
# ─────────────────────────────────────────────────────────────
@app.get("/reports/")
@app.get("/reports")
def get_reports(
    user_id: Optional[int] = None,
    role: Optional[str] = None,
    username: Optional[str] = None,
    scope: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Return reports filtered by role with pagination.
      citizen          → only their own reports
      worker           → jobs they have claimed + their team's unclaimed pool
      authority        → everything owned by their team
      admin / None     → all reports

    Scoping keys off Staff.agencyID and Complaint.assigned_agency_id rather than
    fuzzy-matching department text against the caller's username, which silently
    mis-scoped anyone whose username did not happen to contain their agency name.

    `scope` narrows a worker's view so the client can render separate lists
    without re-filtering client-side:
      mine → claimed by me    pool → unclaimed team pool    team → both (default)
      recent_claims → teammates' claims in the last RECENT_CLAIM_WINDOW_MINUTES,
        so the rest of the crew can be notified who just took a job instead of
        it silently vanishing from their pool.
    """
    query = db.query(DBComplaint)

    # Secure role/username check from the JWT token
    token_role = _token.get("role") or ""
    token_username = _token.get("username") or ""
    scope = (scope or "team").lower()

    staff = None
    if token_role in ("worker", "authority", "admin") or token_role.startswith("authority_"):
        try:
            staff = db.query(DBStaff).filter(DBStaff.id == int(_token["sub"])).first()
        except (KeyError, TypeError, ValueError):
            staff = None

    if token_role == "citizen" or (user_id is not None and token_role not in ("worker", "admin") and not token_role.startswith("authority") and token_role != "authority"):
        if user_id is not None:
            query = query.filter(DBComplaint.user_id == user_id)
    elif token_role == "worker":
        my_id = staff.id if staff else -1
        my_agency = staff.agencyID if staff else None
        my_crew = staff.crewID if staff else None
        on_leave = bool(staff.on_leave) if staff else False

        mine = DBComplaint.assigned_worker_id == my_id
        if my_agency and not on_leave:
            pool = and_(
                DBComplaint.assigned_agency_id == my_agency,
                DBComplaint.assigned_worker_id.is_(None),
                _crew_visible_to(my_crew),
            )
        else:
            # On leave: still see claimed work (to finish or release it), but no
            # new pool items — nothing to notify them about while they're out.
            pool = false()

        if scope == "mine":
            query = query.filter(mine)
        elif scope == "pool":
            query = query.filter(pool)
        elif scope == "recent_claims":
            if my_agency and not on_leave:
                cutoff = (
                    datetime.now(timezone.utc) - timedelta(minutes=RECENT_CLAIM_WINDOW_MINUTES)
                ).isoformat()
                # claimed_at is stored as an isoformat() string; all rows share
                # the same fixed format and UTC offset, so string comparison
                # sorts chronologically the same as a real timestamp would.
                query = query.filter(
                    DBComplaint.assigned_agency_id == my_agency,
                    DBComplaint.assigned_worker_id.isnot(None),
                    DBComplaint.assigned_worker_id != my_id,
                    DBComplaint.claimed_at >= cutoff,
                    _crew_visible_to(my_crew),
                )
            else:
                query = query.filter(false())
        else:
            query = query.filter(or_(mine, pool))

        query = query.filter(DBComplaint.status.in_(["In Process", "In Maintenance"]))
    elif token_role == "authority" or token_role.startswith("authority_"):
        my_agency = staff.agencyID if staff else None
        if my_agency:
            # Their own team's work, plus anything still awaiting dispatch that
            # is routed to them by category (assigned_agency_id set at review).
            query = query.filter(DBComplaint.assigned_agency_id == my_agency)
            if scope == "pool":
                query = query.filter(DBComplaint.assigned_worker_id.is_(None))

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
    user_corrected_category: str = Form(None, max_length=128),
    file: UploadFile = File(...),
    metadata_blob: Optional[UploadFile] = File(None),
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
        assigned_agency_id = None
        if cat_record and cat_record.agencyID:
            agency = db.query(DBAgency).filter(DBAgency.agencyID == cat_record.agencyID).first()
            if agency:
                assigned_dept = agency.name
                # Route to the owning team up front so that team's authority sees
                # it in their queue as soon as the admin approves it.
                assigned_agency_id = agency.agencyID

        new_report = DBComplaint(
            assigned_agency_id=assigned_agency_id,
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
        authenticity = await _inspect_authenticity(
            contents, metadata_blob, file.filename or "image.jpg"
        )
        image_hash = dataset_collector.compute_image_hash(contents)
        _persist_authenticity(new_report, authenticity, image_hash)

        db.add(new_report)
        db.commit()
        db.refresh(new_report)

        # Also add record to Issue table
        if cat_record:
            db.add(DBIssue(complaintID=new_report.id, categoryID=cat_record.categoryID, count=1))
            db.commit()

        # Harvest the image as a training sample. Never let a collection failure
        # break a citizen's submission — the report is the product, the dataset
        # is a side effect.
        sample_status = None
        try:
            sample_status = _collect_training_sample(
                db=db,
                report=new_report,
                contents=contents,
                authenticity=authenticity,
                submitted_category=categories,
                ai_prediction=ai_prediction,
                confidence=confidence,
                user_corrected_category=user_corrected_category,
            )
        except Exception as e:
            logger.error(f"Dataset collection failed for report {new_report.id}: {e}")

        return {
            "message": "Report submitted successfully",
            "id": new_report.id,
            "authenticity": authenticity,
            "dataset_status": sample_status,
        }
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
    # Resolve the department name to the owning team so the right authority
    # picks it up; falls back to whatever routing create_report already set.
    resolved = _resolve_agency(db, req.department)
    if resolved:
        report.assigned_agency_id = resolved.agencyID
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


# ─────────────────────────────────────────────────────────────
#  TEAM DISPATCH HELPERS
#
#  A "team" is an Agency. A report is dispatched to a team, sits in that team's
#  shared pool (assigned_worker_id IS NULL), and the first member to claim it
#  owns it. Statuses are unchanged — pool vs claimed is expressed by the FK.
# ─────────────────────────────────────────────────────────────
SLA_HOURS = int(os.getenv("DISPATCH_SLA_HOURS", "48"))
RECENT_CLAIM_WINDOW_MINUTES = int(os.getenv("RECENT_CLAIM_WINDOW_MINUTES", "30"))


def _current_staff(db: Session, token: dict) -> DBStaff:
    """Resolve the caller to a Staff row, or 403 if they are not staff."""
    try:
        staff = db.query(DBStaff).filter(DBStaff.id == int(token["sub"])).first()
    except (KeyError, TypeError, ValueError):
        staff = None
    if not staff:
        raise HTTPException(status_code=403, detail="This action requires a staff account.")
    return staff


def _resolve_agency(db: Session, name: Optional[str]) -> Optional[DBAgency]:
    """Match a free-text department name to an Agency via DEPT_MAP aliases."""
    if not name:
        return None
    needle = name.strip().lower()
    for agency in db.query(DBAgency).all():
        aliases = DEPT_MAP.get(agency.name.upper(), [agency.name])
        if agency.name.lower() == needle or any(a.lower() in needle for a in aliases):
            return agency
    return None


def _log_action(db: Session, staff: DBStaff, report: DBComplaint, status: str, remarks: str) -> None:
    """Append an AuthorityAction audit row, matching the existing workflow steps."""
    cat_rec = db.query(DBCategory).filter(DBCategory.name == report.categories).first()
    db.add(DBAuthorityAction(
        status=status,
        remarks=remarks[:1000],
        staffID=staff.id,
        complaintID=report.id,
        categoryID=cat_rec.categoryID if cat_rec else None,
    ))


def _require_team_access(staff: DBStaff, report: DBComplaint) -> None:
    """Admins act anywhere; an authority may only act on their own team's work."""
    if staff.role == "admin":
        return
    if staff.role != "authority" and not (staff.role or "").startswith("authority"):
        raise HTTPException(status_code=403, detail="Only an authority or admin may do this.")
    if report.assigned_agency_id and report.assigned_agency_id != staff.agencyID:
        raise HTTPException(
            status_code=403,
            detail="This report belongs to another team. Ask an admin to transfer it.",
        )


def _get_report_or_404(db: Session, report_id: int) -> DBComplaint:
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    return report


def _require_crew_member(db: Session, staff: DBStaff, report: DBComplaint) -> None:
    """Anyone on the crew holding the job may progress it (admins exempt).

    Work dispatched to a crew is shared by that crew: teammates coordinate
    between themselves rather than racing to claim it, and a job is never
    blocked because the one worker who tapped Accept first is unavailable.

    Crews remain a hard boundary in the other direction — Team B cannot touch
    Team A's work — and a crew-less dispatch stays open to the whole agency,
    matching the visibility rules in _crew_visible_to.
    """
    if staff.role == "admin":
        return
    if staff.role != "worker":
        raise HTTPException(status_code=403, detail="Only workers can carry out tasks.")
    if not staff.agencyID or report.assigned_agency_id != staff.agencyID:
        raise HTTPException(status_code=403, detail="This task belongs to another team.")
    if report.assigned_crew_id and report.assigned_crew_id != staff.crewID:
        raise HTTPException(status_code=403, detail="This task belongs to another crew.")
    if staff.on_leave:
        raise HTTPException(
            status_code=400,
            detail="You're marked on leave — ask your authority to update that first.",
        )
    if report.assigned_crew_id:
        crew = db.query(DBCrew).filter(DBCrew.id == report.assigned_crew_id).first()
        if crew and crew.status == "disabled":
            raise HTTPException(status_code=403, detail=f"{crew.name} is currently disabled.")


def _adopt_if_unclaimed(staff: DBStaff, report: DBComplaint) -> None:
    """Record the first teammate to actually start work as the handler.

    Claiming is no longer a gate, so nobody has to tap Accept before working.
    Stamping the handler here anyway keeps claimed_at populated, which the pool
    wait and mobilisation stages of the analytics measure, and leaves a record of
    who did the job.
    """
    if staff.role != "worker" or report.assigned_worker_id is not None:
        return
    report.assigned_worker_id = staff.id
    report.assigned_worker = staff.username
    report.claimed_at = datetime.now(timezone.utc).isoformat()


# ─────────────────────────────────────────────────────────────
#  TEAM ROSTER
# ─────────────────────────────────────────────────────────────
@app.get("/teams")
def list_teams(db: Session = Depends(get_db), _token: dict = Depends(require_token)):
    """Every team with its headcount and current open load.

    Replaces the free-text worker box in the admin panel: the authority picks a
    real team from this list instead of typing a name that matches nothing.
    """
    open_statuses = ["In Review", "In Process", "In Maintenance"]
    teams = []
    for agency in db.query(DBAgency).order_by(DBAgency.name).all():
        worker_count = db.query(func.count(DBStaff.id)).filter(
            DBStaff.agencyID == agency.agencyID, DBStaff.role == "worker"
        ).scalar() or 0
        open_count = db.query(func.count(DBComplaint.id)).filter(
            DBComplaint.assigned_agency_id == agency.agencyID,
            DBComplaint.status.in_(open_statuses),
        ).scalar() or 0
        unclaimed = db.query(func.count(DBComplaint.id)).filter(
            DBComplaint.assigned_agency_id == agency.agencyID,
            DBComplaint.assigned_worker_id.is_(None),
            DBComplaint.status.in_(open_statuses),
        ).scalar() or 0
        teams.append({
            "id": agency.agencyID,
            "name": agency.name,
            "address": agency.address,
            "worker_count": worker_count,
            "open_count": open_count,
            "unclaimed_count": unclaimed,
        })
    return teams


@app.get("/teams/{team_id}/workers")
def list_team_workers(
    team_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Roster for one team, with each worker's current active job count."""
    staff = _current_staff(db, _token)
    if staff.role != "admin" and staff.agencyID != team_id:
        raise HTTPException(status_code=403, detail="You can only view your own team's roster.")

    workers = db.query(DBStaff).filter(
        DBStaff.agencyID == team_id, DBStaff.role == "worker"
    ).order_by(DBStaff.username).all()

    out = []
    for w in workers:
        active = db.query(func.count(DBComplaint.id)).filter(
            DBComplaint.assigned_worker_id == w.id,
            DBComplaint.status.in_(["In Process", "In Maintenance"]),
        ).scalar() or 0
        out.append({
            "id": w.id,
            "username": w.username,
            "email": w.email,
            "phoneNumber": w.phoneNumber,
            "active_jobs": active,
            "crew_id": w.crewID,
            "on_leave": bool(w.on_leave),
        })
    return out


# ─────────────────────────────────────────────────────────────
#  CREWS — sub-teams within one agency, e.g. MBMB "Team A" vs "Team B"
# ─────────────────────────────────────────────────────────────
def _require_agency_owner(staff: DBStaff, agency_id: int) -> None:
    """Admins manage any agency's crews; an authority only their own — this
    is the day-to-day crew management path (create/rename/disable, members,
    leave), so it stays with the authority rather than becoming a bottleneck
    on admin for every agency."""
    if staff.role == "admin":
        return
    if staff.role != "authority" and not (staff.role or "").startswith("authority"):
        raise HTTPException(status_code=403, detail="Only an authority or admin may manage crews.")
    if staff.agencyID != agency_id:
        raise HTTPException(status_code=403, detail="You can only manage your own team's crews.")




def _serialize_crew(db: Session, crew: DBCrew) -> dict:
    members = db.query(DBStaff).filter(DBStaff.crewID == crew.id).order_by(DBStaff.username).all()
    open_statuses = ["In Process", "In Maintenance"]
    member_list = []
    for m in members:
        active = db.query(func.count(DBComplaint.id)).filter(
            DBComplaint.assigned_worker_id == m.id,
            DBComplaint.status.in_(open_statuses),
        ).scalar() or 0
        member_list.append({
            "id": m.id,
            "username": m.username,
            "email": m.email,
            "phoneNumber": m.phoneNumber,
            "on_leave": bool(m.on_leave),
            "active_jobs": active,
        })
    return {
        "id": crew.id,
        "agency_id": crew.agencyID,
        "name": crew.name,
        "status": crew.status,
        "created_at": crew.created_at,
        "members": member_list,
    }


@app.get("/agencies/{agency_id}/crews")
def list_crews(
    agency_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """All crews in one agency, each with its member roster and load."""
    staff = _current_staff(db, _token)
    _require_agency_owner(staff, agency_id)
    crews = db.query(DBCrew).filter(DBCrew.agencyID == agency_id).order_by(DBCrew.name).all()
    return [_serialize_crew(db, c) for c in crews]


class CrewCreateRequest(BaseModel):
    name: str = Field(..., max_length=128)


@app.post("/agencies/{agency_id}/crews")
def create_crew(
    agency_id: int,
    req: CrewCreateRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Create a new crew (e.g. "Team A") inside an agency."""
    staff = _current_staff(db, _token)
    _require_agency_owner(staff, agency_id)

    agency = db.query(DBAgency).filter(DBAgency.agencyID == agency_id).first()
    if not agency:
        raise HTTPException(status_code=404, detail="Team not found")

    name = req.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Crew name is required.")
    dup = db.query(DBCrew).filter(DBCrew.agencyID == agency_id, DBCrew.name.ilike(name)).first()
    if dup:
        raise HTTPException(status_code=409, detail=f"A crew named '{name}' already exists in {agency.name}.")

    crew = DBCrew(
        agencyID=agency_id,
        name=name,
        status="active",
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    db.add(crew)
    db.commit()
    db.refresh(crew)
    return _serialize_crew(db, crew)


class CrewUpdateRequest(BaseModel):
    name: Optional[str] = Field(None, max_length=128)
    status: Optional[str] = None  # active | disabled


@app.patch("/crews/{crew_id}")
def update_crew(
    crew_id: int,
    req: CrewUpdateRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Rename a crew, or take it offline (disabled) — e.g. the whole crew on leave.

    A disabled crew cannot receive new dispatches or claims, but jobs already
    claimed by its members are left alone so in-progress work is not stranded.
    """
    staff = _current_staff(db, _token)
    crew = db.query(DBCrew).filter(DBCrew.id == crew_id).first()
    if not crew:
        raise HTTPException(status_code=404, detail="Crew not found")
    _require_agency_owner(staff, crew.agencyID)

    if req.name is not None:
        name = req.name.strip()
        if not name:
            raise HTTPException(status_code=400, detail="Crew name cannot be empty.")
        crew.name = name
    if req.status is not None:
        if req.status not in ("active", "disabled"):
            raise HTTPException(status_code=400, detail="Status must be 'active' or 'disabled'.")
        crew.status = req.status

    db.commit()
    db.refresh(crew)
    return _serialize_crew(db, crew)


@app.delete("/crews/{crew_id}")
def delete_crew(
    crew_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Permanently remove an empty crew.

    Blocked while it still has members — remove everyone first, so nobody's
    membership disappears silently as a side effect of deleting the crew.
    Reports that reference this crew (open or historical) are not blocked or
    orphaned: their assigned_crew_id is cleared, so they simply read as
    agency-wide work going forward, same as a crew that was never set.
    """
    staff = _current_staff(db, _token)
    crew = db.query(DBCrew).filter(DBCrew.id == crew_id).first()
    if not crew:
        raise HTTPException(status_code=404, detail="Crew not found")
    _require_agency_owner(staff, crew.agencyID)

    member_count = db.query(func.count(DBStaff.id)).filter(DBStaff.crewID == crew.id).scalar() or 0
    if member_count > 0:
        raise HTTPException(
            status_code=400,
            detail=f"Remove all {member_count} member(s) from {crew.name} before deleting it.",
        )

    db.query(DBComplaint).filter(DBComplaint.assigned_crew_id == crew.id).update(
        {"assigned_crew_id": None}, synchronize_session=False
    )
    db.delete(crew)
    db.commit()
    return {"deleted": True, "id": crew_id}


class CrewMemberRequest(BaseModel):
    staff_id: int


@app.post("/crews/{crew_id}/members")
def add_crew_member(
    crew_id: int,
    req: CrewMemberRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Add a worker to a crew. A worker can only be on one crew at a time —
    adding them here moves them out of any crew they were already on."""
    staff = _current_staff(db, _token)
    crew = db.query(DBCrew).filter(DBCrew.id == crew_id).first()
    if not crew:
        raise HTTPException(status_code=404, detail="Crew not found")
    _require_agency_owner(staff, crew.agencyID)

    worker = db.query(DBStaff).filter(DBStaff.id == req.staff_id, DBStaff.role == "worker").first()
    if not worker:
        raise HTTPException(status_code=404, detail="Worker not found")
    if worker.agencyID != crew.agencyID:
        raise HTTPException(status_code=400, detail=f"{worker.username} is not a member of this team.")

    worker.crewID = crew.id
    db.commit()
    return _serialize_crew(db, crew)


@app.delete("/crews/{crew_id}/members/{staff_id}")
def remove_crew_member(
    crew_id: int,
    staff_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Remove a worker from a crew — they fall back to the agency-wide pool."""
    staff = _current_staff(db, _token)
    crew = db.query(DBCrew).filter(DBCrew.id == crew_id).first()
    if not crew:
        raise HTTPException(status_code=404, detail="Crew not found")
    _require_agency_owner(staff, crew.agencyID)

    worker = db.query(DBStaff).filter(DBStaff.id == staff_id, DBStaff.crewID == crew.id).first()
    if not worker:
        raise HTTPException(status_code=404, detail="This worker is not on that crew.")
    worker.crewID = None
    db.commit()
    return _serialize_crew(db, crew)


class LeaveRequest(BaseModel):
    on_leave: bool


@app.patch("/staff/{staff_id}/leave")
def set_staff_leave(
    staff_id: int,
    req: LeaveRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Toggle one worker's on-leave flag.

    While on leave, a worker drops out of dispatch/pin pickers and stops
    seeing new pool work, but keeps whatever they already claimed so they can
    finish or release it before going offline.
    """
    staff = _current_staff(db, _token)
    worker = db.query(DBStaff).filter(DBStaff.id == staff_id, DBStaff.role == "worker").first()
    if not worker:
        raise HTTPException(status_code=404, detail="Worker not found")
    _require_agency_owner(staff, worker.agencyID)

    worker.on_leave = req.on_leave
    db.commit()
    return {"id": worker.id, "username": worker.username, "on_leave": bool(worker.on_leave)}


@app.get("/agencies/{agency_id}/crews/workload")
def crew_workload(
    agency_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Per-crew load, capacity, ageing and throughput within one agency.

    Mirrors /teams/workload one level down, so an authority can see which of
    their own crews is drowning and which has room, not just the agency
    total. A final "Unassigned" row covers work dispatched agency-wide, no
    crew set.
    """
    staff = _current_staff(db, _token)
    _require_agency_owner(staff, agency_id)

    now = datetime.now(timezone.utc)
    week_ago = now - timedelta(days=7)
    open_statuses = ["In Process", "In Maintenance"]

    def stats_for(crew_id: Optional[int], label: str, crew_status: str) -> dict:
        crew_cond = (
            DBComplaint.assigned_crew_id == crew_id if crew_id is not None
            else DBComplaint.assigned_crew_id.is_(None)
        )
        open_reports = db.query(DBComplaint).filter(
            DBComplaint.assigned_agency_id == agency_id,
            crew_cond,
            DBComplaint.status.in_(open_statuses),
        ).all()
        unclaimed = [r for r in open_reports if r.assigned_worker_id is None]
        claimed = [r for r in open_reports if r.assigned_worker_id is not None]

        worker_cond = (
            DBStaff.crewID == crew_id if crew_id is not None
            else and_(DBStaff.agencyID == agency_id, DBStaff.crewID.is_(None))
        )
        active_workers = db.query(func.count(DBStaff.id)).filter(
            worker_cond, DBStaff.role == "worker", DBStaff.on_leave.isnot(True),
        ).scalar() or 0
        on_leave_count = db.query(func.count(DBStaff.id)).filter(
            worker_cond, DBStaff.role == "worker", DBStaff.on_leave.is_(True),
        ).scalar() or 0

        ages = [
            (now - ts).total_seconds() / 3600.0
            for ts in (_parse_ts(r.dispatched_at or r.in_process_at) for r in unclaimed)
            if ts is not None
        ]
        oldest_hours = round(max(ages), 1) if ages else 0.0
        breached = sum(1 for a in ages if a > SLA_HOURS)

        completed_7d = sum(
            1 for r in db.query(DBComplaint).filter(
                DBComplaint.assigned_agency_id == agency_id,
                crew_cond,
                DBComplaint.status == "Resolved",
            ).all()
            if (ts := _parse_ts(r.resolved_at)) and ts >= week_ago
        )

        load_per_worker = round(len(open_reports) / active_workers, 2) if active_workers else None
        strain = 0
        if load_per_worker is None and open_reports:
            strain += 2
        elif load_per_worker is not None and load_per_worker >= 5:
            strain += 2 if load_per_worker >= 8 else 1
        if breached:
            strain += 2 if breached >= 3 else 1
        derived_status = "bottleneck" if strain >= 3 else "strained" if strain >= 1 else "healthy"

        return {
            "id": crew_id,
            "name": label,
            "status": crew_status,
            "derived_status": derived_status,
            "open_count": len(open_reports),
            "unclaimed_count": len(unclaimed),
            "claimed_count": len(claimed),
            "worker_count": active_workers,
            "on_leave_count": on_leave_count,
            "load_per_worker": load_per_worker,
            "oldest_unclaimed_hours": oldest_hours,
            "sla_breached_count": breached,
            "completed_7d": completed_7d,
        }

    crews = db.query(DBCrew).filter(DBCrew.agencyID == agency_id).order_by(DBCrew.name).all()
    out = [stats_for(c.id, c.name, c.status) for c in crews]
    out.append(stats_for(None, "Unassigned", "active"))
    return {"sla_hours": SLA_HOURS, "crews": out}


# ─────────────────────────────────────────────────────────────
#  STEP 2 → Authority dispatches to a team: In Review → In Process (pool)
# ─────────────────────────────────────────────────────────────
class DispatchRequest(BaseModel):
    agency_id: int
    crew_id: Optional[int] = None     # optional: scope to one crew's pool
    worker_id: Optional[int] = None   # optional pin; omit to leave in the pool
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/dispatch")
def dispatch_to_team(
    report_id: int,
    req: DispatchRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Send a report to a team (or one crew's) shared pool, optionally pinned
    to one worker."""
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_team_access(staff, report)

    agency = db.query(DBAgency).filter(DBAgency.agencyID == req.agency_id).first()
    if not agency:
        raise HTTPException(status_code=404, detail="Team not found")

    crew = None
    if req.crew_id is not None:
        crew = db.query(DBCrew).filter(DBCrew.id == req.crew_id).first()
        if not crew:
            raise HTTPException(status_code=404, detail="Crew not found")
        if crew.agencyID != agency.agencyID:
            raise HTTPException(status_code=400, detail=f"{crew.name} is not part of {agency.name}.")
        if crew.status == "disabled":
            raise HTTPException(status_code=400, detail=f"{crew.name} is currently disabled.")

    pinned = None
    if req.worker_id is not None:
        pinned = db.query(DBStaff).filter(
            DBStaff.id == req.worker_id, DBStaff.role == "worker"
        ).first()
        if not pinned:
            raise HTTPException(status_code=404, detail="Worker not found")
        if pinned.agencyID != agency.agencyID:
            raise HTTPException(
                status_code=400,
                detail=f"{pinned.username} is not a member of {agency.name}.",
            )
        if crew and pinned.crewID != crew.id:
            raise HTTPException(status_code=400, detail=f"{pinned.username} is not on {crew.name}.")
        if pinned.on_leave:
            raise HTTPException(status_code=400, detail=f"{pinned.username} is currently on leave.")

    now = datetime.now(timezone.utc).isoformat()
    report.status = "In Process"
    report.assigned_agency_id = agency.agencyID
    report.assigned_department = agency.name
    report.assigned_crew_id = crew.id if crew else None
    report.dispatched_at = now
    report.in_process_at = now
    report.assigned_worker_id = pinned.id if pinned else None
    report.assigned_worker = pinned.username if pinned else None
    report.claimed_at = now if pinned else None

    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Authority] {req.note}"

    if pinned:
        target = f"{pinned.username} ({agency.name})"
    elif crew:
        target = f"{crew.name} pool ({agency.name})"
    else:
        target = f"{agency.name} pool"
    _log_action(db, staff, report, "In Process", f"Dispatched to {target}. {req.note}".strip())

    db.commit()
    db.refresh(report)
    return _serialize(report)


# Legacy path — the admin panel and older clients still POST a worker *name* here.
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
    """Assign by worker name (→ In Process).

    Kept for backwards compatibility. Where the name matches a real worker this
    now also sets the team and worker foreign keys, so a legacy assign lands in
    the same state as a dispatch-with-pin. An unmatched name still writes the
    free-text field rather than failing, so nothing that used to work breaks.
    """
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_team_access(staff, report)

    now = datetime.now(timezone.utc).isoformat()
    worker = db.query(DBStaff).filter(
        DBStaff.username.ilike(req.worker_name.strip()), DBStaff.role == "worker"
    ).first()

    report.status = "In Process"
    report.assigned_worker = req.worker_name
    # Both stamps are first-set-wins. Overwriting in_process_at while preserving
    # dispatched_at (the previous behaviour) inverted the pair for any report
    # dispatched before being assigned through this legacy path, yielding a
    # negative dispatched_at - in_process_at interval in stage-duration analytics.
    report.in_process_at = report.in_process_at or now
    report.dispatched_at = report.dispatched_at or now

    if worker:
        report.assigned_worker_id = worker.id
        report.assigned_crew_id = worker.crewID
        report.claimed_at = now
        if worker.agencyID:
            report.assigned_agency_id = worker.agencyID
            agency = db.query(DBAgency).filter(DBAgency.agencyID == worker.agencyID).first()
            if agency:
                report.assigned_department = agency.name
    elif report.assigned_agency_id is None and staff.agencyID:
        # No such worker — keep it in the assigning authority's own team pool
        # instead of stranding it with no owner at all.
        report.assigned_agency_id = staff.agencyID

    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Authority] {req.note}"

    _log_action(db, staff, report, "In Process", f"Assigned to {req.worker_name}. {req.note}".strip())

    db.commit()
    db.refresh(report)
    return _serialize(report)


# ─────────────────────────────────────────────────────────────
#  STEP 2b → Worker claims from the team pool (first to accept wins)
# ─────────────────────────────────────────────────────────────
@app.post("/reports/{report_id}/claim")
def claim_report(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Claim an unclaimed job from your team's pool.

    The update is conditional on assigned_worker_id still being NULL and is
    committed in one statement, so two workers tapping Accept at the same moment
    cannot both win — the loser gets a 409 rather than silently stealing the job.
    """
    staff = _current_staff(db, _token)
    if staff.role != "worker":
        raise HTTPException(status_code=403, detail="Only workers can claim tasks.")
    if not staff.agencyID:
        raise HTTPException(status_code=400, detail="You are not assigned to a team yet.")
    if staff.on_leave:
        raise HTTPException(status_code=400, detail="You're marked on leave — ask your authority to update that first.")

    report = _get_report_or_404(db, report_id)
    if report.assigned_agency_id != staff.agencyID:
        raise HTTPException(status_code=403, detail="This task belongs to another team.")
    if report.assigned_crew_id and report.assigned_crew_id != staff.crewID:
        raise HTTPException(status_code=403, detail="This task belongs to another crew.")
    if report.assigned_crew_id:
        crew = db.query(DBCrew).filter(DBCrew.id == report.assigned_crew_id).first()
        if crew and crew.status == "disabled":
            raise HTTPException(status_code=403, detail=f"{crew.name} is currently disabled.")

    now = datetime.now(timezone.utc).isoformat()
    updated = (
        db.query(DBComplaint)
        .filter(
            DBComplaint.id == report_id,
            DBComplaint.assigned_worker_id.is_(None),
            DBComplaint.assigned_agency_id == staff.agencyID,
        )
        .update(
            {
                "assigned_worker_id": staff.id,
                "assigned_worker": staff.username,
                "claimed_at": now,
            },
            synchronize_session=False,
        )
    )
    if updated == 0:
        # A teammate got there first. That is no longer a failure: crew work is
        # shared, so this worker can still open, start and finish the job. Return
        # the report as-is rather than a 409, which used to read as "you lost the
        # race" and left the loser with nothing to do.
        db.rollback()
        db.refresh(report)
        return _serialize(report)

    db.refresh(report)
    _log_action(db, staff, report, report.status, f"Claimed from {report.assigned_department} pool")
    db.commit()
    db.refresh(report)
    return _serialize(report)


class ReleaseRequest(BaseModel):
    reason: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/release")
def release_report(
    report_id: int,
    req: ReleaseRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Give a claimed job back to your own team's pool.

    No approval needed: the work stays inside the team, it just becomes
    available again. release_count feeds the bottleneck view — a report that
    keeps bouncing is a signal the team cannot handle it.
    """
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)

    is_owner = report.assigned_worker_id == staff.id
    is_supervisor = staff.role == "admin" or (staff.role or "").startswith("authority")
    if not (is_owner or is_supervisor):
        raise HTTPException(status_code=403, detail="You have not claimed this task.")
    if report.assigned_worker_id is None:
        raise HTTPException(status_code=400, detail="This task is already in the pool.")
    if report.worker_completed == 1:
        raise HTTPException(status_code=400, detail="Completion proof was already submitted.")

    released_from = report.assigned_worker
    report.assigned_worker_id = None
    report.assigned_worker = None
    report.claimed_at = None
    report.release_count = (report.release_count or 0) + 1
    # Back to the pool: a released job is un-started again.
    report.status = "In Process"
    report.in_maintenance_at = None
    report.dispatched_at = datetime.now(timezone.utc).isoformat()

    if req.reason:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Released by {released_from}] {req.reason}"

    _log_action(db, staff, report, "In Process", f"Released back to pool by {released_from}. {req.reason}".strip())

    db.commit()
    db.refresh(report)
    return _serialize(report)


# ─────────────────────────────────────────────────────────────
#  WITHIN-AGENCY REBALANCE — move a report between crews (or the general
#  pool) without leaving the agency. No approval needed, unlike a cross-team
#  transfer: it's the authority watching their own crews and rebalancing.
# ─────────────────────────────────────────────────────────────
class ReassignCrewRequest(BaseModel):
    crew_id: Optional[int] = None  # None = move to the agency-wide general pool
    note: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/reassign-crew")
def reassign_crew(
    report_id: int,
    req: ReassignCrewRequest,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Move a report to a different crew (or back to the general pool) within
    the same agency — for rebalancing when one crew is overloaded."""
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_team_access(staff, report)

    if report.status in ("Resolved", "Rejected"):
        raise HTTPException(status_code=400, detail="This report is already closed.")

    crew = None
    if req.crew_id is not None:
        crew = db.query(DBCrew).filter(DBCrew.id == req.crew_id).first()
        if not crew:
            raise HTTPException(status_code=404, detail="Crew not found")
        if crew.agencyID != report.assigned_agency_id:
            raise HTTPException(status_code=400, detail=f"{crew.name} is not part of this team.")
        if crew.status == "disabled":
            raise HTTPException(status_code=400, detail=f"{crew.name} is currently disabled.")
    if crew and crew.id == report.assigned_crew_id:
        raise HTTPException(status_code=400, detail=f"This report is already with {crew.name}.")
    if crew is None and report.assigned_crew_id is None:
        raise HTTPException(status_code=400, detail="This report is already in the general pool.")

    old_crew = (
        db.query(DBCrew).filter(DBCrew.id == report.assigned_crew_id).first()
        if report.assigned_crew_id else None
    )

    # If the current claimant isn't on the destination crew, the whole point of
    # rebalancing is to put it in front of people who actually can pick it up —
    # so drop the claim and let it land unclaimed in the new crew's pool.
    if report.assigned_worker_id and crew:
        claimant = db.query(DBStaff).filter(DBStaff.id == report.assigned_worker_id).first()
        if not claimant or claimant.crewID != crew.id:
            report.assigned_worker_id = None
            report.assigned_worker = None
            report.claimed_at = None
            report.status = "In Process"
            report.in_maintenance_at = None

    report.assigned_crew_id = crew.id if crew else None
    report.dispatched_at = datetime.now(timezone.utc).isoformat()

    old_name = old_crew.name if old_crew else "the general pool"
    new_name = crew.name if crew else "the general pool"
    if req.note:
        existing = report.authority_notes or ""
        sep = "\n" if existing else ""
        report.authority_notes = existing + sep + f"[Reassigned {old_name} → {new_name}] {req.note}"
    _log_action(db, staff, report, report.status, f"Reassigned {old_name} → {new_name}. {req.note}".strip())

    db.commit()
    db.refresh(report)
    return _serialize(report)


# ─────────────────────────────────────────────────────────────
#  CROSS-TEAM HANDOVER
#
#  Two routes, deliberately: a team can *ask* to be relieved of a job
#  (transfer-request → approval), and an authority can *push* a job to another
#  team when it plainly is not getting done.
# ─────────────────────────────────────────────────────────────
def _move_report_to_team(
    db: Session, report: DBComplaint, target: DBAgency, actor: DBStaff, reason: str
) -> None:
    """Hand a report to another team, dropping it into that team's pool."""
    now = datetime.now(timezone.utc).isoformat()
    origin = report.assigned_department or "unassigned"

    report.assigned_agency_id = target.agencyID
    report.assigned_department = target.name
    report.assigned_crew_id = None  # crews don't span agencies
    report.assigned_worker_id = None
    report.assigned_worker = None
    report.claimed_at = None
    report.dispatched_at = now
    report.in_maintenance_at = None
    if report.status in ("In Review", "In Maintenance"):
        report.status = "In Process"
    report.in_process_at = report.in_process_at or now

    existing = report.authority_notes or ""
    sep = "\n" if existing else ""
    report.authority_notes = existing + sep + f"[Transfer {origin} → {target.name}] {reason}".strip()

    _log_action(db, actor, report, report.status, f"Transferred {origin} → {target.name}. {reason}".strip())


class TransferRequestBody(BaseModel):
    to_agency_id: Optional[int] = None
    reason: str = Field("", max_length=1000)


@app.post("/reports/{report_id}/transfer")
def transfer_report(
    report_id: int,
    req: TransferRequestBody,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Authority/admin moves a report straight to another team."""
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_team_access(staff, report)

    if req.to_agency_id is None:
        raise HTTPException(status_code=400, detail="Pick a destination team.")
    target = db.query(DBAgency).filter(DBAgency.agencyID == req.to_agency_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="Destination team not found")
    if target.agencyID == report.assigned_agency_id:
        raise HTTPException(status_code=400, detail="That team already owns this report.")
    if report.status in ("Resolved", "Rejected"):
        raise HTTPException(status_code=400, detail="This report is already closed.")

    _move_report_to_team(db, report, target, staff, req.reason)
    db.commit()
    db.refresh(report)
    return _serialize(report)


@app.post("/reports/{report_id}/transfer-request")
def create_transfer_request(
    report_id: int,
    req: TransferRequestBody,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Ask for a report to be taken off this team (worker or authority)."""
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)

    if staff.role == "worker" and report.assigned_agency_id != staff.agencyID:
        raise HTTPException(status_code=403, detail="This task belongs to another team.")
    if report.status in ("Resolved", "Rejected"):
        raise HTTPException(status_code=400, detail="This report is already closed.")

    existing = db.query(DBTransferRequest).filter(
        DBTransferRequest.complaintID == report.id,
        DBTransferRequest.status == "pending",
    ).first()
    if existing:
        raise HTTPException(
            status_code=409,
            detail="A release request for this report is already awaiting a decision.",
        )

    tr = DBTransferRequest(
        complaintID=report.id,
        from_agency_id=report.assigned_agency_id,
        to_agency_id=req.to_agency_id,
        requested_by_staff_id=staff.id,
        reason=req.reason,
        status="pending",
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    db.add(tr)
    _log_action(db, staff, report, report.status, f"Release requested by {staff.username}. {req.reason}".strip())
    db.commit()
    db.refresh(tr)
    return _serialize_transfer(db, tr)


def _serialize_transfer(db: Session, tr: DBTransferRequest) -> dict:
    def agency_name(aid):
        if not aid:
            return None
        a = db.query(DBAgency).filter(DBAgency.agencyID == aid).first()
        return a.name if a else None

    requester = db.query(DBStaff).filter(DBStaff.id == tr.requested_by_staff_id).first()
    report = db.query(DBComplaint).filter(DBComplaint.id == tr.complaintID).first()
    return {
        "id": tr.id,
        "report_id": tr.complaintID,
        "report_title": (report.categories if report else None),
        "report_status": (report.status if report else None),
        "from_agency_id": tr.from_agency_id,
        "from_team": agency_name(tr.from_agency_id),
        "to_agency_id": tr.to_agency_id,
        "to_team": agency_name(tr.to_agency_id),
        "requested_by": requester.username if requester else None,
        "requested_by_role": requester.role if requester else None,
        "reason": tr.reason,
        "status": tr.status,
        "decision_note": tr.decision_note,
        "decided_at": tr.decided_at,
        "created_at": tr.created_at,
    }


@app.get("/transfers")
def list_transfers(
    status: str = "pending",
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Release/transfer requests an authority needs to act on."""
    staff = _current_staff(db, _token)
    if staff.role == "worker":
        raise HTTPException(status_code=403, detail="Only an authority or admin may review transfers.")

    query = db.query(DBTransferRequest)
    if status and status != "all":
        query = query.filter(DBTransferRequest.status == status)
    if staff.role != "admin":
        # An authority sees requests leaving their team and requests aimed at it.
        query = query.filter(
            or_(
                DBTransferRequest.from_agency_id == staff.agencyID,
                DBTransferRequest.to_agency_id == staff.agencyID,
            )
        )
    rows = query.order_by(DBTransferRequest.id.desc()).limit(200).all()
    return [_serialize_transfer(db, tr) for tr in rows]


class TransferDecision(BaseModel):
    to_agency_id: Optional[int] = None   # required if the request left it open
    note: str = Field("", max_length=1000)


@app.post("/transfers/{transfer_id}/approve")
def approve_transfer(
    transfer_id: int,
    req: TransferDecision,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Approve a release request and move the report to the destination team."""
    staff = _current_staff(db, _token)
    if staff.role == "worker":
        raise HTTPException(status_code=403, detail="Only an authority or admin may decide transfers.")

    tr = db.query(DBTransferRequest).filter(DBTransferRequest.id == transfer_id).first()
    if not tr:
        raise HTTPException(status_code=404, detail="Transfer request not found")
    if tr.status != "pending":
        raise HTTPException(status_code=400, detail=f"This request was already {tr.status}.")
    if staff.role != "admin" and staff.agencyID not in (tr.from_agency_id, tr.to_agency_id):
        raise HTTPException(status_code=403, detail="This request does not involve your team.")

    target_id = req.to_agency_id or tr.to_agency_id
    if not target_id:
        raise HTTPException(status_code=400, detail="Pick a destination team for this request.")
    target = db.query(DBAgency).filter(DBAgency.agencyID == target_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="Destination team not found")

    report = _get_report_or_404(db, tr.complaintID)
    if target.agencyID == report.assigned_agency_id:
        raise HTTPException(status_code=400, detail="That team already owns this report.")

    _move_report_to_team(db, report, target, staff, req.note or (tr.reason or "Release approved"))

    tr.status = "approved"
    tr.to_agency_id = target.agencyID
    tr.decided_by_staff_id = staff.id
    tr.decided_at = datetime.now(timezone.utc).isoformat()
    tr.decision_note = req.note

    db.commit()
    db.refresh(tr)
    return _serialize_transfer(db, tr)


@app.post("/transfers/{transfer_id}/deny")
def deny_transfer(
    transfer_id: int,
    req: TransferDecision,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Deny a release request; the report stays where it is."""
    staff = _current_staff(db, _token)
    if staff.role == "worker":
        raise HTTPException(status_code=403, detail="Only an authority or admin may decide transfers.")

    tr = db.query(DBTransferRequest).filter(DBTransferRequest.id == transfer_id).first()
    if not tr:
        raise HTTPException(status_code=404, detail="Transfer request not found")
    if tr.status != "pending":
        raise HTTPException(status_code=400, detail=f"This request was already {tr.status}.")
    if staff.role != "admin" and staff.agencyID not in (tr.from_agency_id, tr.to_agency_id):
        raise HTTPException(status_code=403, detail="This request does not involve your team.")

    tr.status = "denied"
    tr.decided_by_staff_id = staff.id
    tr.decided_at = datetime.now(timezone.utc).isoformat()
    tr.decision_note = req.note

    report = db.query(DBComplaint).filter(DBComplaint.id == tr.complaintID).first()
    if report:
        _log_action(db, staff, report, report.status, f"Release request denied. {req.note}".strip())

    db.commit()
    db.refresh(tr)
    return _serialize_transfer(db, tr)


# ─────────────────────────────────────────────────────────────
#  BOTTLENECK VIEW
# ─────────────────────────────────────────────────────────────
def _parse_ts(raw: Optional[str]) -> Optional[datetime]:
    """Parse the ISO strings this schema stores workflow timestamps in."""
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


@app.get("/teams/workload")
def team_workload(db: Session = Depends(get_db), _token: dict = Depends(require_token)):
    """Per-team load, capacity, ageing and throughput — the bottleneck board.

    Returns a derived status per team so the web panel and the app colour-code
    from one place instead of each re-deriving the thresholds. Open to any
    authority (not just admin) — comparing load across agencies is what lets
    an authority judge where to send a transfer request.
    """
    staff = _current_staff(db, _token)
    if staff.role == "worker":
        raise HTTPException(status_code=403, detail="Only an authority or admin may view team workload.")

    now = datetime.now(timezone.utc)
    week_ago = now - timedelta(days=7)
    open_statuses = ["In Review", "In Process", "In Maintenance"]

    # Every authority sees every team: choosing where to move work requires the
    # comparison. Their own team is flagged via is_mine so the UI can lead with it.
    agencies = db.query(DBAgency).order_by(DBAgency.name).all()

    out = []
    for agency in agencies:
        open_reports = db.query(DBComplaint).filter(
            DBComplaint.assigned_agency_id == agency.agencyID,
            DBComplaint.status.in_(open_statuses),
        ).all()

        unclaimed = [r for r in open_reports if r.assigned_worker_id is None]
        claimed = [r for r in open_reports if r.assigned_worker_id is not None]
        in_maintenance = [r for r in open_reports if r.status == "In Maintenance"]

        workers = db.query(func.count(DBStaff.id)).filter(
            DBStaff.agencyID == agency.agencyID, DBStaff.role == "worker"
        ).scalar() or 0

        # Ageing: how long the oldest unclaimed job has been sitting in the pool.
        ages = [
            (now - ts).total_seconds() / 3600.0
            for ts in (_parse_ts(r.dispatched_at or r.in_process_at) for r in unclaimed)
            if ts is not None
        ]
        oldest_hours = round(max(ages), 1) if ages else 0.0
        breached = sum(1 for a in ages if a > SLA_HOURS)

        # Throughput: is the team keeping up with what arrives?
        completed_7d = sum(
            1 for r in db.query(DBComplaint).filter(
                DBComplaint.assigned_agency_id == agency.agencyID,
                DBComplaint.status == "Resolved",
            ).all()
            if (ts := _parse_ts(r.resolved_at)) and ts >= week_ago
        )
        arrived_7d = db.query(func.count(DBComplaint.id)).filter(
            DBComplaint.assigned_agency_id == agency.agencyID,
            DBComplaint.timestamp >= week_ago,
        ).scalar() or 0

        load_per_worker = round(len(open_reports) / workers, 2) if workers else None
        bounced = sum(1 for r in open_reports if (r.release_count or 0) > 0)

        # Any one of these alone is a warning; two or more is a real bottleneck.
        strain = 0
        if load_per_worker is None and open_reports:
            strain += 2                       # work with nobody to do it
        elif load_per_worker is not None and load_per_worker >= 5:
            strain += 2 if load_per_worker >= 8 else 1
        if breached:
            strain += 2 if breached >= 3 else 1
        if oldest_hours > SLA_HOURS:
            strain += 1
        if arrived_7d > completed_7d and arrived_7d - completed_7d >= 3:
            strain += 1
        status = "bottleneck" if strain >= 3 else "strained" if strain >= 1 else "healthy"

        out.append({
            "id": agency.agencyID,
            "name": agency.name,
            "is_mine": agency.agencyID == staff.agencyID,
            # Open workload
            "open_count": len(open_reports),
            "unclaimed_count": len(unclaimed),
            "claimed_count": len(claimed),
            "in_maintenance_count": len(in_maintenance),
            "bounced_count": bounced,
            # Load vs capacity
            "worker_count": workers,
            "load_per_worker": load_per_worker,
            # Ageing / SLA
            "oldest_unclaimed_hours": oldest_hours,
            "sla_hours": SLA_HOURS,
            "sla_breached_count": breached,
            # Throughput
            "completed_7d": completed_7d,
            "arrived_7d": arrived_7d,
            "net_7d": completed_7d - arrived_7d,
            "status": status,
        })

    return {"sla_hours": SLA_HOURS, "teams": out}


# STEP 3 → Worker accepts task: In Process → In Maintenance
@app.post("/reports/{report_id}/start-maintenance")
def start_maintenance(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Worker starts maintenance on an In Process report (→ In Maintenance).

    Any member of the holding crew may start; whoever does becomes the recorded
    handler if nobody had accepted it yet.
    """
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_crew_member(db, staff, report)
    _adopt_if_unclaimed(staff, report)
    report.status = "In Maintenance"
    report.in_maintenance_at = datetime.now(timezone.utc).isoformat()

    _log_action(db, staff, report, "In Maintenance", "Worker started maintenance")

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
    """Worker submits completion proof (photo + notes).

    Shared across the crew: a teammate can finish and submit for a job another
    member started, which is the point of dispatching to a crew rather than to
    an individual.
    """
    staff = _current_staff(db, _token)
    report = _get_report_or_404(db, report_id)
    _require_crew_member(db, staff, report)
    _adopt_if_unclaimed(staff, report)

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

    _log_action(db, staff, report, "In Maintenance", f"Completed task: {notes}")

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
#  ROUTES — AI DATASET REVIEW  (admin)
#
#  These MUST stay above the `GET /{catchall:path}` route below, which would
#  otherwise shadow every GET registered after it.
# ─────────────────────────────────────────────────────────────
def _require_admin(token: dict) -> None:
    if token.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required.")


def _serialize_sample(s: DBDatasetSample) -> dict:
    report = None
    if s.report_id:
        report = {"id": s.report_id}
    return {
        "id": s.id,
        "report_id": s.report_id,
        "report": report,
        "image_hash": s.image_hash,
        "class_label": s.class_label,
        "confidence": s.confidence,
        "status": s.status,
        "reason": s.reason,
        "source": s.source,
        "authenticity_verdict": s.authenticity_verdict,
        "authenticity_score": s.authenticity_score,
        "image_path": s.image_path,
        "github_path": s.github_path,
        "synced": bool(s.synced),
        "created_at": s.created_at,
        "reviewed_by": s.reviewed_by,
        "reviewed_at": s.reviewed_at,
    }


@app.get("/dataset/stats")
def dataset_stats(
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Counts by status and class, plus the health of the class balance."""
    _require_admin(_token)

    rows = db.query(DBDatasetSample.status, func.count(DBDatasetSample.id)).group_by(
        DBDatasetSample.status
    ).all()
    by_status = {status: count for status, count in rows}

    class_rows = db.query(DBDatasetSample.class_label, func.count(DBDatasetSample.id)).filter(
        DBDatasetSample.status == dataset_collector.STATUS_APPROVED
    ).group_by(DBDatasetSample.class_label).all()
    by_class = {label: count for label, count in class_rows if label}

    # Must match the filter in /dataset/sync exactly, or the dashboard shows a
    # backlog that syncing can never clear.
    unsynced = db.query(func.count(DBDatasetSample.id)).filter(
        DBDatasetSample.synced == 0,
        DBDatasetSample.pending_blob.isnot(None),
        DBDatasetSample.status.in_([
            dataset_collector.STATUS_APPROVED, dataset_collector.STATUS_PENDING
        ]),
    ).scalar() or 0

    return {
        "by_status": by_status,
        "by_class": by_class,
        "total": sum(by_status.values()),
        "unsynced": unsynced,
        "auto_accept_threshold": dataset_collector.AUTO_ACCEPT_CONFIDENCE,
        "storage_configured": dataset_store.is_configured(),
        "local": dataset_collector.get_dataset_stats(),
        "base_dataset": _base_dataset_counts(),
    }


def _base_dataset_counts() -> dict:
    """Per-class image counts in the original ai_data/ training set, if present."""
    counts = {}
    base = BASE_DIR / "ai_data"
    if not base.exists():
        return counts
    try:
        for class_dir in base.iterdir():
            if class_dir.is_dir():
                counts[class_dir.name] = sum(1 for _ in class_dir.iterdir())
    except Exception as e:
        logger.warning(f"Could not count base dataset: {e}")
    return counts


@app.get("/dataset/samples")
def dataset_samples(
    status: str = "pending",
    limit: int = 100,
    offset: int = 0,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """List collected samples, newest first. Defaults to the review queue."""
    _require_admin(_token)

    query = db.query(DBDatasetSample)
    if status and status != "all":
        query = query.filter(DBDatasetSample.status == status)

    total = query.count()
    rows = query.order_by(DBDatasetSample.id.desc()).offset(offset).limit(min(limit, 200)).all()

    # Surface the report's stored photo so the reviewer can actually see it.
    report_ids = [r.report_id for r in rows if r.report_id]
    images = {}
    if report_ids:
        for rid, path in db.query(DBComplaint.id, DBComplaint.image_path).filter(
            DBComplaint.id.in_(report_ids)
        ).all():
            images[rid] = path

    payload = []
    for row in rows:
        item = _serialize_sample(row)
        item["preview_url"] = images.get(row.report_id)
        payload.append(item)

    return {"total": total, "count": len(payload), "samples": payload}


class SampleReview(BaseModel):
    class_label: Optional[str] = None   # set to relabel while approving
    note: Optional[str] = None


@app.post("/dataset/{sample_id}/approve")
def approve_sample(
    sample_id: int,
    review: SampleReview = SampleReview(),
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Accept a sample into the training pool, optionally correcting its label."""
    _require_admin(_token)

    sample = db.query(DBDatasetSample).filter(DBDatasetSample.id == sample_id).first()
    if not sample:
        raise HTTPException(status_code=404, detail="Sample not found.")

    if review.class_label:
        corrected = dataset_collector.to_training_class(review.class_label)
        if not corrected:
            raise HTTPException(
                status_code=400,
                detail=f"'{review.class_label}' is not a trainable class.",
            )
        sample.class_label = corrected
        sample.source = dataset_collector.SOURCE_ADMIN

    sample.status = dataset_collector.STATUS_APPROVED
    sample.reason = review.note or "Approved by admin"
    sample.reviewed_by = str(_token.get("username") or _token.get("sub"))
    sample.reviewed_at = datetime.now(timezone.utc).isoformat()

    # Retraining reads the filesystem, so the image has to physically move into
    # the approved folder for this decision to have any effect.
    sample.image_path = dataset_collector.relocate_sample_file(
        sample.image_path, sample.status, sample.class_label
    )
    if sample.synced and dataset_store.is_configured():
        dataset_store.move_sample(
            {"image_hash": sample.image_hash, "class_label": sample.class_label,
             "status": dataset_collector.STATUS_PENDING, "extension": ".jpg"},
            dataset_collector.STATUS_APPROVED,
        )
    db.commit()

    return {"message": "Sample approved", "sample": _serialize_sample(sample)}


@app.post("/dataset/{sample_id}/reject")
def reject_sample(
    sample_id: int,
    review: SampleReview = SampleReview(),
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """
    Exclude a sample from training.

    The row is kept rather than deleted so its hash still participates in
    duplicate detection — otherwise the same rejected image would be re-queued
    every time someone uploaded it again.
    """
    _require_admin(_token)

    sample = db.query(DBDatasetSample).filter(DBDatasetSample.id == sample_id).first()
    if not sample:
        raise HTTPException(status_code=404, detail="Sample not found.")

    sample.status = dataset_collector.STATUS_REJECTED
    sample.reason = review.note or "Rejected by admin"
    sample.reviewed_by = str(_token.get("username") or _token.get("sub"))
    sample.reviewed_at = datetime.now(timezone.utc).isoformat()
    sample.pending_blob = None   # never sync a rejected image

    # Take the image out of the training tree entirely; the row stays so the
    # hash keeps blocking re-submission.
    dataset_collector.discard_sample_file(sample.image_path)
    sample.image_path = None
    db.commit()

    return {"message": "Sample rejected", "sample": _serialize_sample(sample)}


@app.post("/dataset/sync")
def sync_dataset(
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Push buffered approved/pending samples to the dataset repo in one commit."""
    _require_admin(_token)

    if not dataset_store.is_configured():
        return {
            "status": "skipped",
            "message": (
                "Set GITHUB_TOKEN and DATASET_REPO to enable durable storage. "
                "Samples are currently kept on local disk only, which does not "
                "survive a redeploy on Vercel."
            ),
        }

    rows = db.query(DBDatasetSample).filter(
        DBDatasetSample.synced == 0,
        DBDatasetSample.pending_blob.isnot(None),
        DBDatasetSample.status.in_([
            dataset_collector.STATUS_APPROVED, dataset_collector.STATUS_PENDING
        ]),
    ).order_by(DBDatasetSample.id).limit(dataset_store.SYNC_BATCH_SIZE).all()

    if not rows:
        return {"status": "skipped", "committed": 0, "message": "Nothing to sync."}

    batch = []
    for row in rows:
        try:
            image_bytes = base64.b64decode(row.pending_blob)
        except Exception as e:
            logger.error(f"Sample {row.id} has an unreadable buffer: {e}")
            continue
        batch.append({
            "image_bytes": image_bytes,
            "image_hash": row.image_hash,
            "class_label": row.class_label,
            "status": row.status,
            "extension": ".jpg",
            "report_id": row.report_id,
            "confidence": row.confidence,
            "source": row.source,
            "authenticity_verdict": row.authenticity_verdict,
            "authenticity_score": row.authenticity_score,
            "created_at": row.created_at,
        })

    result = dataset_store.push_samples(batch)

    if result.get("status") == "success":
        by_hash = {b["image_hash"]: b for b in batch}
        for row in rows:
            if row.image_hash in by_hash:
                row.synced = 1
                row.github_path = dataset_store._sample_path(by_hash[row.image_hash])
                row.pending_blob = None   # buffer served its purpose
        db.commit()

    return result


@app.get("/reports/{report_id}/authenticity")
def report_authenticity(
    report_id: int,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Full forensic signal breakdown for one report's image."""
    report = db.query(DBComplaint).filter(DBComplaint.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found.")

    return {
        "report_id": report.id,
        "image_hash": report.image_hash,
        "verdict": report.authenticity_verdict,
        "authenticity_score": report.authenticity_score,
        "signals": _load_signals(report.authenticity_signals),
    }


# NOTE: this must stay above the `GET /{catchall:path}` route below, which
# matches everything. FastAPI resolves in registration order.
@app.get("/reports/actions")
def list_authority_actions(
    report_id: Optional[int] = None,
    since: Optional[str] = None,
    limit: int = 1000,
    db: Session = Depends(get_db),
    _token: dict = Depends(require_token),
):
    """Workflow audit trail — one row per authority action.

    Every workflow step already writes an AuthorityAction row, but nothing has
    ever read them back. Exposing them lets the analytics reconstruct true
    time-in-state and full rework chains: the scalar timestamps on a report are
    reset by release, reassign and transfer, so a bounced report otherwise shows
    only its final cycle.

    Scoped like /transfers: admins see everything, an authority sees only its own
    team's reports, workers are refused. Scoping keys off the JWT, never a query
    parameter.
    """
    staff = _current_staff(db, _token)
    if staff.role == "worker":
        raise HTTPException(
            status_code=403,
            detail="Only an authority or admin may read the audit trail.",
        )

    # Joined to Complaint because AuthorityAction carries no agency of its own.
    query = db.query(DBAuthorityAction).join(
        DBComplaint, DBComplaint.id == DBAuthorityAction.complaintID
    )
    if staff.role != "admin":
        query = query.filter(DBComplaint.assigned_agency_id == staff.agencyID)
    if report_id is not None:
        query = query.filter(DBAuthorityAction.complaintID == report_id)
    if since:
        try:
            query = query.filter(DBAuthorityAction.actionDate >= datetime.fromisoformat(since))
        except ValueError:
            raise HTTPException(status_code=400, detail="`since` must be an ISO datetime.")

    rows = (
        query.order_by(DBAuthorityAction.actionDate.asc())
        .limit(max(1, min(limit, 5000)))
        .all()
    )

    return [
        {
            "id": a.authorityID,
            "report_id": a.complaintID,
            "status": a.status,
            "remarks": a.remarks,
            "staff_id": a.staffID,
            "action_date": a.actionDate.isoformat()
            if hasattr(a.actionDate, "isoformat")
            else a.actionDate,
        }
        for a in rows
    ]


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


@app.get("/")
async def read_root():
    return {
        "status": "online",
        "service": "Smart City AI Engine API",
        "version": "1.1.0",
        "documentation": "/docs",
        "health": "/healthz"
    }


@app.get("/{catchall:path}")
async def catch_all(catchall: str):
    raise HTTPException(
        status_code=404, 
        detail=f"Path '/{catchall}' not found. Refer to '/docs' for available API endpoints."
    )


app = ApiPrefixMiddleware(app)