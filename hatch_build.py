"""Hatchling build hook: compile libpingo with Zig and bundle it in the wheel.

Runs `zig build` (ReleaseSafe) at build time, copies the resulting shared
library next to the `pingo` package sources, and force-includes it in the
wheel as `pingo/<libname>`. The wheel therefore ships a self-contained
libpingo — `pip install pingo` needs Zig only at build time, not at runtime.
The build is tagged platform-specific (not pure-Python) since it carries a
compiled artifact.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


def _lib_filename() -> str:
    if sys.platform == "darwin":
        return "libpingo.dylib"
    if sys.platform in ("win32", "cygwin"):
        return "pingo.dll"
    return "libpingo.so"


class PingoBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict) -> None:
        root = Path(self.root)
        libname = _lib_filename()

        subprocess.run(
            ["zig", "build", "-Doptimize=ReleaseSafe"],
            cwd=root,
            check=True,
        )

        src = root / "zig-out" / "lib" / libname
        if not src.exists():
            raise FileNotFoundError(
                f"expected {src} after `zig build`; is the shared library "
                "target still installed in build.zig?"
            )
        dst = root / "python" / "pingo" / libname
        shutil.copy2(src, dst)

        # Ship a platform wheel that carries the compiled library. The binding
        # is ctypes (no C-extension ABI), so it runs on any Python 3.10+ on this
        # platform: tag it py3-none-<platform>, not cp3xx-cp3xx.
        from packaging.tags import platform_tags

        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{next(iter(platform_tags()))}"
        build_data["force_include"][str(dst)] = f"pingo/{libname}"
