# Communication as a first-class module (the architecture law)

Status 2026-06-24. Companion to `CONNECTION-CONTRACT.md` (the multi-writer *coordination* layer) and
`README.md` (the design law). This document is the **runtime communication** layer: it makes the
maintainer's central architectural directive concrete and checks the foundation against it.

> **The directive (Liam, verbatim intent).** *"All functionality should live in the connections
> between modules and the modules themselves — never in primitives or the foundation. Different
> modules have different communication protocols, which are modules themselves that act as
> intermediaries. Scenes, contexts, menus, simulations, and procedural generation all act as methods
> of communication between modules, so the same nodes can behave differently depending on what is
> going on. Rather than making efficient modules that cover as much functionality as possible, we
> separate functionalities into different modules and make the most efficient connection between
> them."*

The point of this file: **communication itself is a module.** The foundation knows only how to hold
modules, bind their ports, and run one privileged propagation primitive. *How* two modules talk — the
protocol, the medium, the context — is supplied by **other modules**, never baked into the
foundation. This is not speculative: it is the 20-year-stable shape of Flow-Based Programming, Apache
NiFi, ROS 2 QoS, Houdini network contexts, Apache Camel / Enterprise Integration Patterns, and
algebraic effect handlers (citations at the foot).

---

## 1. The two things the foundation may contain (and nothing else)

1. **Modules** — a node / primitive / Chip. A module names only **its own typed ports** and is
   otherwise opaque. It carries no knowledge of who it talks to or how. (Already true today:
   `Primitive` exposes `input_ports`/`output_ports` + `evaluate`; a `Chip` is a sub-arrangement
   wrapped as one module.)
2. **The privileged propagation substrate** — `GraphRuntime`, the one fixed layer that instantiates
   modules, binds ports, and moves values. Its base operation (read an output, hand it to an input)
   is the **terminating base case** of the whole system. It is *not* itself a module and is *not*
   pluggable. Everything else is a module.

Everything that is **not** one of those two is a module: behaviors, renderers, effects, **and the
communication between modules**.

---

## 2. The communication modules — four kinds, one spectrum

Communication is modeled as a single spectrum, from "do nothing" to "mediate a whole external
protocol," with the cheap default costing nothing.

### 2.1 The wire (degenerate identity communication) — the default
A plain wire is `{from, out, to, in}` — it copies one output value to one input, unchanged. This is
the **category-theoretic identity morphism** `1_A`: a real, first-class connection that happens to do
nothing. It stays **schema-strict and dumb** (per `CONNECTION-CONTRACT.md` §1 — *edge intent lives on
nodes/ports, never on the wire shape*). 99% of connections are this, and they cost nothing. The
runtime's pull-dataflow `evaluate()` is exactly the identity-wire propagator.

### 2.2 The Channel (edge-level communication module)
When a connection must do more than copy a value — **buffer, order, rate-decouple, gate, route, or
translate one data format to another** — you do not fatten the wire. You **route the connection
through a Channel module**: `A.out → channel.in`, `channel.out → B.in`. The Channel is an ordinary
node, so it is openable, rewireable, nestable, and shareable like any module (the homoiconic law),
and the wires on either side of it stay dumb (the contract holds).

The **one hard rule that keeps the foundation un-bloated** (the FBP discipline): a Channel may
*buffer / bound / order / route / format-translate / negotiate* — it may **never carry arbitrary
domain computation**. Domain logic is a *node's* job. An edge that grows a real domain function should
have been a node. (NiFi's connection is the existence proof of how much an edge can legitimately
carry: capacity + backpressure + prioritizer + expiration + distribution — all *policy*, no
*business logic*.)

> Note: in pure synchronous dataflow a Channel-as-midpoint and a transform-node are
> indistinguishable — which is *correct*: the edge-level Channel only earns its keep once a
> non-synchronous **Context** (below) exists to give buffering/backpressure/ordering meaning.

