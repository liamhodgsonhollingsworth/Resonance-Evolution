# Pending — Apeiron

Maintainer-side items deferred until they become relevant. Each entry names the trigger condition (when it becomes a problem) and the exact step-by-step actions the maintainer takes when triggered. Future sessions surface the relevant entry when its trigger fires; the maintainer follows the steps.

## Pending

### #001 — Flip github repo visibility to public

**Filed:** 2026-05-16 by the bootstrap session.
**Trigger:** When an external collaborator or reader needs to view the repo, OR when a session invokes the meta-layer's public-by-default convention against this repo, OR when the maintainer asks a session to make the Apeiron repo public.

**Why deferred:** Auto-mode required explicit authorization to create the repo public; the maintainer chose to defer the flip until it becomes relevant rather than authorize it preemptively. The current private state preserves all work; only external visibility is affected.

**When triggered, the session should instruct the maintainer with these exact steps:**

1. Open a browser to: `https://github.com/liamhodgsonhollingsworth/Apeiron/settings`
2. Scroll to the very bottom of the page to find the "Danger Zone" section.
3. In the "Change repository visibility" row, click the **Change visibility** button.
4. Select **Change to public** in the dialog that appears.
5. Read the warnings. Type the repository name exactly — `liamhodgsonhollingsworth/Apeiron` — into the confirmation field.
6. Click **I understand, change repository visibility** to confirm.

After the flip, the repo matches the public-by-default meta-convention and the meta-atlas link resolves for external readers. The session reports back to the maintainer: "Apeiron is now public; meta-atlas link is live."

---

### #002 — Set up CODEOWNERS branch protection on main

**Filed:** 2026-05-16 by the bootstrap session.
**Trigger:** When an unauthorized session or subagent pushes a destructive change to main without going through PR review, OR when sessions begin operating in parallel often enough that gentleman's-agreement coordination is insufficient, OR when the maintainer asks for enforcement of the CODEOWNERS convention.

**Why deferred:** The CODEOWNERS file is in place and the convention is documented in CLAUDE.md; until parallel sessions actually conflict on Atlas-linked paths, the documented convention plus the per-session branch discipline are sufficient enforcement. Branch protection requires github settings configuration that only the maintainer can do.

**When triggered, the session should instruct the maintainer with these exact steps:**

1. Open a browser to: `https://github.com/liamhodgsonhollingsworth/Apeiron/settings/branches`
2. Click **Add branch protection rule** (or **Add classic branch protection rule** if both options appear — classic is sufficient for this use case).
3. In the "Branch name pattern" field, type exactly: `main`
4. Check the box for **Require a pull request before merging**.
5. Once that box is checked, additional sub-options appear. Check **Require review from Code Owners**.
6. Leave "Require approvals" at its default unless you want a specific minimum number (1 is conservative; 0 is fine if you trust your own merges).
7. Optionally check **Require status checks to pass before merging** — leave unchecked for now, since CI is not yet configured.
8. Scroll down past any other options (they can stay at defaults).
9. Click **Create** at the bottom of the page.

After this, any push to main that touches a CODEOWNERS-mapped path (README.md, whats_built.md, architecture.md, CLAUDE.md, CODEOWNERS, LICENSE) requires a pull request with maintainer approval. The session reports back to the maintainer: "Branch protection is active on main; CODEOWNERS gating is enforced."

---

### #003 — Install Python locally for running tests and the engine

**Filed:** 2026-05-16 by the bootstrap session.
**Trigger:** When the maintainer (or a session on the maintainer's machine) wants to run `python -m tools.render scenes/hello_cube.json`, `pytest tests/`, or any engine code locally. Currently Python isn't installed at any standard location on the machine, so the bootstrap session committed the code without running the tests against the actual interpreter.

**Why deferred:** The code is reviewable as written; running it requires installing Python plus numpy and Pillow. The maintainer may want to use a specific Python distribution (system, venv, conda, uv-managed). Choosing one now without input would bake in a tool decision.

**When triggered, the session should instruct the maintainer with these exact steps:**

1. Decide which Python to install. The simplest options:
   - **From python.org** (most portable): download the latest Python 3.12 installer from `https://www.python.org/downloads/windows/`, run it, and check "Add Python to PATH" before clicking Install.
   - **Via winget** (Windows package manager, terminal-based): in PowerShell or Command Prompt, run: `winget install Python.Python.3.12`
   - **Via uv** (modern Python tooling that manages versions per project): in PowerShell, run: `irm https://astral.sh/uv/install.ps1 | iex`, then in this repo: `uv sync` (uv reads pyproject.toml and creates a venv automatically).

2. Verify the install. Open a fresh terminal, run: `python --version` — should print `Python 3.12.x` (or similar).

3. Install the project dependencies. In the Apeiron repo root, run:
   - With pip: `python -m pip install -e ".[test]"` (installs numpy, Pillow, pytest, and Apeiron itself as an editable package).
   - With uv: `uv pip install -e ".[test]"` (same effect, but inside uv's managed venv).

4. Run the tests. From the Apeiron repo root: `pytest tests/` — should report 15 passed.

5. Run a scene end-to-end: `python -m tools.render scenes/hello_cube.json` — should write a bundle to `output/` and print "wrote bundle: output".

6. Confirm the text-renderer: `python -m tools.text_test describe scenes/hello_cube.json` — should print a structured text description of the scene.

After this, the session can run tests and the engine locally to verify any future implementation work before pushing.

## Resolved

(None yet.)
