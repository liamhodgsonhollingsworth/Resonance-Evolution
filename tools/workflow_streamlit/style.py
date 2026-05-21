"""CSS for the Streamlit workflow surface.

Single-place styling so the dark theme is shared across all panels. Lifts
the palette from the historical idea-vault UI (Playfair Display heads +
IBM Plex Mono labels + soft amber accents on near-black) so the look is
familiar across the project's prior surfaces. Web-deploy mode loads the
same CSS; the theme is renderer-agnostic.
"""

from __future__ import annotations

CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;600;700&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@300;400;500&display=swap');

html, .stApp { background-color: #080b10 !important; color: #d4cfc7; font-family: 'IBM Plex Sans', sans-serif; }
h1, h2, h3 { font-family: 'Playfair Display', serif; color: #e8d5a3; letter-spacing: -0.02em; }

[data-testid="stSidebar"] { background: #0d1118 !important; border-right: 1px solid #1e2535; }
[data-testid="stSidebar"] * { color: #a0a8b8 !important; }
[data-testid="stSidebar"] h1, [data-testid="stSidebar"] h2, [data-testid="stSidebar"] h3 { color: #e8d5a3 !important; }

.stTextArea textarea, .stTextInput input, .stChatInput textarea {
    background: #0d1118 !important; color: #d4cfc7 !important;
    border: 1px solid #1e2535 !important; border-radius: 4px !important;
    font-family: 'IBM Plex Sans', sans-serif !important;
}

div[data-testid="stButton"] button {
    background: transparent !important; color: #e8d5a3 !important;
    border: 1px solid #e8d5a3 !important; border-radius: 3px !important;
    font-family: 'IBM Plex Mono', monospace !important;
    font-size: .78rem !important; letter-spacing: .06em !important;
    text-transform: uppercase !important; padding: 6px 14px !important;
    transition: all .15s !important;
}
div[data-testid="stButton"] button:hover { background: #e8d5a3 !important; color: #080b10 !important; }

.panel-card {
    background: #0d1118; border: 1px solid #1e2535; border-radius: 6px;
    padding: 12px 16px; margin-bottom: 10px;
}
.panel-card .title { font-family: 'Playfair Display', serif; font-size: 1rem; color: #e8d5a3; }
.panel-card .body { font-size: .85rem; color: #8a9ab0; margin-top: 4px; line-height: 1.5; }
.panel-card .meta { font-family: 'IBM Plex Mono', monospace; font-size: .68rem; color: #5a6478; letter-spacing: .06em; margin-top: 6px; }

.status-pill {
    border-radius: 20px; padding: 2px 10px; font-family: 'IBM Plex Mono', monospace;
    font-size: .66rem; letter-spacing: .06em; display: inline-block; margin-right: 4px;
}
.status-pill-ok { background: #061810; border: 1px solid #0d3320; color: #3a9a62; }
.status-pill-pending { background: #181408; border: 1px solid #2e2412; color: #a89a52; }
.status-pill-alert { background: #1a0808; border: 1px solid #2e1212; color: #c84a4a; }
.status-pill-in_progress { background: #08111a; border: 1px solid #122a44; color: #5a8aba; }
.status-pill-cancelled { background: #11111a; border: 1px solid #2a2a2e; color: #6a6a78; }

.chat-msg {
    background: #0d1118; border: 1px solid #1e2535; border-radius: 6px;
    padding: 10px 14px; margin-bottom: 8px; font-size: .88rem; line-height: 1.5;
}
.chat-msg.from-maintainer {
    background: #0a121a; border-left: 3px solid #6b8cba; margin-left: 40px;
}
.chat-msg.from-session {
    background: #110d18; border-left: 3px solid #8a6aaa; margin-right: 40px;
}
.chat-msg .from {
    font-family: 'IBM Plex Mono', monospace; font-size: .66rem;
    color: #5a6478; letter-spacing: .08em; text-transform: uppercase; margin-bottom: 4px;
}
.chat-msg .summary { font-family: 'Playfair Display', serif; color: #e8d5a3; font-size: .92rem; margin-bottom: 4px; }

.mode-banner {
    background: #08100e; border: 1px solid #0d2a1e; border-left: 3px solid #2a6a4a;
    border-radius: 4px; padding: 6px 12px; font-family: 'IBM Plex Mono', monospace;
    font-size: .68rem; color: #6a8a7a; margin-bottom: 8px;
}
.mode-banner.web { border-left-color: #6a4aaa; color: #8a6aaa; background: #0a0814; border-color: #2a1a4a; }

.empty-hint { font-family: 'IBM Plex Mono', monospace; font-size: .76rem; color: #5a6478; padding: 12px 0; }

.terminal-log {
    background: #05080c; border: 1px solid #1e2535; border-radius: 4px;
    padding: 10px; max-height: 360px; overflow-y: auto;
    font-family: 'IBM Plex Mono', monospace; font-size: .76rem; line-height: 1.45;
    margin-bottom: 8px;
}
.term-row { display: block; color: #8a9ab0; }
.term-when { color: #4a5a6e; margin-right: 8px; }
.term-src { font-size: .66rem; padding: 0 5px; border-radius: 2px; margin-right: 8px; letter-spacing: .04em; }
.term-src-gui { background: #0e1830; color: #6b8cba; border: 1px solid #1a2e4a; }
.term-src-terminal { background: #1a180a; color: #b89a3a; border: 1px solid #2e2a12; }
.term-src-cli { background: #0a1814; color: #4aa68c; border: 1px solid #16382c; }
.term-src-system { background: #181018; color: #8a6aaa; border: 1px solid #2e1a4a; }
.term-cmd { color: #d4cfc7; }
.term-output { margin-left: 16px; margin-bottom: 4px; }
.term-output pre { color: inherit; background: transparent; border: none; padding: 0; margin: 0; font-family: inherit; font-size: inherit; white-space: pre-wrap; }
.term-output.term-ok { color: #5a8a6a; }
.term-output.term-err { color: #c84a4a; }
.term-marker { font-weight: 600; margin-right: 4px; }
</style>
"""


def inject(streamlit_module) -> None:
    """Call from app.py after st.set_page_config to apply the theme."""
    streamlit_module.markdown(CSS, unsafe_allow_html=True)