### 2.3 The Context (region-level communication module) — the load-bearing idea
A **Context** scopes a sub-arrangement (like a Chip) **and supplies the *handler* that interprets how
the modules inside it communicate.** This is the realization of *"scenes, contexts, menus,
simulations, procedural generation are methods of communication,"* and of *"the same nodes behave
differently depending on what is going on."*

The same two modules, wired identically, **communicate differently depending on the Context that
scopes them** — with **zero change to the modules**. This is precisely:
- **Houdini network contexts** — one node UI, but a wire carries *geometry* in a SOP network,
  *channels over time* in a CHOP network, a *solver relationship* in a DOP network, and a
  *per-element program* in a VOP network. Context decides what the wire means.
- **Algebraic effect handlers** — the same operations get different interpretations from the active
  handler; "clear separation of syntax and semantics." A Context **is** the handler.
- **Dreams microchips as a "powered scope"** — one wire into a chip's power port gates whether every
  gadget inside it acts.

A Context with the **default `dataflow` handler is exactly a Chip** (synchronous pull). A Context with
a different handler changes the propagation discipline of its whole scope. The handler roadmap:

| handler | how the scope's modules communicate | status |
|---|---|---|
| `dataflow` (default) | synchronous pull, topo-ordered — today's `evaluate()` | **shipped** |
| `gate` | the scope only propagates while an `enabled` input is truthy (Dreams powered-scope; a scene/menu being active vs dormant) | **shipped** |
| `modulate` | the Context injects per-node param overrides, so the **same modules compute different values** under different Contexts ("different properties depending on what's going on") | **shipped** |
| `abstract` | treat the scope as a **primitive**: run its dataflow ONCE, content-address the result, and shortcut to the cache forever after — "a primitive is a node you chose not to open" (§2.5) | **shipped** |
| `event` | push, not pull: a module fires; only its downstream re-propagates (menus, input, triggers) | planned |
| `tick` / `sim` | continuous time-stepped propagation (simulations, physics, walking around) | planned |
| `proximity` | the **spatial gate**: the scope propagates only while its two implicit `pos_a`/`pos_b` vector inputs are within a static `radius` (per-pair 3D interaction: "use X on Y"); otherwise dormant, like a disabled `gate`. First handler to realize "the observer/spatial state is just an INPUT a handler reads" — position is dynamic (an input port), range is static (a param); the observer-driven `abstract`/LOD handler will read camera distance the same way | **shipped** |
| `connector` | the scope's far endpoint is an **external** system (§2.4) | planned |

New handlers are **new modules / new data**, never foundation edits — that is the whole point.

### 2.4 The Connector (communication with the outside world) — the universal integrator
A **Connector** is a Channel/Context whose far endpoint is an *external* system — another game, a web
API, a GitHub repo, a simulation, or *another instance of this engine with different connections*.
This is the path to the stated end goal: a **universal integrator** that wraps what already exists
instead of re-implementing it ("wrap, don't rebuild").

The integration interface is a deliberately **narrow waist** (the hourglass law that made IP, Unix
pipes, HTTP, 9P, and Zapier universal — O(M+N) integration, never O(M×N)):

- **One canonical envelope:** `{identity, routing, typed-payload, interaction-pattern}`. The
  `interaction-pattern` (one-way / request-reply / pub-sub / stream — Camel's *Message Exchange
  Pattern*) makes the *style* of communication **data the engine can route on and swap**, not
  something buried in an endpoint.
