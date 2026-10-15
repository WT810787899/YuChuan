import os, struct, sys

root = r"D:\Coding\YuChuan"
targets = {
    705076105: "OLD(705076105)",
    -793795930 & 0xFFFFFFFF: "NEW(-793795930)",
}
pats = {}
for v, label in targets.items():
    pats[struct.pack("<i", v if v < 0x80000000 else v - 0x100000000)] = label

results = []
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        if not (fn.endswith(".dll") or fn.endswith(".so") or fn.endswith(".dylib")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            size = os.path.getsize(p)
        except OSError:
            continue
        if size < 50 * 1024:
            continue
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        found = set()
        for pat, label in pats.items():
            if pat in data:
                found.add(label)
        if found:
            results.append((p, size, ",".join(sorted(found)), os.path.getmtime(p)))

results.sort(key=lambda r: -r[3])
for p, size, found, mt in results:
    print(f"{found:32s} {size:>10d}  {p}")
if not results:
    print("no dll contains either hash constant")
