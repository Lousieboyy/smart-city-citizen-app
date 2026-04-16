import tensorflow as tf
from tensorflow.keras.applications import MobileNetV2
from tensorflow.keras.layers import Dense, GlobalAveragePooling2D, Dropout
from tensorflow.keras.models import Model
from tensorflow.keras import Sequential
from tensorflow.keras.layers import RandomFlip, RandomRotation, RandomZoom
from pathlib import Path

# 1. Setup Paths
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "ai_data"
MODEL_PATH = BASE_DIR / "keras_Model.h5"
LABELS_PATH = BASE_DIR / "labels.txt"

def train():
    print("🚀 Loading images...")
    
    # 2. Load the image dataset
    train_dataset = tf.keras.utils.image_dataset_from_directory(
        DATA_DIR,
        image_size=(224, 224),
        batch_size=32,
        label_mode='categorical'
    )

    class_names = train_dataset.class_names
    num_classes = len(class_names)

    # --- THE CLEAN FIX STARTS HERE ---
    
    # 3. Create the "Study Tools" (Augmentation)
    data_augmentation = Sequential([
        RandomFlip("horizontal"),
        RandomRotation(0.1),
        RandomZoom(0.1),
    ])

    # 4. Apply Augmentation and Math to the DATA, not the Brain
    # We do (img / 127.5) - 1 to make the numbers small (-1 to 1)
    # This stops the TrueDivide error in FastAPI!
    def prepare(img, label):
        img = data_augmentation(img, training=True) # Flip/Rotate the data
        img = (img / 127.5) - 1 # Dim the lights so the AI can see textures
        return img, label

    train_dataset = train_dataset.map(prepare)
    # --- THE CLEAN FIX ENDS HERE ---

    # 5. Build the "Clean" AI Model
    print("🧠 Building the Clean AI Model...")
    base_model = MobileNetV2(weights='imagenet', include_top=False, input_shape=(224, 224, 3))
    base_model.trainable = False

    inputs = tf.keras.Input(shape=(224, 224, 3))
    # Notice: No 'data_augmentation' inside the layers now!
    x = base_model(inputs, training=False) 
    x = GlobalAveragePooling2D()(x)
    x = Dense(128, activation='relu')(x)
    x = Dropout(0.2)(x) 
    predictions = Dense(num_classes, activation='softmax')(x)

    model = Model(inputs=inputs, outputs=predictions)

    # 6. Train
    print("Starting Training (20 Epochs)...")
    model.compile(optimizer='adam', loss='categorical_crossentropy', metrics=['accuracy'])
    model.fit(train_dataset, epochs=20) 

    # 7. Save
    print("Saving Clean Model...")
    model.save(MODEL_PATH)

    with open(LABELS_PATH, "w") as f:
        for i, name in enumerate(class_names):
            f.write(f"{i} {name}\n")
    print("✨ Done! Restart your Uvicorn server now.")

if __name__ == "__main__":
    train()