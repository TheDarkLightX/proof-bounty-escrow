from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
REPOSITORY = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from validate_json_schemas import (  # noqa: E402
    InstanceError,
    SchemaError,
    load_json,
    validate_instance,
    validate_repository,
    validate_schema,
)


class JsonSchemaValidationTests(unittest.TestCase):
    def test_repository_schemas_and_bound_instances_are_valid(self) -> None:
        schemas, instances = validate_repository(REPOSITORY)
        self.assertGreaterEqual(schemas, 7)
        self.assertEqual(instances, 1)

    def test_rejects_unknown_keyword_fail_closed(self) -> None:
        with self.assertRaisesRegex(SchemaError, "unsupported schema keyword"):
            validate_schema({"type": "string", "minByteLength": 1})

    def test_rejects_unresolved_reference(self) -> None:
        with self.assertRaisesRegex(SchemaError, "unresolved reference"):
            validate_schema({"$ref": "#/$defs/missing", "$defs": {}})

    def test_rejects_invalid_regular_expression(self) -> None:
        with self.assertRaisesRegex(SchemaError, "invalid regular expression"):
            validate_schema({"type": "string", "pattern": "["})

    def test_rejects_non_numeric_bounds_cleanly(self) -> None:
        with self.assertRaisesRegex(SchemaError, "minimum must be numeric"):
            validate_schema({"minimum": "zero", "maximum": 10})

    def test_rejects_duplicate_json_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"same": 1, "same": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(SchemaError, "duplicate JSON object key"):
                load_json(path)

    def test_network_schema_rejects_additional_property(self) -> None:
        schema = load_json(REPOSITORY / "deployments" / "networks.schema.json")
        instance = load_json(REPOSITORY / "deployments" / "networks.json")
        changed = json.loads(json.dumps(instance))
        changed["unreviewed"] = True
        with self.assertRaisesRegex(InstanceError, "additional property"):
            validate_instance(changed, schema)

    def test_conditional_then_is_enforced(self) -> None:
        schema = {
            "type": "object",
            "if": {"properties": {"status": {"const": "active"}}},
            "then": {"required": ["approval"]},
        }
        validate_schema(schema)
        with self.assertRaisesRegex(InstanceError, "approval"):
            validate_instance({"status": "active"}, schema)
        validate_instance({"status": "draft"}, schema)

    def test_one_of_requires_exactly_one_branch(self) -> None:
        schema = {"oneOf": [{"type": "integer"}, {"minimum": 0}]}
        validate_schema(schema)
        with self.assertRaisesRegex(InstanceError, "matched 2"):
            validate_instance(1, schema)


if __name__ == "__main__":
    unittest.main()
