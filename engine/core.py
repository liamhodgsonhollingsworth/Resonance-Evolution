"""
The engine.

Two phases:
- precompute(): walks graph, builds caches for aggregators and dispatch
  tables. Stub for now (extension point); future aggregators land here.
- assemble(root_id, view): walks the graph from root under view, calling
  each node's emit() in turn, returning composed Channels.

Module isolation: every emit()/build() call is wrapped in try/except. A
broken node returns a placeholder; the rest of the scene renders. New
node-types can fail without crashing the engine.

Renderer dispatch: each node-type's manifest declares a renderer_id; the
default compositor (Z-buffer for color/depth, list-concat for text) lives
in this module. Future renderer-nodes (TextRenderer, AsciiDebug, etc.)
override compositing for their sub-graph by being node-types themselves
with custom emit() implementations.
"""

import importlib
import importlib.util
import json
import sys
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
import numpy as np

from engine.node import (
    Channels,
    EmitContext,
    Manifest,
    NodeInstance,
    View,
)


class Engine:
    def __init__(self, root_dir: Path, trust_set: Any = None):
        """Construct the engine.

        ``trust_set`` (optional) gates which node-type source files the
        engine will execute (SPEC-054 render-trust). When provided, only
        sources for which ``trust_set.is_trusted(source_id)`` returns
        True are imported; others are skipped, recorded in
        ``self.untrusted_encounters``, and any spawn referencing their
        type-name produces the same typed-zero placeholder as an
        unknown-type spawn.

        When ``trust_set`` is ``None`` (the default), all sources load.
        This preserves backward compatibility with tests and pre-trust
        callers; production startup wires a trust-set in.
        """
        self.root_dir = Path(root_dir)
        self.types: Dict[str, Any] = {}     # type_name -> module
        self.type_sources: Dict[str, str] = {}  # type_name -> source-id (relative posix path)
        self.nodes: Dict[str, NodeInstance] = {}
        self.cache: Dict[str, Any] = {}
        self.errors: List[str] = []
        self.trust_set = trust_set
        self.untrusted_encounters: List[str] = []  # source-ids encountered but not loaded

    # ----- registration / discovery -----

    def discover(self) -> None:
        """
        Walk node_types/ and renderers/ for .py files; import each; register
        by the module's manifest().name. New node-types and renderers added
        to these directories are picked up without engine changes.

        Failures during discovery are recorded but do not crash discovery —
        a broken module-file means only that one type isn't available.
        """
        for kind in ("node_types", "renderers"):
            kind_dir = self.root_dir / kind
            if not kind_dir.exists():
                continue
            for py_file in sorted(kind_dir.glob("*.py")):
                if py_file.name.startswith("_"):
                    continue
                self._load_node_type_file(py_file, kind)

    def _load_node_type_file(self, py_file: Path, kind: str) -> None:
        source_id = self._source_id_for(py_file)
        if self.trust_set is not None and not self.trust_set.is_trusted(source_id):
            if source_id not in self.untrusted_encounters:
                self.untrusted_encounters.append(source_id)
            self.errors.append(
                f"discover({py_file}): source not trusted ({source_id}); "
                f"add to state/trusted_sources.json to enable."
            )
            return
        try:
            mod_name = f"apeiron_{kind}_{py_file.stem}"
            spec = importlib.util.spec_from_file_location(mod_name, py_file)
            module = importlib.util.module_from_spec(spec)
            sys.modules[mod_name] = module
            spec.loader.exec_module(module)
            if not hasattr(module, "manifest"):
                return
            m = module.manifest()
            self.types[m.name] = module
            self.type_sources[m.name] = source_id
        except Exception as e:
            self.errors.append(
                f"discover({py_file}): {e}\n{traceback.format_exc()}"
            )

    def _source_id_for(self, py_file: Path) -> str:
        """Compute the canonical source-id for a node-type file.

        The id is the path relative to ``self.root_dir`` in forward-slash
        form. Used by the trust-set to gate which sources may execute.
        """
        try:
            rel = Path(py_file).resolve().relative_to(self.root_dir.resolve())
        except ValueError:
            # File is outside the root — return its absolute posix path
            # so trust-sets can be explicit about external locations.
            return Path(py_file).resolve().as_posix()
        return rel.as_posix()

    def reload_type(self, type_name: str) -> bool:
        """
        Hot-reload a node-type after its file was edited. Returns True if
        the type was found and reloaded successfully.

        Implementation note: importlib.reload does not work cleanly for
        modules originally loaded via importlib.util.spec_from_file_location
        (it raises "spec not found" because the spec object isn't kept on
        the module the way regular-import flows do). The reliable path is
        to delete the module from sys.modules and re-run the same loader
        the engine uses for initial discovery. That guarantees the new
        file content is read and re-executed.
        """
        importlib.invalidate_caches()
        for kind in ("node_types", "renderers"):
            for py_file in (self.root_dir / kind).glob("*.py"):
                try:
                    mod_name = f"apeiron_{kind}_{py_file.stem}"
                    if mod_name in sys.modules:
                        m_old = sys.modules[mod_name].manifest()
                        if m_old.name != type_name:
                            continue
                        del sys.modules[mod_name]
                        # Also evict any stale .pyc for this source file so
                        # the next load re-reads the source. SourceFileLoader
                        # otherwise prefers a fresh-looking cached bytecode
                        # whose mtime can differ from the source's by less
                        # than the filesystem's mtime resolution, producing
                        # silent "reload returned True but content unchanged"
                        # failures.
                        try:
                            cache_file = importlib.util.cache_from_source(str(py_file))
                            if Path(cache_file).exists():
                                Path(cache_file).unlink()
                        except Exception:
                            pass
                        self._load_node_type_file(py_file, kind)
                        new_module = sys.modules.get(mod_name)
                        if new_module is None or not hasattr(new_module, "manifest"):
                            return False
                        self.types[new_module.manifest().name] = new_module
                        return True
                except Exception as e:
                    self.errors.append(f"reload_type({type_name}): {e}")
                    return False
        return False

    # ----- scene management -----

    def load_scene(self, scene_path: Path) -> str:
        """
        Load a scene JSON file.

        Scene format:
        {
            "root": "<id>",
            "view": { ... optional initial viewer state ... },
            "nodes": [
                {"id": "<id>", "type": "<type>", "params": {...}, "connections": {...}},
                ...
            ]
        }
        Returns the root node id.
        """
        data = json.loads(Path(scene_path).read_text())
        for node_data in data["nodes"]:
            self.spawn(
                node_id=node_data["id"],
                type_name=node_data["type"],
                params=node_data.get("params", {}),
                connections=node_data.get("connections", {}),
            )
        return data["root"]

    def spawn(
        self,
        node_id: str,
        type_name: str,
        params: Optional[Dict[str, Any]] = None,
        connections: Optional[Dict[str, Any]] = None,
    ) -> str:
        """Create a node instance. Wraps build() in try/except."""
        params = params or {}
        connections = connections or {}
        instance = NodeInstance(
            id=node_id,
            type_name=type_name,
            params=params,
            connections=connections,
        )
        try:
            module = self.types[type_name]
        except KeyError:
            instance.dead = True
            instance.error = f"unknown type: {type_name}"
            self.nodes[node_id] = instance
            return node_id

        try:
            if hasattr(module, "build"):
                instance.state = module.build(params)
            else:
                instance.state = dict(params)
        except Exception as e:
            instance.dead = True
            instance.error = f"build failed: {e}\n{traceback.format_exc()}"
        self.nodes[node_id] = instance
        return node_id

    # ----- phases -----

    def precompute(self) -> None:
        """
        Walk every spawned node; for any node-type module exposing a
        precompute_hook(state, engine, node) function, call it and store
        the result at self.cache[node_id]. New node-types that want
        build-time work just expose precompute_hook — no engine change
        required. Wrapped in try/except so a broken hook doesn't block
        other nodes' precompute.
        """
        for node_id, node in self.nodes.items():
            if node.dead:
                continue
            module = self.types.get(node.type_name)
            if module is None or not hasattr(module, "precompute_hook"):
                continue
            try:
                self.cache[node_id] = module.precompute_hook(node.state, self, node)
            except Exception as e:
                self.errors.append(
                    f"precompute({node_id}): {e}\n{traceback.format_exc()}"
                )

    def sim_precompute(self) -> None:
        """
        Companion to precompute() for nodes that pre-simulate interactions
        before runtime. Walks every spawned node; for any module exposing
        sim_precompute_hook(state, engine, node), calls it and stores the
        result at self.cache[node_id + "__sim__"]. Separate cache key so a
        node may have both regular precompute output (aggregator impostor)
        and a simulation trajectory (SimulationProbe) cached side-by-side.

        New node-types pre-simulating interactions just expose
        sim_precompute_hook — same pattern as precompute_hook.
        """
        for node_id, node in self.nodes.items():
            if node.dead:
                continue
            module = self.types.get(node.type_name)
            if module is None or not hasattr(module, "sim_precompute_hook"):
                continue
            try:
                self.cache[node_id + "__sim__"] = module.sim_precompute_hook(
                    node.state, self, node
                )
            except Exception as e:
                self.errors.append(
                    f"sim_precompute({node_id}): {e}\n{traceback.format_exc()}"
                )

    def invert_edit(self, node_id: str, edit: Dict[str, Any]) -> bool:
        """
        Walk up from node_id to the nearest Generator ancestor; call its
        invert_hook with edit; apply returned param_delta to the connected
        Seed; re-trigger the Generator's precompute. Returns True if an
        ancestor handled the edit. Implementation in engine/inverse.py.

        Imported lazily to avoid a circular import (inverse uses Engine
        type at runtime; Engine references inverse only inside this
        method).
        """
        from engine.inverse import invert_edit as _invert
        return _invert(self, node_id, edit)

    def assemble(self, root_id: str, view: View) -> Channels:
        """
        Walk from root under view; call each node's emit(); composite the
        result. Module isolation via try/except — broken nodes render
        placeholders, the rest of the scene renders.
        """
        return self._emit_node(root_id, view)

    # ----- internals -----

    def _emit_node(self, node_id: str, view: View) -> Channels:
        node = self.nodes.get(node_id)
        if node is None:
            return self._empty_channels(view)
        if node.dead:
            return self._placeholder_channels(view, color=(1.0, 0.0, 1.0))

        module = self.types.get(node.type_name)

        # Ask the node which children to recurse into. Default: all of them.
        # A node-type implementing select_children() can skip subtrees that
        # would be thrown away at composite time — e.g., an Aggregator using
        # its precomputed impostor and not needing the target's full render.
        children_to_emit = list(node.connections.keys())
        if module is not None and hasattr(module, "select_children"):
            try:
                children_to_emit = list(module.select_children(node.state, view, self, node))
            except Exception as e:
                self.errors.append(f"select_children({node.id}): {e}")
                children_to_emit = list(node.connections.keys())

        # Recursively emit selected children
        child_outputs: Dict[str, Tuple[NodeInstance, Channels]] = {}
        for conn_name in children_to_emit:
            conn = node.connections.get(conn_name)
            if conn is None:
                continue
            target_id, transform = self._resolve_connection(conn)
            child_view = self._apply_transform(view, transform)
            sub_node = self.nodes.get(target_id)
            if sub_node is not None:
                child_outputs[conn_name] = (sub_node, self._emit_node(target_id, child_view))

        # Then emit this node
        try:
            if module is None:
                return self._placeholder_channels(view, color=(0.5, 0.5, 0.5))
            if not hasattr(module, "emit"):
                # Composition-only node (e.g. a Group with no own emit):
                # composite children directly.
                return self._composite_children(child_outputs, view)
            ctx = EmitContext(engine=self, node=node, child_outputs=child_outputs)
            return module.emit(node.state, view, ctx)
        except Exception as e:
            node.dead = True
            node.error = f"emit failed: {e}\n{traceback.format_exc()}"
            self.errors.append(f"emit({node.id}): {e}")
            return self._placeholder_channels(view, color=(1.0, 0.0, 1.0))

    def _resolve_connection(self, conn) -> Tuple[str, Optional[np.ndarray]]:
        """
        A connection is either a string (target_id, identity transform) or
        a dict with {"target": id, "transform": 4x4 list-of-lists}.
        """
        if isinstance(conn, str):
            return conn, None
        if isinstance(conn, dict):
            tf = conn.get("transform")
            if tf is not None:
                tf = np.asarray(tf, dtype=np.float64)
            return conn["target"], tf
        # list shape: ["target_id", optional_transform]
        if isinstance(conn, list):
            target_id = conn[0]
            tf = np.asarray(conn[1], dtype=np.float64) if len(conn) > 1 else None
            return target_id, tf
        raise ValueError(f"unrecognized connection shape: {conn!r}")

    def _apply_transform(self, view: View, transform: Optional[np.ndarray]) -> View:
        """
        Apply a 4x4 transform to a view's position+orientation. Used when
        traversing into a child node whose local frame differs from its
        parent's. Identity transform returns the view unchanged.
        """
        if transform is None:
            return view
        # Decompose transform into rotation (3x3 upper-left) and translation
        R = transform[:3, :3]
        t = transform[:3, 3]
        # Inverse-transform the viewer position into the child's frame:
        # new_pos = R^T @ (view.position - t)
        new_pos = R.T @ (view.position - t)
        new_orient = R.T @ view.orientation
        return View(
            position=new_pos,
            orientation=new_orient,
            scale=view.scale,
            width=view.width,
            height=view.height,
            fov_y_radians=view.fov_y_radians,
        )

    def _composite_children(
        self,
        child_outputs: Dict[str, Tuple[NodeInstance, Channels]],
        view: View,
    ) -> Channels:
        """
        Default compositor: Z-buffer for color/depth pairs, list-concat for
        text-shaped channels. Future renderer-nodes override this.
        """
        if not child_outputs:
            return self._empty_channels(view)

        # Start from an empty buffer
        result = self._empty_channels(view)
        for _, (_, ch) in child_outputs.items():
            result = self._composite_pair(result, ch)
        return result

    def _composite_pair(self, base: Channels, over: Channels) -> Channels:
        """Composite `over` onto `base` using a depth test on the depth channel.
        The Z-buffer mask also drives normal/ids — without that the pixel's
        normal can come from a node that's behind something else, breaking
        downstream shaders that read the normal channel."""
        out: Channels = {}
        mask = None
        if "color" in over and "depth" in over and "depth" in base:
            mask = over["depth"] < base["depth"]
            fallback_color = base.get("color")
            if fallback_color is None:
                fallback_color = np.zeros_like(over["color"])
            out["color"] = np.where(mask[..., None], over["color"], fallback_color)
            out["depth"] = np.where(mask, over["depth"], base["depth"])
        else:
            out["color"] = over.get("color", base.get("color"))
            out["depth"] = over.get("depth", base.get("depth"))

        # Z-buffer for normal/ids using the same mask. Without this the
        # "winning" channel for compositing diverges per channel — pixels
        # could read color from one node and normal from another.
        for name in ("normal", "ids"):
            over_chan = over.get(name)
            base_chan = base.get(name)
            if over_chan is not None and base_chan is not None and mask is not None \
                    and over_chan.shape == base_chan.shape:
                if over_chan.ndim == 3:
                    out[name] = np.where(mask[..., None], over_chan, base_chan)
                else:
                    out[name] = np.where(mask, over_chan, base_chan)
            elif over_chan is not None:
                out[name] = over_chan
            elif base_chan is not None:
                out[name] = base_chan

        # Concatenate text channels if present
        text_parts = []
        if isinstance(base.get("text"), str):
            text_parts.append(base["text"])
        if isinstance(over.get("text"), str):
            text_parts.append(over["text"])
        if text_parts:
            out["text"] = "\n".join(text_parts)

        return out

    def _empty_channels(self, view: View) -> Channels:
        return {
            "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
            "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
        }

    def _placeholder_channels(self, view: View, color=(1.0, 0.0, 1.0)) -> Channels:
        c = np.zeros((view.height, view.width, 3), dtype=np.float32)
        c[:] = np.array(color, dtype=np.float32)
        d = np.full((view.height, view.width), 0.5, dtype=np.float32)
        return {"color": c, "depth": d}
