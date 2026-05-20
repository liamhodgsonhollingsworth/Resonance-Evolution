"""2D Tk GUI workflow shell — SPEC-065.

The maintainer-facing workflow surface as a native productivity-app
layout: sidebar of tabs on the left, scrollable list in the central
pane, chat input at the bottom. Selecting the 3D tab embeds the
realtime renderer in the central pane; selecting any 2D tab tears
down the 3D loop so no compute runs on it.

Companion to ``tools.workflow`` (the terminal REPL). The two shells
share the engine, SessionManager, Inbox, and trust primitives — only
the rendering layer differs (Tk widgets vs stdin/stdout).
"""
