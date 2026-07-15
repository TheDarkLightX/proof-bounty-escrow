#!/usr/bin/env python3
"""Offline semantic validation for the repository's JSON Schema profile.

The repository deliberately uses a closed subset of JSON Schema Draft 2020-12.
This module validates every schema against that profile, resolves local JSON
Pointers, compiles every regular expression, and validates each checked-in
instance. Unknown schema keywords fail closed, so extending the profile requires
an explicit review here. No package download or network access is required.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


DRAFT_2020_12 = "https://json-schema.org/draft/2020-12/schema"
JSON_TYPES = {"null", "boolean", "object", "array", "number", "integer", "string"}
SCHEMA_KEYWORDS = {
    "$defs",
    "$id",
    "$ref",
    "$schema",
    "additionalProperties",
    "allOf",
    "const",
    "description",
    "else",
    "enum",
    "format",
    "if",
    "items",
    "maxItems",
    "maxLength",
    "maximum",
    "minItems",
    "minLength",
    "minimum",
    "oneOf",
    "pattern",
    "properties",
    "required",
    "then",
    "title",
    "type",
    "uniqueItems",
}
SUPPORTED_FORMATS = {"date-time", "uri"}
INSTANCE_BINDINGS = (("deployments/networks.json", "deployments/networks.schema.json"),)


class SchemaError(ValueError):
    """A schema is outside the reviewed profile or internally inconsistent."""


class InstanceError(ValueError):
    """A JSON instance does not satisfy its bound schema."""


def _json_key(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, SchemaError) as error:
        raise SchemaError(f"{path}: {error}") from error


def _schema_path(path: str, token: str | int) -> str:
    return f"{path}/{token}"


def _expect(condition: bool, path: str, message: str) -> None:
    if not condition:
        raise SchemaError(f"{path}: {message}")


def _resolve_local_ref(root: Any, reference: str, path: str) -> Any:
    _expect(reference.startswith("#/"), path, "only local '#/...' references are supported")
    target = root
    for encoded_token in reference[2:].split("/"):
        token = unquote(encoded_token).replace("~1", "/").replace("~0", "~")
        _expect(isinstance(target, dict) and token in target, path, f"unresolved reference {reference!r}")
        target = target[token]
    return target


def validate_schema(schema: Any, *, root: Any | None = None, path: str = "$") -> None:
    """Validate one schema node against the repository's closed schema profile."""

    if root is None:
        root = schema
    if isinstance(schema, bool):
        return
    _expect(isinstance(schema, dict), path, "schema must be an object or boolean")

    unknown = sorted(set(schema) - SCHEMA_KEYWORDS)
    _expect(not unknown, path, f"unsupported schema keyword(s): {', '.join(unknown)}")

    if "$schema" in schema:
        _expect(schema["$schema"] == DRAFT_2020_12, path, "unsupported $schema dialect")
    if "$id" in schema:
        identifier = schema["$id"]
        _expect(isinstance(identifier, str), path, "$id must be a string")
        parsed = urlparse(identifier)
        _expect(bool(parsed.scheme) and " " not in identifier, path, "$id must be an absolute URI")
    if "$ref" in schema:
        _expect(isinstance(schema["$ref"], str), path, "$ref must be a string")
        _resolve_local_ref(root, schema["$ref"], _schema_path(path, "$ref"))
    if "type" in schema:
        declared = schema["type"]
        if isinstance(declared, str):
            declared_types = [declared]
        else:
            _expect(isinstance(declared, list) and bool(declared), path, "type must be a string or non-empty array")
            declared_types = declared
        _expect(
            all(isinstance(item, str) and item in JSON_TYPES for item in declared_types),
            path,
            "type contains an unsupported JSON type",
        )
        _expect(len(set(declared_types)) == len(declared_types), path, "type entries must be unique")
    if "enum" in schema:
        values = schema["enum"]
        _expect(isinstance(values, list) and bool(values), path, "enum must be a non-empty array")
        keys = [_json_key(value) for value in values]
        _expect(len(keys) == len(set(keys)), path, "enum values must be unique")
    if "format" in schema:
        _expect(schema["format"] in SUPPORTED_FORMATS, path, "format is not supported by the offline validator")
    if "pattern" in schema:
        pattern = schema["pattern"]
        _expect(isinstance(pattern, str), path, "pattern must be a string")
        try:
            re.compile(pattern)
        except re.error as error:
            raise SchemaError(f"{path}/pattern: invalid regular expression: {error}") from error

    for keyword in ("minLength", "maxLength", "minItems", "maxItems"):
        if keyword in schema:
            value = schema[keyword]
            _expect(isinstance(value, int) and not isinstance(value, bool) and value >= 0, path, f"{keyword} must be a non-negative integer")
    for keyword in ("minimum", "maximum"):
        if keyword in schema:
            value = schema[keyword]
            _expect(
                isinstance(value, (int, float)) and not isinstance(value, bool),
                path,
                f"{keyword} must be numeric",
            )
    for lower, upper in (
        ("minLength", "maxLength"),
        ("minItems", "maxItems"),
        ("minimum", "maximum"),
    ):
        if lower in schema and upper in schema:
            _expect(schema[lower] <= schema[upper], path, f"{lower} must not exceed {upper}")
    if "uniqueItems" in schema:
        _expect(isinstance(schema["uniqueItems"], bool), path, "uniqueItems must be boolean")
    if "required" in schema:
        required = schema["required"]
        _expect(isinstance(required, list), path, "required must be an array")
        _expect(all(isinstance(item, str) for item in required), path, "required entries must be strings")
        _expect(len(required) == len(set(required)), path, "required entries must be unique")

    for keyword in ("properties", "$defs"):
        if keyword in schema:
            mapping = schema[keyword]
            _expect(isinstance(mapping, dict), path, f"{keyword} must be an object")
            for name, child in mapping.items():
                validate_schema(child, root=root, path=_schema_path(_schema_path(path, keyword), name))
    for keyword in ("items", "additionalProperties", "if", "then", "else"):
        if keyword in schema:
            validate_schema(schema[keyword], root=root, path=_schema_path(path, keyword))
    for keyword in ("allOf", "oneOf"):
        if keyword in schema:
            children = schema[keyword]
            _expect(isinstance(children, list) and bool(children), path, f"{keyword} must be a non-empty array")
            for index, child in enumerate(children):
                validate_schema(child, root=root, path=_schema_path(_schema_path(path, keyword), index))


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    raise AssertionError(f"unreviewed type: {expected}")


