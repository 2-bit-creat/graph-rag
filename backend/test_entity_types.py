from app.entity_types import (
    canonical_identity_type,
    identity_merge_group,
    identity_types_compatible,
    is_identity_type,
    normalize_entity_type,
    resolve_is_source,
    type_group_key,
)
from app.ontology_presets import ensure_identity_hierarchy


def test_normalize_entity_type():
    assert normalize_entity_type("PERSON") == "Person"
    assert normalize_entity_type("person") == "Person"
    assert normalize_entity_type("TOPIC") == "Topic"
    assert normalize_entity_type("job_title") == "JobTitle"
    assert type_group_key("Person") == type_group_key("PERSON")


def test_legacy_person_spellings_are_identities():
    """Person was retired as a type, but rows and payloads still say it."""
    for legacy in ("Person", "person", "Speaker", "화자", "Human", "Individual"):
        assert is_identity_type(legacy)
        assert canonical_identity_type(legacy) == "Identity"
    # Source was retired as a type too — canonical_identity_type collapses it
    # onto "Identity"; resolve_is_source carries the distinction as a flag.
    assert canonical_identity_type("Source") == "Identity"
    assert canonical_identity_type("media") == "Identity"
    assert resolve_is_source("Source") is True
    assert resolve_is_source("media") is True
    assert resolve_is_source("Person") is False
    assert resolve_is_source(None, default=True) is True
    # Non-identities are not swept in.
    assert not is_identity_type("Concept")
    assert not is_identity_type("Statement")


def test_identity_and_source_are_separate_merge_groups():
    assert identity_merge_group(False) == "identity"
    assert identity_merge_group(True) == "source"
    assert identity_types_compatible(False, False)
    assert not identity_types_compatible(False, True)


def test_ensure_identity_hierarchy_migrates_legacy_speaker():
    """A pre-Identity ontology row (just Speaker/Statement/Concept) must show up
    as the current 4-type model — not as Speaker AND a separately appended
    Identity, which would read as the same role listed twice."""
    stale = [
        {"name": "Speaker", "color": "#ff8c42", "description": "화자 · 인물"},
        {"name": "Statement", "color": "#6366f1", "description": "화자의 발화"},
        {"name": "Concept", "color": "#5b9dff", "description": "도메인 개념"},
    ]
    result = ensure_identity_hierarchy(stale)
    names = [et["name"] for et in result]
    assert names.count("Speaker") == 0
    assert names.count("Person") == 0
    assert names.count("Identity") == 1
    assert set(names) == {"Identity", "Statement", "Concept", "Source"}


def test_ensure_identity_hierarchy_collapses_speaker_and_person():
    """An ontology carrying BOTH legacy spellings collapses to one Identity —
    the old implementation appended both and showed a duplicate role."""
    both = [
        {"name": "Speaker", "color": "#ff8c42", "description": ""},
        {"name": "Person", "color": "#ff8c42", "description": ""},
        {"name": "Statement", "color": "#b07bff", "description": ""},
        {"name": "Concept", "color": "#5b9dff", "description": ""},
    ]
    names = [et["name"] for et in ensure_identity_hierarchy(both)]
    assert names.count("Identity") == 1
    assert "Person" not in names and "Speaker" not in names


def test_ensure_identity_hierarchy_is_stable_on_current_model():
    """Already-migrated ontologies pass through untouched — no duplication."""
    current = [
        {"name": "Identity", "color": "#f07b5b", "description": ""},
        {"name": "Source", "color": "#ffc53d", "description": "", "parent": "Identity"},
        {"name": "Statement", "color": "#b07bff", "description": ""},
        {"name": "Concept", "color": "#5b9dff", "description": ""},
    ]
    result = ensure_identity_hierarchy(current)
    assert len(result) == 4
    names = [et["name"] for et in result]
    assert names == ["Identity", "Source", "Statement", "Concept"]
