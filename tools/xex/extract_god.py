"""List or extract files from a Games-on-Demand (SVOD) package: the LIVE/CON header file plus its
<name>.data/Data#### folder. usage: extract_god.py <header file> [path/in/disc out_file]
With one argument, prints the package metadata and the root directory."""
import os, struct, sys

hdr_path = sys.argv[1]
data_dir = hdr_path + '.data'
h = open(hdr_path, 'rb').read(0x1800)
be32 = lambda b, o: struct.unpack('>I', b[o:o+4])[0]
assert h[:4] in (b'LIVE', b'PIRS', b'CON '), 'not an XContent package'
assert be32(h, 0x344) == 0x7000, f'content type {be32(h, 0x344):#x} is not Games on Demand (0x7000)'
print(f"title {be32(h, 0x360):08X} media {be32(h, 0x354):08X} "
      f"version {be32(h, 0x358):#x} base {be32(h, 0x35C):#x} "
      f"name {h[0x411:0x491].decode('utf-16-be', 'ignore').split(chr(0))[0]!r}")

# Each Data#### file: a 0x1000 level-1 hash block, then groups of a 0x1000 level-0 hash block
# followed by 0xCC data blocks of 0x1000. 0xA1C4000 bytes of disc data per file.
BLOCK, PER_GROUP, PER_FILE = 0x1000, 0xCC, 0xA1C4000
files = {}
def read(offset, size):
    out = bytearray()
    while size:
        index, r = divmod(offset, PER_FILE)
        group, within = divmod(r, PER_GROUP * BLOCK)
        chunk = min(size, PER_GROUP * BLOCK - within)
        f = files.get(index) or files.setdefault(index, open(os.path.join(data_dir, f'Data{index:04d}'), 'rb'))
        f.seek(BLOCK + group * (BLOCK + PER_GROUP * BLOCK) + BLOCK + within)
        out += f.read(chunk)
        offset += chunk; size -= chunk
    return bytes(out)

# XGD (GDF) volume descriptor at sector 32 of the disc image; GOD images may keep a leading gap.
MAGIC = b'MICROSOFT*XBOX*MEDIA'
base = next((b for b in (0, 0x2000, 0xFD90000, 0x2080000) if read(b + 0x10000, 20) == MAGIC), None)
assert base is not None, 'GDF volume descriptor not found'
root_sector, root_size = struct.unpack('<II', read(base + 0x10014, 8))

def walk(sector, size, prefix=''):
    table = read(base + sector * 0x800, size)
    stack, out = [0], []
    while stack:
        off = stack.pop() * 4
        if off + 14 > len(table) or table[off:off+4] == b'\xff\xff\xff\xff':
            continue
        left, right, start, length, attr, nlen = struct.unpack('<HHIIBB', table[off:off+14])
        name = table[off+14:off+14+nlen].decode('latin-1')
        out.append((prefix + name, start, length, attr & 0x10))
        stack += [x for x in (left, right) if x]
    return out

if len(sys.argv) == 2:
    for name, start, length, is_dir in sorted(walk(root_sector, root_size)):
        print(f"  {'<dir>' if is_dir else f'{length:>12}'}  {name}")
    sys.exit()

entries = walk(root_sector, root_size)
for part in sys.argv[2].strip('/').split('/'):
    match = next((e for e in entries if e[0].lower().rsplit('/', 1)[-1] == part.lower()), None)
    assert match, f'{part} not found'
    if match[3]:
        entries = walk(match[1], match[2], match[0] + '/')
with open(sys.argv[3], 'wb') as out:
    for pos in range(0, match[2], 0x1000000):
        out.write(read(base + match[1] * 0x800 + pos, min(0x1000000, match[2] - pos)))
print(f"wrote {sys.argv[3]} ({match[2]} bytes)")
