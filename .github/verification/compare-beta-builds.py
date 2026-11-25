"""Compare this runtime's PE prefix and the individual payload file contents."""
import hashlib
import sys
import zipfile
from pathlib import Path


def contents(path):
    with path.open("rb") as source, zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        source.seek(0)
        image = source.read(min(entry.header_offset for entry in entries))
        files = {}
        for entry in entries:
            if entry.filename in files:
                raise ValueError(f"Repeated payload name {entry.filename!r}")
            files[entry.filename] = hashlib.sha256(archive.read(entry)).digest()
        return hashlib.sha256(image).digest(), files


first_image, first = contents(Path(sys.argv[1]))
second_image, second = contents(Path(sys.argv[2]))
different = sorted(name for name in first.keys() | second.keys() if first.get(name) != second.get(name))
print(f"PE prefix bytes equal: {first_image == second_image}")
print(f"Payload files: {len(first)} in the tested executable, {len(second)} in the second reconstruction.")
print(f"Payload entries with changed names or decompressed bytes: {len(different)}")
for name in different[:15]:
    print(f"  {name}")
