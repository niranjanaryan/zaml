import subprocess
import sys

failed = subprocess.call([sys.executable, "-m", "pip", "install", "-e", "."])
assert not failed

import zaml

# Scalars / nesting / coercions
assert zaml.load("a0: b1") == {"a0": "b1"}
assert zaml.load("a: 1\nb: 2.5\nc: true\nd: null\ne: hello\n") == {
    "a": 1,
    "b": 2.5,
    "c": True,
    "d": None,
    "e": "hello",
}
assert zaml.load("foo: 1\nbar: [a, b, 3.14]\n") == {"foo": 1, "bar": ["a", "b", 3.14]}

# Nested structures
assert zaml.load("a:\n  b: [1, 2, 3]\n  c: {d: e}\n") == {
    "a": {"b": [1, 2, 3], "c": {"d": "e"}}
}

# Explicit tags keep strings as strings
assert zaml.load("x: !!str 123") == {"x": "123"}

# Anchors and aliases
assert zaml.load("a: &x 1\nb: *x\n") == {"a": 1, "b": 1}

# Empty document -> None
assert zaml.load("") is None

# Malformed input raises
try:
    zaml.load("[unclosed")
except ValueError:
    pass
else:
    raise AssertionError("expected ValueError for malformed YAML")

print("zaml Python extension: all checks passed")