def _instance_failure(path: str, message: str) -> None:
    raise InstanceError(f"{path}: {message}")


def _validate_format(value: str, format_name: str, path: str) -> None:
    if format_name == "uri":
        parsed = urlparse(value)
        if not parsed.scheme or " " in value:
            _instance_failure(path, "must be an absolute URI")
        if parsed.scheme in {"http", "https"} and not parsed.netloc:
            _instance_failure(path, "HTTP(S) URI must have an authority")
        return
    if format_name == "date-time":
        try:
            parsed_time = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise InstanceError(f"{path}: must be an RFC 3339 date-time") from error
        if "T" not in value or parsed_time.tzinfo is None:
            _instance_failure(path, "must be a timezone-qualified RFC 3339 date-time")
        return
    raise AssertionError(f"unreviewed format: {format_name}")


def validate_instance(instance: Any, schema: Any, *, root: Any | None = None, path: str = "$") -> None:
    """Validate an instance against a schema already accepted by ``validate_schema``."""

    if root is None:
        root = schema
    if schema is True:
        return
    if schema is False:
        _instance_failure(path, "rejected by false schema")
    assert isinstance(schema, dict)

    if "$ref" in schema:
        validate_instance(instance, _resolve_local_ref(root, schema["$ref"], path), root=root, path=path)

    if "type" in schema:
        declared = schema["type"]
        expected = [declared] if isinstance(declared, str) else declared
        if not any(_matches_type(instance, item) for item in expected):
            _instance_failure(path, f"expected type {' or '.join(expected)}")
    if "const" in schema and _json_key(instance) != _json_key(schema["const"]):
        _instance_failure(path, "does not equal const value")
    if "enum" in schema and _json_key(instance) not in {_json_key(value) for value in schema["enum"]}:
        _instance_failure(path, "is not one of the enumerated values")

    if isinstance(instance, dict):
        for required in schema.get("required", []):
            if required not in instance:
                _instance_failure(path, f"missing required property {required!r}")
        properties = schema.get("properties", {})
        for name, value in instance.items():
            child_path = _schema_path(path, name)
            if name in properties:
                validate_instance(value, properties[name], root=root, path=child_path)
            elif schema.get("additionalProperties", True) is False:
                _instance_failure(child_path, "additional property is not allowed")
            elif isinstance(schema.get("additionalProperties"), dict):
                validate_instance(value, schema["additionalProperties"], root=root, path=child_path)

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            _instance_failure(path, f"must contain at least {schema['minItems']} items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            _instance_failure(path, f"must contain at most {schema['maxItems']} items")
        if schema.get("uniqueItems", False):
            keys = [_json_key(value) for value in instance]
            if len(keys) != len(set(keys)):
                _instance_failure(path, "items must be unique")
        if "items" in schema:
            for index, value in enumerate(instance):
                validate_instance(value, schema["items"], root=root, path=_schema_path(path, index))

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            _instance_failure(path, f"must contain at least {schema['minLength']} characters")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            _instance_failure(path, f"must contain at most {schema['maxLength']} characters")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            _instance_failure(path, f"does not match pattern {schema['pattern']!r}")
        if "format" in schema:
            _validate_format(instance, schema["format"], path)

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            _instance_failure(path, f"must be at least {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            _instance_failure(path, f"must be at most {schema['maximum']}")

    for child in schema.get("allOf", []):
        validate_instance(instance, child, root=root, path=path)
    if "oneOf" in schema:
        matches = 0
        for child in schema["oneOf"]:
            try:
                validate_instance(instance, child, root=root, path=path)
            except InstanceError:
                continue
            matches += 1
        if matches != 1:
            _instance_failure(path, f"must match exactly one oneOf branch; matched {matches}")
    if "if" in schema:
        try:
            validate_instance(instance, schema["if"], root=root, path=path)
        except InstanceError:
            branch = schema.get("else")
        else:
            branch = schema.get("then")
        if branch is not None:
            validate_instance(instance, branch, root=root, path=path)


def validate_repository(root: Path) -> tuple[int, int]:
    schema_paths = sorted(
        (*root.glob("deployments/*.schema.json"), *root.glob("schemas/*.schema.json"))
    )
    if not schema_paths:
        raise SchemaError("no JSON Schema files found")
    identifiers: dict[str, Path] = {}
    for path in schema_paths:
        schema = load_json(path)
        if not isinstance(schema, dict) or schema.get("$schema") != DRAFT_2020_12:
            raise SchemaError(f"{path}: root $schema must declare Draft 2020-12")
        validate_schema(schema)
        identifier = schema.get("$id")
        if identifier is not None:
            if identifier in identifiers:
                raise SchemaError(f"{path}: duplicate $id also used by {identifiers[identifier]}")
            identifiers[identifier] = path

    for instance_name, schema_name in INSTANCE_BINDINGS:
        instance_path = root / instance_name
        schema_path = root / schema_name
        schema = load_json(schema_path)
        validate_instance(load_json(instance_path), schema)
    return len(schema_paths), len(INSTANCE_BINDINGS)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to this script's parent repository)",
    )
    args = parser.parse_args(argv)
    try:
        schemas, instances = validate_repository(args.root.resolve())
    except (SchemaError, InstanceError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"JSON Schemas valid: {schemas} schema(s), {instances} bound instance(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
