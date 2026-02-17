import kagglehub
import os

# 1. Define where you want to save the images
target_folder = "./ai_data"

# 2. Download the dataset
# Note: This will use your kaggle.json key automatically
path = kagglehub.dataset_download("andrewmvd/pothole-detection")

print(f"Dataset downloaded to: {path}")
print("You can now copy the images from there into your 'ai_data' folder.")