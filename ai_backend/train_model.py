import tensorflow as tf
from tensorflow.keras.applications import MobileNetV2
from tensorflow.keras.layers import Dense, GlobalAveragePooling2D, Dropout, RandomFlip, RandomRotation, RandomZoom
from tensorflow.keras.models import Model
from tensorflow.keras import Sequential
from pathlib import Path

# 1. Setup Paths safely using pathlib
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "ai_data"
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"

def train():
    print("Loading images from your folders...")
    
    # 2. Load the image dataset from your sorted folders
    train_dataset = tf.keras.utils.image_dataset_from_directory(
        DATA_DIR,
        image_size=(224, 224),
        batch_size=32,
        label_mode='categorical'
    )

    class_names = train_dataset.class_names
    num_classes = len(class_names)
    print(f"Found classes: {class_names}")

    if num_classes < 2:
        print("Error: You need at least two subfolders inside 'ai_data' to train.")
        return

    # 3. Create the Data Augmentation Pipeline (NEW)
    # This prevents the AI from memorizing exact photos by slightly tweaking them
    data_augmentation = Sequential([
        RandomFlip("horizontal"),
        RandomRotation(0.1), # Rotate up to 10%
        RandomZoom(0.1),     # Zoom in/out up to 10%
    ])

    # 4. Build the Smarter AI Model
    print("Building the AI Model...")
    base_model = MobileNetV2(weights='imagenet', include_top=False, input_shape=(224, 224, 3))
    base_model.trainable = False  # Freeze the base

    # Link everything together
    inputs = tf.keras.Input(shape=(224, 224, 3))
    x = data_augmentation(inputs) # Apply augmentation first
    x = base_model(x, training=False) 
    x = GlobalAveragePooling2D()(x)
    x = Dense(128, activation='relu')(x)
    
    # Dropout Layer (NEW): Drops 20% of connections to force the AI to look at the big picture
    x = Dropout(0.2)(x) 
    
    predictions = Dense(num_classes, activation='softmax')(x) # Output layer

    model = Model(inputs=inputs, outputs=predictions)

    # 5. Compile and Train
    print("Starting Training (This will take a bit longer for maximum accuracy)...")
    model.compile(optimizer='adam', loss='categorical_crossentropy', metrics=['accuracy'])
    
    # Increased epochs (NEW): Changed from 5 to 20 so it studies 4x longer!
    model.fit(train_dataset, epochs=20) 

    # 6. Save files perfectly for FastAPI
    print("Training complete! Saving files...")
    model.save(MODEL_PATH)

    with open(LABELS_PATH, "w") as f:
        for i, name in enumerate(class_names):
            f.write(f"{i} {name}\n")
            
    print(f"Success! '{MODEL_PATH.name}' and '{LABELS_PATH.name}' have been generated.")
    print("Remember to RESTART your Uvicorn server to load this new brain!")

if __name__ == "__main__":
    train()