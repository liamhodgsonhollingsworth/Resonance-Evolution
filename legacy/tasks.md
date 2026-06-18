# Tasks

The maintainer's task list. Read by `TaskPanel` (a `ListRenderer` + `FileSource`
pair in [scenes/workflow_view.json](scenes/workflow_view.json)) and rendered as
a vertical checklist with status glyphs.

Status syntax:

- `[ ]` open / pending
- `[x]` done
- `[~]` in progress
- `[-]` cancelled

Sub-bullets indented under a task attach as continuation text in the item's
`body` (visible when the task is expanded — wish #006).

## Active

- [ ] Try the workflow_view scene end-to-end and report any rendering issues
- [~] Decide whether the panel font size should be larger by default
- [ ] Audit which Tier C panels would benefit most from being mounted next
- [ ] Plan the wish #006 click-to-expand interaction shape

## Done

- [x] Bootstrap the Apeiron engine and core node-types
- [x] Build the dream-features skeleton + N-D pipeline
- [x] Grant Tier A wish cluster (#001-#005 + #009) via the wish-granting session
