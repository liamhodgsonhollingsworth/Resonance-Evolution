"""Auth gate — short-circuits the page when login is required and absent.

Two modes, switched by ``ctx.config.require_login``:

- **Local mode** (default): no UI; ``ctx.user`` is filled in from
  ``cfg.local_user`` by the driver before this panel runs, so this
  panel is essentially a no-op and just renders a small "local mode"
  banner so the maintainer can see at a glance which mode is active.

- **Web mode** (``APEIRON_REQUIRE_LOGIN=1``): renders the login form,
  validates credentials against ``tools.workflow.auth``, persists the
  authenticated username in ``st.session_state['user']``, and reruns
  the page once the user logs in. Until then the panel writes
  ``ctx.scratch['gate'] = 'block'`` which tells the driver to skip the
  main + sidebar + bottom panels for this rerun.
"""

from __future__ import annotations

import streamlit as st

from engine import actions as engine_actions
from tools.workflow_streamlit.panels._common import MOUNT_GATE, PanelContext, PanelManifest


def manifest() -> PanelManifest:
    return PanelManifest(
        name="auth",
        description="Login gate — local auto-login or scrypt-backed sign-in.",
        mount_point=MOUNT_GATE,
        order=0,
        requires_auth=False,
    )


def render(ctx: PanelContext) -> None:
    cfg = ctx.config
    if not cfg.require_login:
        # Local mode: trust the configured user and surface a small banner.
        ctx.user = cfg.local_user
        st.session_state["user"] = cfg.local_user
        st.markdown(
            f'<div class="mode-banner">local mode · auto-signed-in as {cfg.local_user}</div>',
            unsafe_allow_html=True,
        )
        return

    # Web mode: enforce real authentication.
    user_in_session = st.session_state.get("user")
    if user_in_session:
        ctx.user = user_in_session
        st.markdown(
            f'<div class="mode-banner web">web mode · signed in as {user_in_session}</div>',
            unsafe_allow_html=True,
        )
        return

    # Render the login form and short-circuit the rest of the page.
    ctx.scratch["gate"] = "block"
    _render_login_form(ctx)


def _render_login_form(ctx: PanelContext) -> None:
    st.markdown("# Apeiron")
    st.markdown("Sign in to continue.")
    with st.form("login-form"):
        username = st.text_input("Username", key="login_username")
        password = st.text_input("Password", type="password", key="login_password")
        submitted = st.form_submit_button("Sign in")
    if not submitted:
        st.stop()
    # Dispatch through auth_gate_main; the node owns the actual
    # password verification + accounts-store I/O. Surface owns
    # session-state and rerun decisions.
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="auth_gate_main", action_name="authenticate",
        payload={"username": username, "password": password},
    )
    view = engine_actions.get_view_state(ctx.engine, "auth_gate_main")
    res = view.get("last_authenticate", {})
    if res.get("ok"):
        st.session_state["user"] = res["username"]
        st.rerun()
    else:
        st.error(res.get("reason") or "Incorrect username or password.")
        st.stop()
