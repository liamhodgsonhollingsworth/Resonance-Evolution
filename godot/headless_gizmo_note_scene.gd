extends Node
## Minimal fake scene root for the GizmoNote headless test: it exposes a SCENE_ID const so the
## autoload's _scene_id() detection (which prefers a scene-declared SCENE_ID) can be verified.
const SCENE_ID := "fake_test_scene"
