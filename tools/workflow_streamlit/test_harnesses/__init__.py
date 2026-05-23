"""Test harnesses for the workflow-streamlit surface.

Per brief 02 commit 2 (Tools T1-T5). Each harness drives a substrate-
or-Streamlit surface programmatically and asserts a contract — used by
the LLM-driver scenarios in the per-module plan to verify behaviour
without spinning up a full Streamlit page.

Bootstrap roster (brief 02 commit 2):
  - scroll_window — Tool T1; drives the continuous-scroll renderer with
    a synthetic workflow_view and verifies the rendered band against
    `select_window()`.
"""
