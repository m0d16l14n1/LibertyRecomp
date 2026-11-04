#!/usr/bin/env python3
"""Ray-traced sun-shadow variants of the title's deferred-lighting pixel shaders.

deferred_lighting's global contribution with a sun (lightShadowDirectional) takes four
cascade taps of gShadowZSamplerDir, compares them with the receiver depth and averages
them, then fades the result towards lit with distance:

    rT.xyzw = (float4)((rT.xyzw >= rD.wwww));                                  // 4 taps
    rS.c = (float)((xenosDot((float4)(rT.zwxy), (float4)(cK.yyyy))));          // PCF average
    ...
    rF.x = (float)((xenosMul((float)(rG.w), (float)(rH.c)) + rS.c));           // faded factor

rF.x then scales the sun's diffuse and specular in both material branches. A variant
adds, right after that statement,

    rF.x = libertySunShadowFactor(rF.x);

which combines the cascade factor with the ray-traced visibility at the fragment:
min(cascade, traced) or the traced value alone (the texture's g channel picks per frame).
The sun colour, N.L, the ambient and the reflection are unchanged. Shaders without the
cascade (lightNoDirectional, forward shaders) get no variant.

Contract (gta4_metal/raytracing/sun_shadows.h and draw.mm must match):
  texture(1)  texture2d<float> libertySunShadow: RG16Float at the target's size,
              r = visibility (1 = lit), g = 1 to replace the cascade, 0 to take the minimum
  texture(0) stays free for libertyAmbientOcclusion (raytracing_ao_variants.py): the two
  transforms compose, so a later combined mode can apply both.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import dataclasses
from pathlib import Path
import re
import sys
import shader_archive as archive

MARKER = "PixelShaderOutput shaderMain("
PUSH = "constant PushConstants& g_PushConstants [[buffer(8)]]"
PARAMETER = ",\n\ttexture2d<float, access::read> libertySunShadow [[texture(1)]]"
FETCH = """
#ifdef __air__
	const float2 libertySunShadow2=libertySunShadow.read(min(uint2(input.iPos.xy),
		uint2(libertySunShadow.get_width()-1,libertySunShadow.get_height()-1))).rg;
#else
	const float2 libertySunShadow2=float2(1.0,0.0);
#endif
#define libertySunShadowFactor(cascade) mix(min((cascade),libertySunShadow2.x),libertySunShadow2.x,libertySunShadow2.y)"""
COMPARE = re.compile(r"^\t(r\d+)\.xyzw = \(float4\)\(\(r\d+\.xyzw >= r\d+\.wwww\)\);$", re.M)
AVERAGE = r"^\t(r\d+\.[xyzw]) = \(float\)\(\(xenosDot\(\(float4\)\({tap}\.[xyzw]{{4}}\), \(float4\)\(c\d+\.([xyzw])\2\2\2\)\)\)\);$"
FADE = r"^\t(r\d+\.[xyzw]) = \(float\)\(\(xenosMul\(\(float\)\(r\d+\.[xyzw]\), \(float\)\(r\d+\.[xyzw]\)\) \+ {average}\)\);$"


class Unsupported(ValueError):
    """A shader this generator does not change: it gets no shadow variant."""


def shadow_factor(source: str) -> tuple[str, int]:
    """The register component holding the faded cascade factor, and where its statement ends."""
    compares = COMPARE.findall(source)
    if len(compares) != 1:
        raise Unsupported(f"{len(compares)} cascade comparisons (need exactly 1)")
    averages = list(re.finditer(AVERAGE.format(tap=re.escape(compares[0])), source, re.M))
    if len(averages) != 1:
        raise Unsupported("no single cascade average")
    average = averages[0]
    fades = list(re.compile(FADE.format(average=re.escape(average.group(1))), re.M).finditer(source, average.end()))
    if not fades:
        raise Unsupported("no cascade fade statement")
    fade = fades[0]
    # A predicated statement (`if (p0)` on the line before, without braces) cannot take a
    # statement after it: the transpiler emits single-statement ifs.
    before = source.rfind("\n", 0, fade.start() - 1)
    if source[before + 1:fade.start()].strip().startswith("if"):
        raise Unsupported("predicated cascade fade")
    return fade.group(1), fade.end()


def transform(source: str, stage: int) -> str:
    if stage != archive.PIXEL:
        raise ValueError("shadow variants exist for pixel shaders only")
    if "libertySunShadow" in source:
        raise ValueError("source is already a shadow variant")
    if source.count(MARKER) != 1:
        raise Unsupported("not the stock pixel entry-point form")
    if "GBufferTextureSampler0" not in source or "GBufferTextureSampler1" not in source:
        raise Unsupported("not a deferred-lighting shader")
    if "gShadowZSamplerDir" not in source or "gDirectionalLight" not in source:
        raise Unsupported("no sun cascade")
    if not re.search(r"struct Interpolators\s*\{[^}]*float4 iPos \[\[position\]\]", source, re.S):
        raise Unsupported("no fragment position input")
    factor, end = shadow_factor(source)
    source = source[:end] + f"\n\t{factor} = libertySunShadowFactor({factor});" + source[end:]
    start = source.index(MARKER)
    push = source.find(PUSH, start)
    if push < 0:
        raise Unsupported("unexpected pixel entry parameters")
    push += len(PUSH)
    # After the AO parameter when the AO transform ran first: parameter order is free in MSL.
    source = source[:push] + PARAMETER + source[push:]
    body = re.compile(r"\)\s*\n\{").search(source, push)
    if not body:
        raise Unsupported("no entry-point body")
    open_brace = body.end()
    return source[:open_brace] + FETCH + source[open_brace:]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--hash", action="append", default=[])
    parser.add_argument("--deployment", default="26.0")
    parser.add_argument("--audit-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--math-mode", choices=sorted(archive.MetalCompiler.MATH_FLAGS), default="safe")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 4:
        raise ValueError("shadow compiler jobs must be in [1,4]")
    records = archive.parse_archive(args.archive.read_bytes())
    chosen = {int(value, 16) for value in args.hash}
    selected = [r for r in records if r.stage == archive.PIXEL and (not chosen or r.shader_hash in chosen)]
    if chosen - {r.shader_hash for r in selected}:
        raise ValueError("requested shadow shader is absent from the stock pixel inventory")
    compiler = None if args.audit_only else archive.MetalCompiler(args.work, "macosx", args.deployment, args.math_mode)

    def prepare(record):
        variants = []
        for suffix in ("early", "late") if record.late else ("early",):
            path = args.sources / f"{record.shader_hash:016X}.{suffix}.metal"
            try:
                source = transform(path.read_text(), record.stage)
            except Unsupported:
                return None
            if compiler:
                args.work.mkdir(parents=True, exist_ok=True)
                (args.work / f"shadow-{path.name}").write_text(source)
                variants.append(compiler.compile(source))
        if not compiler:
            return record
        return dataclasses.replace(record, early=variants[0], late=variants[1] if record.late else b"")

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        compiled = [record for record in pool.map(prepare, selected) if record is not None]
    for record in compiled:
        print(f"raytracing_shadow_variants variant {record.shader_hash:016X}", file=sys.stderr)
    if compiler:
        archive._atomic_write(args.output, archive.build_archive(compiled))
    print(f"raytracing_shadow_variants {'audited' if args.audit_only else 'compiled'}={len(compiled)} "
          f"unchanged={len(selected) - len(compiled)}")


if __name__ == "__main__":
    main()
