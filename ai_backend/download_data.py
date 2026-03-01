import kagglehub
import os
import shutil
from pathlib import Path

# 1. Define where you want to save the images safely
BASE_DIR = Path(__file__).resolve().parent
TARGET_FOLDER = BASE_DIR / "ai_data"

print("Downloading dataset from Kaggle...")

# 2. Download the dataset (Kaggle stores this in a temporary hidden cache)
cache_path = kagglehub.dataset_download("andrewmvd/pothole-detection")
print(f"Downloaded to temporary cache: {cache_path}")

# 3. Automatically copy the files from the cache into your project folder
print(f"Copying files to your project folder: {TARGET_FOLDER}...")

# Create the 'ai_data' folder if it doesn't already exist
TARGET_FOLDER.mkdir(parents=True, exist_ok=True)

# Copy everything from Kaggle's cache folder directly into your 'ai_data' folder
shutil.copytree(cache_path, TARGET_FOLDER, dirs_exist_ok=True)

print(f"Success! All images and data are now fully set up inside your '{TARGET_FOLDER.name}' folder.")