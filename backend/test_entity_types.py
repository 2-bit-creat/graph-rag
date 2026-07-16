from app.entity_types import normalize_entity_type, type_group_key
from app.ontology_presets import ensure_identity_hierarchy


def test_normalize_entity_type():
    assert normalize_entity_type("PERSON") == "Person"
    assert normalize_entity_type("person") == "Person"
    assert normalize_entity_type("TOPIC") == "Topic"
    assert normalize_entity_type("job_title") == "JobTitle"
    assert type_group_key("Person") == type_group_key("PERSON")
    print("OK entity type normalization")


def test_ensure_identity_hierarchy_migrates_legacy_speaker():
    """A pre-Identity/Person/Source ontology row (just Speaker/Statement/Concept)
    must show up as the current 5-type model — not as Speaker AND a separately
    appended Person, which would read as the same role listed twice."""
    stale = [
        {"name": "Speaker", "color": "#ff8c42", "description": "화자 · 인물"},
        {"name": "Statement", "color": "#6366f1", "description": "화자의 발화"},
        {"name": "Concept", "color": "#5b9dff", "description": "도메인 개념"},
    ]
    result = ensure_identity_hierarchy(stale)
    names = [et["name"] for et in result]
    assert names.count("Speaker") == 0
    assert names.count("Person") == 1
    assert set(names) == {"Person", "Statement", "Concept", "Identity", "Source"}


def test_ensure_identity_hierarchy_is_stable_on_current_model():
    """Already-migrated ontologies pass through untouched — no duplication."""
    current = [
        {"name": "Identity", "color": "#f07b5b", "description": ""},
        {"name": "Person", "color": "#ff8c42", "description": "", "parent": "Identity"},
        {"name": "Source", "color": "#ffc53d", "description": "", "parent": "Identity"},
        {"name": "Statement", "color": "#b07bff", "description": ""},
        {"name": "Concept", "color": "#5b9dff", "description": ""},
    ]
    result = ensure_identity_hierarchy(current)
    assert len(result) == 5
    names = [et["name"] for et in result]
    assert names == ["Identity", "Person", "Source", "Statement", "Concept"]


if __name__ == "__main__":
    test_normalize_entity_type()
    test_ensure_identity_hierarchy_migrates_legacy_speaker()
    test_ensure_identity_hierarchy_is_stable_on_current_model()
