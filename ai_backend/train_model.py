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
    print("Loading images...")
    
    # 2. Load the image dataset with a validation split
    train_dataset = tf.keras.utils.image_dataset_from_directory(
        DATA_DIR,
        validation_split=0.2,
        subset="training",
        seed=123,
        image_size=(224, 224),
        batch_size=32,
        label_mode='categorical'
    )

    val_dataset = tf.keras.utils.image_dataset_from_directory(
        DATA_DIR,
        validation_split=0.2,
        subset="validation",
        seed=123,
        image_size=(224, 224),
        batch_size=32,
        label_mode='categorical'
    )

    class_names = train_dataset.class_names
    num_classes = len(class_names)

    # 3. Create the Augmentation layers for training only
    data_augmentation = Sequential([
        RandomFlip("horizontal"),
        RandomRotation(0.1),
        RandomZoom(0.1),
    ])

    # 4. Prepare datasets (scale image values to range [-1, 1])
    def prepare_train(img, label):
        img = data_augmentation(img, training=True)
        img = (img / 127.5) - 1
        return img, label

    def prepare_val(img, label):
        img = (img / 127.5) - 1
        return img, label

    train_dataset = train_dataset.map(prepare_train)
    val_dataset = val_dataset.map(prepare_val)

    # 5. Build the AI Model with Sigmoid output for multi-label classification
    print("Building the upgraded AI Model...")
    base_model = MobileNetV2(weights='imagenet', include_top=False, input_shape=(224, 224, 3))
    base_model.trainable = False

    inputs = tf.keras.Input(shape=(224, 224, 3))
    x = base_model(inputs, training=False) 
    x = GlobalAveragePooling2D()(x)
    x = Dense(128, activation='relu')(x)
    x = Dropout(0.2)(x) 
    predictions = Dense(num_classes, activation='sigmoid')(x)

    model = Model(inputs=inputs, outputs=predictions)

    # 6. Train
    # Phase 1: Warm-up classifier head
    print("Starting Phase 1: Warm-up Classifier Head (10 Epochs)...")
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
        loss='binary_crossentropy',
        metrics=['accuracy']
    )
    model.fit(train_dataset, validation_data=val_dataset, epochs=10) 

    # Phase 2: Fine-tune top layers of the backbone
    print("Starting Phase 2: Fine-tuning top layers (15 Epochs)...")
    base_model.trainable = True
    # Freeze lower layers, unfreeze only top 30 layers
    for layer in base_model.layers[:-30]:
        layer.trainable = False

    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-5),
        loss='binary_crossentropy',
        metrics=['accuracy']
    )
    model.fit(train_dataset, validation_data=val_dataset, epochs=15)

    # 7. Save
    print("Saving Upgraded Model...")
    model.save(MODEL_PATH)

    with open(LABELS_PATH, "w") as f:
        for i, name in enumerate(class_names):
            f.write(f"{i} {name}\n")
    print("Done! Restart your Uvicorn server now.")

if __name__ == "__main__":
    train()