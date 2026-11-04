#!/usr/bin/env python3
"""Ambient-occlusion variants of the title's deferred-lighting pixel shaders, for ray tracing.

deferred_lighting's global contribution (lightShadowDirectional / lightNoDirectional)
computes a hemisphere ambient from the G-buffer normal:

    rA.xyz = (float3)((xenosMul((float3)(rB.sss), (float3)(gLightAmbient1.zyx)) + gLightAmbient0.zyx));

once per material branch. A variant multiplies exactly those statements by the ray-traced
AO at the fragment, so the AO darkens the ambient light only (the sun, its shadow and the
reflection are unchanged). Only shaders that read the G-buffer qualify: forward shaders
have the same statement but draw before the AO exists. On the November 2026 corpus that is
four shaders (0A009DBC8BFE9EA9, 7B14CAC2A31D4199, 97AC30BA76D5515F, FF4B1BA4B364BCD3).

Contract (gta4_metal/raytracing/ambient_occlusion.h and draw.mm must match):
  texture(0)  texture2d<float> libertyAmbientOcclusion: R16Float AO at the target's size, 1 = open
  everything else is bound exactly as for the stock pipeline.
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
PARAMETER = ",\n\ttexture2d<float, access::read> libertyAmbientOcclusion [[texture(0)]]"
FETCH = """
#ifdef __air__
	const float libertyAo=libertyAmbientOcclusion.read(min(uint2(input.iPos.xy),
		uint2(libertyAmbientOcclusion.get_width()-1,libertyAmbientOcclusion.get_height()-1))).r;
#else
	const float libertyAo=1.0;
#endif"""
AMBIENT = re.compile(
    r"(=\s*\(float3\)\(\(xenosMul\(\(float3\)\(r\d+\.[xyzw]{3}\),\s*\(float3\)\(gLightAmbient1\.[xyzw]{3}\)\)"
    r"\s*\+\s*gLightAmbient0\.[xyzw]{3}\)\));")


class Unsupported(ValueError):
    """A shader this generator does not change: it gets no AO variant."""


def transform(source: str, stage: int) -> str:
    if stage != archive.PIXEL:
        raise ValueError("AO variants exist for pixel shaders only")
    if "libertyAmbientOcclusion" in source:
        raise ValueError("source is already a variant")
    if source.count(MARKER) != 1:
        raise Unsupported("not the stock pixel entry-point form")
    # Deferred lighting only: forward shaders use the same ambient but draw before the AO exists.
    if "GBufferTextureSampler0" not in source or "GBufferTextureSampler1" not in source:
        raise Unsupported("not a deferred-lighting shader")
    if not re.search(r"struct Interpolators\s*\{[^}]*float4 iPos \[\[position\]\]", source, re.S):
        raise Unsupported("no fragment position input")
    source, statements = AMBIENT.subn(r"\1 * libertyAo;", source)
    if not statements:
        raise Unsupported("no hemisphere-ambient statement")
    start = source.index(MARKER)
    push = source.find(PUSH, start)
    if push < 0:
        raise Unsupported("unexpected pixel entry parameters")
    push += len(PUSH)
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
        raise ValueError("AO compiler jobs must be in [1,4]")
    records = archive.parse_archive(args.archive.read_bytes())
    chosen = {int(value, 16) for value in args.hash}
    selected = [r for r in records if r.stage == archive.PIXEL and (not chosen or r.shader_hash in chosen)]
    if chosen - {r.shader_hash for r in selected}:
        raise ValueError("requested AO shader is absent from the stock pixel inventory")
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
                (args.work / f"ao-{path.name}").write_text(source)
                variants.append(compiler.compile(source))
        if not compiler:
            return record
        return dataclasses.replace(record, early=variants[0], late=variants[1] if record.late else b"")

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        compiled = [record for record in pool.map(prepare, selected) if record is not None]
    for record in compiled:
        print(f"raytracing_ao_variants variant {record.shader_hash:016X}", file=sys.stderr)
    if compiler:
        archive._atomic_write(args.output, archive.build_archive(compiled))
    print(f"raytracing_ao_variants {'audited' if args.audit_only else 'compiled'}={len(compiled)} "
          f"unchanged={len(selected) - len(compiled)}")


if __name__ == "__main__":
    main()