- **A tiny universal verb set:** `connect / send / receive / close / describe`. Every capability,
  including ones not yet imagined, expresses itself through these (the 9P/Unix "everything is a
  file" move).
- **Connectors are URI-scheme-addressed adapters** (`scheme://address?params`, Camel's model):
  adding "anything" = registering one scheme / writing one adapter.
- **Connections negotiate and fail loudly** (ROS 2 Request-vs-Offered QoS): a connection forms only
  on a checked contract; a refusal is a surfaced diagnostic, **never a silent no-op** (silent
  QoS-mismatch is the #1 ROS debugging trap — we avoid it by construction).
- **A first-class raw escape hatch** (a Shell / HTTP / Python node) is both the principled answer to
  the inevitable leaky abstraction *and* the cheapest integration path.

The existing `bridge/scene_bridge.py` (HTTP push + screenshot) and `bridge/graph_store.py`
(conflict-safe shared-file writes) are the **first two Connectors** in this scheme, before the scheme
was named. The remote/Cowork plug-point in `CONNECTION-CONTRACT.md` §5 is a third.

---

### 2.5 Abstraction & precompute — "a primitive is a node you chose not to open"
The maintainer's three further directives — (1) *no fundamental primitives: different things are a
primitive in different contexts*; (2) *scale-independent simulation: a system of interacting nodes,
used at a larger scale, has its emergent behavior **abstracted** into one coherent primitive with
defined properties rather than simulated live* (cell → plant → garden); (3) *precompute/memoize:
the first time any behavior runs it is computed, and every repeat **shortcuts** to the stored
result* — are **one principle at three zoom levels**, and they fall out of the Context handler with
no foundation change:

> A node is an **opaque primitive** inside a context that treats it as atomic, and an **open,
> re-simulatable arrangement** outside that context. Which one you get is a per-evaluation Context
> decision (the `abstract` handler), and the opaque result is keyed by the **content-address** of
> everything that affects it, so the decision is computed once and shortcut forever after.

- **#1 context-relative primitives** = the handler decides whether to *descend into*
  `params.arrangement` or *return a stored summary*. "Primitive" is the answer to "did this context
  open me?", not a node attribute. (This is the live, grounded form of the `vibrant-elion`
  *no-fundamental-primitives* proposal; the full `type → definition` resolver is its sequenced
  generalization, deferred.)
- **#2 scale-independent abstraction** = the stored result IS a **behavior summary** (the legacy
  Apeiron `Aggregator`/`SimulationProbe` `BehaviorSummary`), so a plant built from interacting cells
  is consumed at garden scale as one primitive with defined properties — recursively. This
  **re-realizes SPEC-300 / SPEC-301**, which were *implemented in the legacy Python engine but
  regressed to PLANNED in the Godot engine*.
- **#3 precompute/memoize** = the cache behind the handler. This is partial evaluation / the
  Futamura projections (specialize once, run the residual many times) and Build-Systems-à-la-Carte
  (an arrangement is a task description; the content-address is the store key).

**Soundness floor (MVP, shipped):** memoization is sound only for a **pure** scope, so a scope
collapses only when **every** inner node opts in via `Primitive.is_cacheable()` (default false; only
`Const`/`Math` opt in for now). Any impure node (`Log`) or renderer-bound / time-varying node
(`Model`, future `tick`/`sim`) makes the scope **degrade to a plain Chip** — it runs live every
time, so abstraction never silently freezes a side effect. The key is **hermetic** (effective
arrangement + handler + canonical inputs), the cache is **process-wide** (two Contexts over the same
pure scope share one result), and it is **non-destructive** (the summary sits beside the retained
`params.arrangement`; re-expansion = clear the cache). **Deferred** (the gated decisions): the
observer/distance trigger (camera-driven LOD abstraction, SPEC-300), unifying scene-graph with
behavior-graph decomposition, stateful-snapshot collapse, on-disk persistence + eviction, and lossy
replacement. Abstraction is *designed to relieve* the `MAX_DEPTH` recursion bound — a collapsed scope
returns its summary without descending, turning a deep emergence cascade into a flat sequence of cache
hits — but note that in the MVP a scope containing a nested wrapper (Chip/Context) is non-cacheable
(the purity gate is non-recursive), so this relief lands only once recursive/nested abstraction does.

## 3. Terminating the regress (the worry this design must answer)

*If a connection is a module, and modules communicate via connections, what connects the connection?*
Every mature system answers this the same way, and so do we: **a communication module is declarative
and runtime-operated — it is never an active node that needs its own inbound connection.** When a
Channel or Context moves a value between its endpoints, it uses the **same one privileged substrate
primitive** every leaf node uses (the runtime reading an output and handing it to an input). That
primitive is **not** itself modeled as a connection-module, so the recursion bottoms out in exactly
one place.

This is identical to how FBP bottoms out at the *scheduler* (the bounded buffer is a passive FIFO the
scheduler animates), Go at the `hchan` struct + goroutine scheduler, ROS at DDS→IP, and Plan 9 at the
kernel mount driver. **Reify communication freely *above* this floor; the floor is fixed and
special.** Concretely: `GraphRuntime.evaluate()` (and the future tick/event drivers) is the floor.

---

## 4. How this checks against the current foundation (the audit)

**Already matching the law:**
- Functionality is data-arrangements over primitives, never new code. ✓
- Primitives carry zero domain identity; nothing in `Primitive`/`GraphRuntime` is feature-specific. ✓
- Typed ports + widening compat = "anything connects to anything compatible." ✓
- Chips = portable, recursively-nestable modules. ✓
- Renderers are dumb delegates over `scene_node` DATA (Phase 2.5). ✓

**The gap this document closes:** the runtime baked in **one** communication discipline (synchronous
pull-dataflow) as the *only* way modules can talk. That is itself a kind of functionality living in
the foundation — a violation of the law. The fix is **not** to add disciplines to the foundation; it
is to make the discipline a **handler supplied by a Context module**, with the default handler
reproducing today's behavior exactly. After this change the foundation is *thinner* (it delegates
"how to propagate" to a module) while gaining *more* expressive power (any number of disciplines, all
as modules).

