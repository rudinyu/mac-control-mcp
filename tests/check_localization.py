import glob
import json
import re
import sys

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|@|d|ld)")


def specifiers(text):
    """Format specifiers in argument order, resolving positional ones such as %2$@."""
    found = []
    for index, match in enumerate(SPEC.finditer(text)):
        position = int(match.group(1)) if match.group(1) else index + 1
        found.append((position, match.group(2)))
    return [kind for _, kind in sorted(found)]


strings_dir, tables = sys.argv[1], sys.argv[2:]
used = set()
for path in glob.glob(f"{strings_dir}/*.stringsdata"):
    for table in json.load(open(path, encoding="utf-8")).get("tables", {}).values():
        used.update(entry["key"] for entry in table)
used.discard("")  # an empty .help("") needs no translation

problems = 0
for table in tables:
    translations = json.load(open(table, encoding="utf-8"))
    for key in sorted(used - translations.keys()):
        problems += 1
        print(f"{table}: missing translation for {key!r}")
    for key in sorted(translations.keys() - used):
        problems += 1
        print(f"{table}: translation no longer used: {key!r}")
    for key in sorted(used & translations.keys()):
        if specifiers(key) != specifiers(translations[key]):
            problems += 1
            print(f"{table}: format specifiers differ for {key!r}")
    print(f"{table}: {len(used & translations.keys())} of {len(used)} strings translated")
sys.exit(1 if problems else 0)
