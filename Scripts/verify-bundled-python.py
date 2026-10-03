"""Build-time portability and full dependency inventory check, run with bundled CPython."""
import importlib.metadata as metadata
import json
from pathlib import Path
import platform
import re
import subprocess
import sys

lock, root = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
normalize = lambda name: re.sub(r"[._-]+", "-", name.lower())
expected = dict((normalize(name), version) for name, version in
                (line.strip().split("==") for line in lock.read_text().splitlines()
                 if line.strip() and not line.lstrip().startswith("#")))
actual = {normalize(d.metadata["Name"]): d.version for d in metadata.distributions()}
if actual != expected or platform.python_version() != "3.12.14":
    raise SystemExit("Bundled Python/package inventory differs from pinned runtime: " +
                     json.dumps({"expected": expected, "actual": actual}))
import synapse.synapse_rust
import cryptography.hazmat.bindings._rust
import PIL.Image
# Keep relative interpreter aliases; reject all external links and library dependencies.
for path in root.rglob("*"):
    if path.is_symlink() and not path.resolve().is_relative_to(root):
        raise SystemExit("External runtime symlink: " + str(path))
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe"):
            # Wheels can retain a build-machine LC_ID_DYLIB. Give bundled libraries a
            # relative install ID before signing; dependencies themselves must already be portable.
            if path.suffix == ".dylib" and "--prepare" in sys.argv:
                subprocess.run(["/usr/bin/install_name_tool", "-id", "@rpath/" + path.name, str(path)], check=True)
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True)
            output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
            for line in output.splitlines():
                if not line.startswith("\t"):
                    continue
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit("Nonportable library: " + dependency + " in " + str(path))
print("Verified portable Python 3.12.14 and", len(actual), "pinned packages")
