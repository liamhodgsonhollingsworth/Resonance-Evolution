"""
Apeiron node-type modules. Each .py file is one node-type, picked up by
the engine's discovery walk. To add a new node-type: write a new file
exposing manifest(), build(params), emit(state, view, ctx), and
optionally describe(state, ctx).
"""
