import os
import sys

from setuptools import setup, Extension

# `builder.py` sits next to this file; make it importable even when setuptools
# execs setup.py from an isolated build environment (PEP 517).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from builder import ZigBuilder

# Package metadata lives in pyproject.toml ([project]); this file only declares
# what PEP 621 cannot: the Zig extension source and the custom build_ext.
zaml = Extension("zaml", sources=["zamlmodule.zig"])

setup(
    ext_modules=[zaml],
    cmdclass={"build_ext": ZigBuilder},
)
