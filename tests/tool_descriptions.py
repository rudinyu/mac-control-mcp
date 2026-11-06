"""Checks both servers' tests share. Rules about one parameter belong in its own description, so tool
descriptions stay short; each tool says whether it only reads; and each successful result is structuredContent
that matches the tool's outputSchema, with the same JSON as its text."""

import json

# About twice the longest description that reads well; a longer one is turning back into a manual.
DESCRIPTION_LIMIT = 800


def check_tool_descriptions(test, tools):
    for tool in tools:
        with test.subTest(tool=tool["name"]):
            test.assertLessEqual(len(tool["description"]), DESCRIPTION_LIMIT)
            test.assertIn("readOnlyHint", tool.get("annotations", {}))
            for name, schema in tool["inputSchema"]["properties"].items():
                test.assertTrue(schema.get("description"), f"{name} has no description")


def check_output_schemas(test, tools):
    for tool in tools:
        with test.subTest(tool=tool["name"]):
            schema = tool.get("outputSchema")
            test.assertIsInstance(schema, dict, "no outputSchema")
            test.assertEqual(schema["type"], "object")


TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def fits(kind, value):
    """Whether value is of the JSON Schema type kind. A bool is not a number, though Python counts it as one."""
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[kind])


def schema_problems(schema, value, where="result"):
    """What in value does not match the schema. Only the keywords the servers' schemas use are checked: type, enum,
    required, properties, and items. Others, such as additionalProperties, minimum, and maximum, are ignored, since
    the output schemas leave objects open so that a new field does not break a client."""
    allowed = schema.get("type")
    if allowed is not None:
        allowed = allowed if isinstance(allowed, list) else [allowed]
        if not any(fits(kind, value) for kind in allowed):
            return [f"{where} is {type(value).__name__}, not {' or '.join(allowed)}"]
    if "enum" in schema and value not in schema["enum"]:
        return [f"{where} is {value!r}, not one of {schema['enum']}"]
    problems = []
    if isinstance(value, dict):
        problems += [f"{where}.{name} is missing" for name in schema.get("required", []) if name not in value]
        for name, sub in schema.get("properties", {}).items():
            if name in value:
                problems += schema_problems(sub, value[name], f"{where}.{name}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            problems += schema_problems(schema["items"], item, f"{where}[{index}]")
    return problems


def structured_result_problems(tool, result):
    """What is wrong with a successful result: its structuredContent must match the tool's outputSchema, and its
    first text must be that same JSON."""
    structured = result.get("structuredContent")
    if not isinstance(structured, dict):
        return ["no structuredContent"]
    problems = schema_problems(tool["outputSchema"], structured)
    if json.loads(result["content"][0]["text"]) != structured:
        problems.append("the text is not the structuredContent JSON")
    return problems


def check_structured_result(test, tool, result):
    test.assertEqual(structured_result_problems(tool, result), [])
