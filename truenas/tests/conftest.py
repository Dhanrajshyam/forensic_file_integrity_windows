import os
import sys
from unittest.mock import MagicMock

# Inject a no-op fcntl before chain.py is imported so tests run on Windows.
# The real locking logic is irrelevant for unit tests — we test the algorithm.
if "fcntl" not in sys.modules:
    _mock_fcntl = MagicMock()
    _mock_fcntl.LOCK_EX = 2
    _mock_fcntl.LOCK_NB = 4
    _mock_fcntl.LOCK_UN = 8
    _mock_fcntl.flock.return_value = None
    sys.modules["fcntl"] = _mock_fcntl

# Add truenas/src to path so tests can import chain, signer, etc.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
