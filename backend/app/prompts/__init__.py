"""Language packs assembled into prompts sent to the LLM.

Two independent packs per call:
- ``native``  — the learner's own language: chat persona, context labels,
  summary/distill copy. Selected by ``User.native_language``.
- ``target``  — the language being learned: teaching focus + quality rubric
  for quiz generation. Selected by the quiz's target language.

See :mod:`backend.app.languages` for the language registry these key off of.
"""

from __future__ import annotations

from .native import NATIVE_PACKS, NativePack, native_pack

__all__ = ["NATIVE_PACKS", "NativePack", "native_pack"]
