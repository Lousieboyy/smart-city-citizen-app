from fastapi import FastAPI, File, UploadFile, HTTPException, Form
from fastapi.staticfiles import StaticFiles
from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker
from pydantic import BaseModel
from datetime import datetime, timezone
import hashlib
import shutil
import uuid
import tensorflow as tf
from tensorflow.keras.models import load_model
from PIL import Image, ImageOps
import numpy as np
from pathlib import Path

app = FastAPI()

# --- Database & Static Files Setup ---
DATABASE_URL = "sqlite:///./reports.db"
engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class DBUser(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True)
    password_hash = Column(String)

class DBReport(Base):
    __tablename__ = "reports"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"))
    description = Column(String)
    location = Column(String)
    address = Column(String)
    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)
    categories = Column(String)
    ai_prediction = Column(String)
    confidence = Column(String)
    image_path = Column(String)
    status = Column(String, default="Pending")
    timestamp = Column(DateTime, default=lambda: datetime.now(timezone.utc))

Base.metadata.create_all(bind=engine)

# Auto-create test user
def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()

db = SessionLocal()
if not db.query(DBUser).filter(DBUser.username == "test").first():
    test_user = DBUser(username="test", password_hash=hash_password("test1234"))
    db.add(test_user)
    db.commit()
db.close()

# 1. Setup Absolute Paths
BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"

# Setup Uploads directory
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)
app.mount("/uploads", StaticFiles(directory=UPLOAD_DIR), name="uploads")

# 2. Safely Load Model and Labels
if not MODEL_PATH.exists() or not LABELS_PATH.exists():
    raise FileNotFoundError(f"Critical Error: Ensure both '{MODEL_PATH.name}' and '{LABELS_PATH.name}' exist.")

# This will now load without any "TrueDivide" errors!
model = load_model(MODEL_PATH, compile=False)

with open(LABELS_PATH, "r") as f:
    class_names = [line.strip() for line in f.readlines()]

@app.get("/")
def home():
    return {"message": "Smart City AI Engine is active!"}

@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    try:
        # 3. Open and Resize Image
        image = Image.open(file.file).convert("RGB")
        size = (224, 224)
        image = ImageOps.fit(image, size, Image.Resampling.LANCZOS)
        
        # 4. Turn image into numbers (Pixels)
        image_array = np.asarray(image).astype(np.float32)
        
        # --- THE FIX: MANUAL NORMALIZATION ---
        # Because we removed the 'Rescaling' layer from the brain,
        # we must dim the lights ourselves here.
        # This converts pixels (0 to 255) into the range (-1 to 1).
        processed_data = (image_array / 127.5) - 1
        
        # Prepare data structure for prediction
        data = np.ndarray(shape=(1, 224, 224, 3), dtype=np.float32)
        data[0] = processed_data 

        # 5. Run the Prediction
        prediction = model.predict(data)
        index = np.argmax(prediction)
        
        # 6. Return JSON result 
        class_name = class_names[index].split(" ", 1)[-1]
        confidence_score = float(prediction[0][index])

        return {
            "issue_type": class_name.strip(), 
            "confidence": f"{round(confidence_score * 100, 2)}%"
        }
        
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error: {str(e)}")

# --- Authentication Routes ---
class AuthRequest(BaseModel):
    username: str
    password: str

@app.post("/signup")
def signup(req: AuthRequest):
    db = SessionLocal()
    if db.query(DBUser).filter(DBUser.username == req.username).first():
        db.close()
        raise HTTPException(status_code=400, detail="Username already registered")
        
    new_user = DBUser(
        username=req.username,
        password_hash=hash_password(req.password)
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    db.close()
    return {"message": "User created successfully", "user_id": new_user.id}

@app.post("/login")
def login(req: AuthRequest):
    db = SessionLocal()
    user = db.query(DBUser).filter(DBUser.username == req.username).first()
    db.close()
    
    if not user or user.password_hash != hash_password(req.password):
        raise HTTPException(status_code=401, detail="Invalid username or password")
        
    # In a real app we'd return a JWT Token. For this prototype, we'll return user_id.
    return {"message": "Login successful", "user_id": user.id, "username": user.username}

@app.get("/reports/")
def get_reports(user_id: int = None):
    db = SessionLocal()
    query = db.query(DBReport)
    if user_id is not None:
        query = query.filter(DBReport.user_id == user_id)
    reports = query.order_by(DBReport.timestamp.desc()).all()
    db.close()
    
    # Convert to dicts so lat/lon serialize properly
    result = []
    for r in reports:
        result.append({
            "id": r.id,
            "user_id": r.user_id,
            "description": r.description,
            "location": r.location,
            "address": r.address,
            "latitude": r.latitude,
            "longitude": r.longitude,
            "categories": r.categories,
            "ai_prediction": r.ai_prediction,
            "confidence": r.confidence,
            "image_path": r.image_path,
            "status": r.status,
            "timestamp": r.timestamp.isoformat() if r.timestamp else None,
        })
    return result

@app.get("/reports/stats")
def get_report_stats(user_id: int = None):
    db = SessionLocal()
    query = db.query(DBReport)
    if user_id is not None:
        query = query.filter(DBReport.user_id == user_id)
    reports = query.all()
    db.close()
    
    total = len(reports)
    pending = sum(1 for r in reports if (r.status or "Pending") == "Pending")
    resolved = sum(1 for r in reports if (r.status or "") == "Resolved")
    in_progress = total - pending - resolved
    
    # Category breakdown
    categories = {}
    for r in reports:
        for cat in (r.categories or "").split(","):
            cat = cat.strip()
            if cat:
                categories[cat] = categories.get(cat, 0) + 1
    
    return {
        "total": total,
        "pending": pending,
        "resolved": resolved,
        "in_progress": in_progress,
        "categories": categories,
    }

@app.post("/reports/")
async def create_report(
    user_id: int = Form(...),
    description: str = Form(...),
    location: str = Form(...),
    address: str = Form("Unknown location"),
    latitude: float = Form(None),
    longitude: float = Form(None),
    categories: str = Form(...),
    ai_prediction: str = Form(...),
    confidence: str = Form(...),
    file: UploadFile = File(...)
):
    try:
        # Save image
        file_ext = Path(file.filename).suffix
        unique_filename = f"{uuid.uuid4()}{file_ext}"
        file_path = UPLOAD_DIR / unique_filename
        
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        # Create DB record
        db = SessionLocal()
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
            image_path=f"/uploads/{unique_filename}"
        )
        db.add(new_report)
        db.commit()
        db.refresh(new_report)
        db.close()
        
        return {"message": "Report submitted successfully", "id": new_report.id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))