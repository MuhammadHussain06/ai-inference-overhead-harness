import sys
from pathlib import Path

import pytest

# Import the service package without installing it.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import responses  # noqa: E402
from app.model import FraudMLTier  # noqa: E402
from app.schemas import TransactionPayload  # noqa: E402

from stubs import StubModel  # noqa: E402


@pytest.fixture(autouse=True)
def reset_serialization_estimate():
    """Clears the module-global EWMA so estimate state never leaks between tests."""
    responses._serialization_estimate_ms = None
    yield
    responses._serialization_estimate_ms = None


@pytest.fixture
def tier():
    loaded = FraudMLTier(5)
    loaded.model = StubModel()
    loaded.n_jobs_verified = True
    return loaded


@pytest.fixture
def payload():
    return TransactionPayload(
        transactionId="11111111-2222-3333-4444-555555555555",
        amount=100.0,
        features=[0.5] * 28,
    )