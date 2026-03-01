from fastapi import FastAPI, File, UploadFile, HTTPException
import tensorflow as tf
from tensorflow.keras.models import load_model
from PIL import Image, ImageOps
import numpy as np
from pathlib import Path

app = FastAPI()

# 1. Setup Absolute Paths (Prevents FileNotFoundError)
BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"

# 2. Safely Load Model and Labels at Startup
if not MODEL_PATH.exists() or not LABELS_PATH.exists():
    raise FileNotFoundError(f"Critical Error: Ensure both '{MODEL_PATH.name}' and '{LABELS_PATH.name}' exist in the '{BASE_DIR}' folder.")

model = load_model(MODEL_PATH, compile=False)

# Use 'with open' to safely read and automatically close the file
with open(LABELS_PATH, "r") as f:
    class_names = [line.strip() for line in f.readlines()]

@app.get("/")
def home():
    return {"message": "Smart City AI Engine is active!"}

@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    try:
        # 3. Efficiently convert the uploaded file to a PIL Image
        image = Image.open(file.file).convert("RGB")

        # 4. Preprocess the image to match AI training (224x224)
        size = (224, 224)
        image = ImageOps.fit(image, size, Image.Resampling.LANCZOS)
        
        # Grab the raw pixel data (values from 0 to 255)
        image_array = np.asarray(image)
        
        # Prepare data structure for prediction
        data = np.ndarray(shape=(1, 224, 224, 3), dtype=np.float32)
        
        # THE FIX: Pass the raw 0-255 pixels directly to the model.
        # We REMOVED the manual math normalization here because the model's new
        # built-in 'Rescaling' layer handles it automatically!
        data[0] = image_array

        # 5. Run the Prediction
        prediction = model.predict(data)
        index = np.argmax(prediction)
        
        # 6. Return JSON result 
        # THE FIX: Split by the first space to safely separate the number from the label.
        # This handles double-digit labels correctly (e.g., "10 Pothole")
        class_name = class_names[index].split(" ", 1)[-1]
        confidence_score = float(prediction[0][index])

        return {
            "issue_type": class_name.strip(), 
            "confidence": f"{round(confidence_score * 100, 2)}%"
        }
        
    except Exception as e:
        # 7. Catch errors without crashing the server
        raise HTTPException(status_code=400, detail=f"Error processing the file. Make sure it is a valid image. Details: {str(e)}")