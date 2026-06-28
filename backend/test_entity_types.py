from app.entity_types import normalize_entity_type, type_group_key


def test_normalize_entity_type():
    assert normalize_entity_type("PERSON") == "Person"
    assert normalize_entity_type("person") == "Person"
    assert normalize_entity_type("TOPIC") == "Topic"
    assert normalize_entity_type("job_title") == "JobTitle"
    assert type_group_key("Person") == type_group_key("PERSON")
    print("OK entity type normalization")


if __name__ == "__main__":
    test_normalize_entity_type()