**What is implemented now:** the `Context` module (`primitives/prim_context.gd`) with four handlers —
`dataflow` (≡ Chip, the backward-compatible default), `gate` (powered-scope), `modulate` (per-node
param override), and `abstract` (content-addressed memoize/collapse — §2.5). This is the minimal
faithful proof that *communication is a module* AND that *abstraction/precompute is a module*: the
same inner arrangement demonstrably behaves differently under different Contexts, and a pure scope is
computed once then shortcut — both with no change to the inner modules and **no change to
`GraphRuntime`** (the propagation floor). `is_cacheable()` is the only addition to the `Primitive`
base contract; the handler computes its own content-address inline (inner arrangement + ports +
canonical inputs) — folding it into the schema's still-inert `id` field is a deferred unification. The
`event` / `tick` / `proximity` / `connector` handlers, the edge-level `Channel` module with
capacity/backpressure, and the deferred abstraction extensions (§2.5) are the sequenced follow-ons —
each a new module, not a foundation edit.

---

## 5. The laws (carry these)
Communication is a module · the wire is the identity (degenerate) case and stays dumb · a Channel may
mediate transport but never compute domain logic · a Context supplies the handler that interprets how
its scope communicates (scenes/sims/menus/procgen are Context handlers) · the same modules behave
differently per Context with zero module changes · a Connector is a Channel/Context with an external
endpoint, integrated through a narrow waist (envelope + `connect/send/receive/close/describe` +
URI-addressed adapters + negotiated/loud-failing connections + a raw escape hatch) · the regress
terminates at the one privileged runtime substrate · new disciplines are new modules, never
foundation edits.

---

### Prior art (the thesis is validated, not speculative)
Flow-Based Programming (bounded-buffer connections, ports, IIPs) · Apache NiFi (connection = policy
queue: backpressure/prioritizer/expiration) · CSP/Go (channel as a passable first-class value;
capacity = sync↔async) · Akka/Erlang (location transparency, supervision context) · ROS 2 (topics +
QoS Request-vs-Offered negotiation; rosbridge as the non-ROS waist) · Unreal Blueprints (exec vs data
pins) · Blender fields / Houdini SOP·CHOP·DOP·VOP contexts (context decides what a wire carries) ·
Max/Pd (message vs signal cords) · Dreams microchips (powered scope) · Enterprise Integration Patterns
+ Apache Camel (Message Channel/Translator/Router/Channel-Adapter; URI-scheme connectors; MEP) ·
Plan 9 / 9P + the hourglass/narrow-waist law · algebraic effect handlers + the identity morphism (the
formal grounding for context-as-handler and edge-as-identity-or-channel).
