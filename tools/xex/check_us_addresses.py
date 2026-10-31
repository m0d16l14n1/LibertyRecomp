"""Check that the hook sources only use guest addresses of the US TU8 compile (the build also produced by
Games-on-Demand base 6 + TU8). Every sub_/__imp__sub_ name must be a function in generated/, every ctx.lr
key a return address in generated/. Other 0x82/0x83 literals are classified against the pre-PAL (US) and
post-remap (PAL) trees so PAL leftovers stand out.
usage: check_us_addresses.py [--git-us REV --git-pal REV]   (run from the repository root)"""
import argparse, collections, glob, os, re, subprocess
ap = argparse.ArgumentParser()
ap.add_argument('--git-us', default='8cc1b982^')   # last commit before the US->PAL remap
ap.add_argument('--git-pal', default='10a31883')   # remap + immediates + PAL-only fixes
a = ap.parse_args()
R = 'glue/rexglue-sdk-main/gta4-recomp'
TOKEN = re.compile(r'(__imp__sub_|sub_|0x|0X)(8[23][0-9A-Fa-f]{6})(?![0-9A-Fa-f])')
gen = ''.join(open(f).read() for f in glob.glob(f'{R}/generated/gta4_recomp.*.cpp'))
funcs = set(int(x, 16) for x in re.findall(r'\{ 0x([0-9A-F]{8}), sub_', open(f'{R}/generated/gta4_init.cpp').read()))
lrs = set(int(x, 16) for x in re.findall(r'ctx\.lr = 0x([0-9A-F]{8});', gen))
def tree_tokens(rev):
    files = subprocess.run(['git', 'ls-tree', '-r', '--name-only', rev, f'{R}/src'], capture_output=True, text=True).stdout.split()
    out = set()
    for f in files:
        if f.endswith(('.cpp', '.h', '.inc', '.mm')) and '/install/' not in f:
            out |= {int(v, 16) for _, v in TOKEN.findall(subprocess.run(['git', 'show', f'{rev}:{f}'], capture_output=True, text=True, errors='replace').stdout)}
    return out
us_tree, pal_tree = tree_tokens(a.git_us), tree_tokens(a.git_pal)
issues = collections.defaultdict(list); counts = collections.Counter()
for f in sorted(glob.glob(f'{R}/src/**/*', recursive=True)):
    if not f.endswith(('.cpp', '.h', '.inc', '.mm')) or '/install/' in f: continue
    for n, line in enumerate(open(f, errors='replace'), 1):
        for prefix, v in TOKEN.findall(line):
            x = int(v, 16)
            # A value only the post-remap tree used is a PAL leftover even if it happens to be a
            # valid US function or return address too (US bl sites are dense, so collisions occur).
            if x in pal_tree and x not in us_tree: kind = 'PAL-leftover'
            elif prefix != '0x' and prefix != '0X':
                kind = 'ok-func' if x in funcs else 'BAD-func'
            elif x in funcs: kind = 'ok-func'
            elif x in lrs: kind = 'ok-lr'
            elif x in us_tree and x not in pal_tree: kind = 'ok-us'
            elif x in us_tree and x in pal_tree: kind = 'ok-both'
            else: kind = 'new-unverified'
            counts[kind] += 1
            if not kind.startswith('ok'):
                issues[kind].append(f'{f[len(R)+1:]}:{n}: {prefix}{v}  {line.strip()[:110]}')
print(dict(counts))
for k, v in issues.items():
    print(f'\n== {k} ({len(v)})'); print('\n'.join(v))
