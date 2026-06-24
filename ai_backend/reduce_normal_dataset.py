import os
import shutil
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
NORMAL_DIR = BASE_DIR / "ai_data" / "Normal"
BACKUP_DIR = BASE_DIR / "ai_data_normal_backup"

def main():
    if not NORMAL_DIR.exists():
        print(f"Error: {NORMAL_DIR} does not exist.")
        return

    # Create backup directory if it doesn't exist
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    # Get sorted list of files in Normal folder
    files = sorted([f for f in NORMAL_DIR.iterdir() if f.is_file()])
    total_files = len(files)
    print(f"Total files in {NORMAL_DIR.name}: {total_files}")

    target_count = 400
    if total_files <= target_count:
        print(f"Dataset already has {total_files} files, which is <= {target_count}. No action needed.")
        return

    files_to_move = files[target_count:]
    print(f"Moving {len(files_to_move)} files to {BACKUP_DIR}...")

    for f in files_to_move:
        shutil.move(str(f), str(BACKUP_DIR / f.name))

    # Verify new counts
    new_files = [f for f in NORMAL_DIR.iterdir() if f.is_file()]
    backup_files = [f for f in BACKUP_DIR.iterdir() if f.is_file()]
    print(f"Success! {NORMAL_DIR.name} now has {len(new_files)} files.")
    print(f"Backup folder {BACKUP_DIR.name} now has {len(backup_files)} files.")

if __name__ == "__main__":
    main()
