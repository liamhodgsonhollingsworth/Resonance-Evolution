# Pending — Apeiron

Items deferred until triggered. The default handling policy is that a session does the work itself via `gh` or other tooling per the GitHub-fully-handled-by-sessions policy in the maintainer's memory; entries here describe the session action plus any fallback UI steps for the maintainer if a session capability is blocked.

## Pending

### #002 — CODEOWNERS branch protection on main

**Filed:** 2026-05-16. Deferred per the maintainer's "defer until it becomes a problem" directive.
**Trigger:** An unauthorized session or subagent pushes a destructive change to main without going through PR review, OR parallel sessions begin conflicting often enough that gentleman's-agreement coordination is insufficient.

**Session action when triggered:**

Run the following from any working copy of the Apeiron repo:

    gh api -X PUT /repos/liamhodgsonhollingsworth/Apeiron/branches/main/protection \
      --input - <<'EOF'
    {
      "required_status_checks": null,
      "enforce_admins": false,
      "required_pull_request_reviews": {
        "required_approving_review_count": 0,
        "require_code_owner_reviews": true
      },
      "restrictions": null
    }
    EOF

This requires CODEOWNER approval on PRs touching CODEOWNERS-mapped paths (README.md, whats_built.md, architecture.md, CLAUDE.md, CODEOWNERS, LICENSE) while leaving non-CODEOWNERS paths freely mergeable by any session.

**Fallback (if `gh api` is blocked or the call fails):** Surface to the maintainer with these exact UI steps:

1. Open `https://github.com/liamhodgsonhollingsworth/Apeiron/settings/branches` in a browser.
2. Click **Add branch protection rule** (or **Add classic branch protection rule**).
3. In the "Branch name pattern" field, type: `main`
4. Check **Require a pull request before merging**.
5. Check **Require review from Code Owners**.
6. Leave "Require approvals" at 0 (no approvals required for non-CODEOWNERS paths).
7. Click **Create** at the bottom.

---

### #003 — Install Python locally for running tests and the engine

**Filed:** 2026-05-16. Maintainer-only — `gh` cannot install Python on the maintainer's machine.
**Trigger:** When a session on the maintainer's machine wants to run `pytest tests/`, `python -m tools.render scenes/hello_cube.json`, or any engine code locally to verify implementation work against the actual interpreter rather than by code review alone.

**Maintainer steps when triggered:** The session walks the maintainer through one of these install paths, asking which they prefer:

1. **python.org installer (simplest):** Download Python 3.12 from `https://www.python.org/downloads/windows/`, run the installer, and check "Add Python to PATH" before clicking Install. Then open a fresh terminal and run `python --version` to confirm.
2. **winget (terminal-based):** In PowerShell, run `winget install Python.Python.3.12`. Verify with `python --version` in a fresh terminal.
3. **uv (modern, per-project managed):** In PowerShell, run `irm https://astral.sh/uv/install.ps1 | iex`. Then in the Apeiron repo, the session can run `uv sync` to read pyproject.toml and create a venv automatically.

After Python is available, the session runs `python -m pip install -e ".[test]"` (or `uv pip install -e ".[test]"`) from the Apeiron repo root to install numpy, Pillow, pytest, and Apeiron itself as an editable package. Then `pytest tests/` and `python -m tools.render scenes/hello_cube.json` should both succeed.

## Resolved

### #001 — Flip github repo visibility to public (resolved 2026-05-16)

Apeiron's github repo was created private under auto-mode classifier restriction. Resolved by the same session that opened this entry, the moment the maintainer surfaced the GitHub-fully-handled-by-sessions policy: ran `gh repo edit liamhodgsonhollingsworth/Apeiron --visibility public --accept-visibility-change-consequences`. Verified via `gh repo view ... --json visibility,isPrivate`: now PUBLIC, isPrivate false. The meta-atlas link resolves for external readers.
