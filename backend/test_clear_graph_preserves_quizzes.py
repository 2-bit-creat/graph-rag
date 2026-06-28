"""Ensure clearing the knowledge graph does not delete quiz rows."""

import inspect

from app import crud


def test_clear_graph_does_not_delete_quizzes():
    source = inspect.getsource(crud.clear_user_knowledge_graph)
    assert "delete(Quiz)" not in source
    assert "graph_staging = None" in source
    assert "unlink_speakers_from_graph" in source


def main():
    test_clear_graph_does_not_delete_quizzes()
    print("All clear-graph quiz preservation tests passed.")


if __name__ == "__main__":
    main()
