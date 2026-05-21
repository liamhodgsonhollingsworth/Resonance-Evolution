"""Environment-driven configuration for the Streamlit workflow surface.

The same Python module loads identically in local-launch mode (auto-login
as the maintainer, no auth gate) and in web-deploy mode (full scrypt
login required, sessions per-user). The switch is one env var so the
locally-developed surface and the future website surface stay byte-
identical at the source level.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


# Default maintainer username — matches the account already provisioned in
# ``state/accounts.json``. The local-launch path skips the login form and
# treats this user as authenticated; the web-deploy path ignores it.
DEFAULT_LOCAL_USER = "LHH"

# Env var that, when set to a truthy value, flips the surface into
# "require real authentication" mode. The website deployment sets this;
# local launches don't.
REQUIRE_LOGIN_ENV = "APEIRON_REQUIRE_LOGIN"

# Optional env var to override the local auto-login username (useful for
# testing the gate locally without setting the global require-login).
LOCAL_USER_ENV = "APEIRON_LOCAL_USER"


@dataclass
class RuntimeConfig:
    """Resolved per-process configuration. Cheap to construct."""

    apeiron_root: Path
    require_login: bool
    local_user: str
    accounts_path: Path
    state_dir: Path
    default_scene: str

    @property
    def deployment_mode(self) -> str:
        """Human-readable label for the status bar."""
        return "web" if self.require_login else "local"


def _truthy(value: str | None) -> bool:
    if value is None:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


def load_config(apeiron_root: Path | None = None) -> RuntimeConfig:
    """Resolve runtime config from env + the Apeiron repo root."""
    if apeiron_root is None:
        apeiron_root = Path(__file__).resolve().parents[2]
    apeiron_root = Path(apeiron_root)
    return RuntimeConfig(
        apeiron_root=apeiron_root,
        require_login=_truthy(os.environ.get(REQUIRE_LOGIN_ENV)),
        local_user=os.environ.get(LOCAL_USER_ENV, DEFAULT_LOCAL_USER),
        accounts_path=apeiron_root / "state" / "accounts.json",
        state_dir=apeiron_root / "state" / "workflow",
        default_scene=os.environ.get("APEIRON_DEFAULT_SCENE", "workflow_view.json"),
    )
