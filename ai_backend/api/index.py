import sys
import os

# Add parent directory to sys.path so main.py modules can be imported
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from main import app
