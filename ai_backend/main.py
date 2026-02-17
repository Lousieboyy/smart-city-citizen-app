from fastapi import FastAPI, File, UploadFile
import tensorflow as tf
from tensorflow import keras
from keras.models import load_model
from PIL import Image, ImageOps
import numpy as np
import io

app = FastAPI()

# 1. Load the Teachable Machine model and labels
# Ensure 'keras_Model.h5' and 'labels.txt' are in the same folder
model = load_model("keras_Model.h5", compile=False)
class_names = [line.strip() for line in open("labels.txt", "r").readlines()]

@app.get("/")
def home():
    return {"message": "Smart City AI Engine is active!"}

@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    # 2. Convert the uploaded file to a PIL Image
    contents = await file.read()
    image = Image.open(io.BytesIO(contents)).convert("RGB")

    # 3. Preprocess the image to match AI training (224x224)
    size = (224, 224)
    image = ImageOps.fit(image, size, Image.Resampling.LANCZOS)
    image_array = np.asarray(image)
    
    # Normalize: converts 0-255 to -1 to 1 range
    normalized_image_array = (image_array.astype(np.float32) / 127.5) - 1
    
    # Prepare data for prediction
    data = np.ndarray(shape=(1, 224, 224, 3), dtype=np.float32)
    data[0] = normalized_image_array

    # 4. Run the Prediction
    prediction = model.predict(data)
    index = np.argmax(prediction)
    class_name = class_names[index]
    confidence_score = float(prediction[0][index])

    # 5. Return JSON result (Label [2:] removes the "0 " prefix from Teachable Machine)
    return {
        "issue_type": class_name[2:], 
        "confidence": f"{round(confidence_score * 100, 2)}%"
    }