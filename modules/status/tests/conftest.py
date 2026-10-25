"""Sets the environment plugin.py reads at import and puts it on sys.path."""

import os
import sys

os.environ.setdefault("SITE_URL", "https://gramps.example.org")
os.environ.setdefault("MIN_ROLE", "member")
os.environ.setdefault("GRAMPS_WEB_VERSION", "v26.1.0")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "plugin"))
