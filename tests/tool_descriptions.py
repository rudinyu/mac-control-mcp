"""Checks every tool list in the tests shares: rules about one parameter belong in its own description, so
tool descriptions stay short, and each tool says whether it only reads."""

# About twice the longest description that reads well; a longer one is turning back into a manual.
DESCRIPTION_LIMIT = 800


def check_tool_descriptions(test, tools):
    for tool in tools:
        with test.subTest(tool=tool["name"]):
            test.assertLessEqual(len(tool["description"]), DESCRIPTION_LIMIT)
            test.assertIn("readOnlyHint", tool.get("annotations", {}))
            for name, schema in tool["inputSchema"]["properties"].items():
                test.assertTrue(schema.get("description"), f"{name} has no description")
