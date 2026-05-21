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

import shlex

import streamlit as st

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
    # Route the submit through the command registry so the same code
    # path serves the GUI form, the bottom terminal's typed `auth.login`,
    # and any future CLI-bridge invocation. The 2026-05-21 GUI/CLI 1:1
    # audit identified this as the missing CLI-reachable interaction.
    registry = ctx.scratch.get("command_registry")
    if registry is None:
        st.error("command registry missing; cannot sign in")
        st.stop()
    line = f"auth.login {shlex.quote(username)} {shlex.quote(password)}"
    result = registry.run_gui(line, ctx.as_command_context())
    if result.ok:
        # The command returns the authenticated username in data.
        signed_in_as = (result.data or {}).get("username") or username
        st.session_state["user"] = signed_in_as
        st.rerun()
    else:
        st.error(result.message or "Incorrect username or password.")
        st.stop()
