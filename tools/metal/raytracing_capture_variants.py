#!/usr/bin/env python3
"""Offline geometry-capture variants of the title's vertex shaders, for ray tracing.

Each variant runs the original translated vertex function unchanged and writes
the vertex's world-space position to a buffer instead of rasterizing it. The
renderer draws it with rasterization disabled, so skinning, wheel transforms and
foliage wind come out exactly as the game drew them, whichever registers hold
the transforms. World space is recovered from the unjittered clip position with
the frame's inverse view-projection, supplied per draw in LibertyCaptureDraw.

Contract (gta4_metal/raytracing/capture.h must match):
  buffer(6)  constant LibertyCaptureDraw: clipToWorld (column-major, world = M * clip),
             firstVertex, vertexCount, flags, padding
  buffer(7)  device float4* positions: positions[vertex_id - firstVertex] = (world.xyz, 1),
             or NaN when the vertex cannot be placed (a remapped depth range, w = 0)
  buffer(8)  the title's PushConstants, as for the stock pipeline
  buffers 0-4 and the vertex streams are bound exactly as for the stock pipeline.
Only the stock entry-point form is supported; other sources (converted overrides)
are reported and left out, and their draws are not captured.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import dataclasses
from pathlib import Path
import re
import sys
import shader_archive as archive

HEAPS = "g_Texture2DDescriptorHeap,g_Texture2DArrayDescriptorHeap,g_Texture3DDescriptorHeap,g_TextureCubeDescriptorHeap,g_SamplerDescriptorHeap"
PARAMETERS = """constant Texture2DDescriptorHeap* g_Texture2DDescriptorHeap [[buffer(0)]],
constant Texture2DArrayDescriptorHeap* g_Texture2DArrayDescriptorHeap [[buffer(1)]],
constant Texture3DDescriptorHeap* g_Texture3DDescriptorHeap [[buffer(2)]],
constant TextureCubeDescriptorHeap* g_TextureCubeDescriptorHeap [[buffer(3)]],
constant SamplerDescriptorHeap* g_SamplerDescriptorHeap [[buffer(4)]],
constant LibertyCaptureDraw& capture [[buffer(6)]],
device float4* libertyPositions [[buffer(7)]],
constant PushConstants& g_PushConstants [[buffer(8)]]"""
CONTRACT = """
#ifdef __air__
struct LibertyCaptureDraw {
    float4x4 clipToWorld;
    uint firstVertex;
    uint vertexCount;
    uint flags;
    uint padding;
};
#endif
"""
MARKER = "Interpolators shaderMain("
# Shared-constant byte offsets, as in temporal_shader_variants.py.
HALF_PIXEL_OFFSET = 552
DEPTH_RANGE = 1264


class Unsupported(ValueError):
    """A source this generator does not handle; its draws are simply not captured."""


def transform(source: str, stage: int) -> str:
    if stage != archive.VERTEX:
        raise ValueError("capture variants exist for vertex shaders only")
    if "LibertyCaptureDraw" in source or "LibertyTemporalDraw" in source:
        raise ValueError("source is already a variant")
    if source.count(MARKER) != 1:
        raise Unsupported("not the stock vertex entry-point form")
    body_start = source.index("{", source.index(MARKER))
    prefix, body = source[:body_start], source[body_start:]
    start = prefix.index(MARKER)
    # The original becomes an ordinary function: no resource or stage-in attributes.
    signature = re.sub(r"\[\[(?:buffer\(\d+\)|stage_in)\]\]", "", prefix[start:])
    prefix = prefix[:start] + signature.replace(MARKER, "Interpolators liberty_capture_original(", 1)
    prefix = prefix.replace("[[vertex]]", "")
    if not re.search(r"struct Interpolators\s*\{[^}]*float4 oPos \[\[position\]\]", prefix, re.S):
        raise Unsupported("no clip-space position output")
    if not re.search(r"VertexShaderInput input\s*(?:\)|$)", signature, re.M):
        raise Unsupported("unexpected stage-in parameter")
    wrapper = f"""
#ifdef __air__
[[vertex]] void shaderMain({PARAMETERS}, VertexShaderInput input [[stage_in]], uint libertyVertex [[vertex_id]]) {{
    const uint slot=libertyVertex-capture.firstVertex;
    if(slot>=capture.vertexCount) return;
    Interpolators current=liberty_capture_original({HEAPS},g_PushConstants,input);
    float4 clip=current.oPos;
    const float2 halfPixel=*(reinterpret_cast<device float2*>(g_PushConstants.SharedConstants+{HALF_PIXEL_OFFSET}));
    clip.xy-=halfPixel*clip.w;
    const float2 depthRange=*(reinterpret_cast<device float2*>(g_PushConstants.SharedConstants+{DEPTH_RANGE}));
    const float4 world=capture.clipToWorld*clip;
    const bool placed=all(depthRange==float2(0,1)) && clip.w!=0.0f && isfinite(world.w) && abs(world.w)>1.0e-20f;
    const float3 position=world.xyz/world.w;
    libertyPositions[slot]=placed&&all(isfinite(position))?float4(position,1.0f):float4(as_type<float>(0x7FC00000u));
}}
#endif
"""
    return CONTRACT + prefix + body + wrapper


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
        raise ValueError("capture compiler jobs must be in [1,4]")
    records = archive.parse_archive(args.archive.read_bytes())
    chosen = {int(value, 16) for value in args.hash}
    selected = [r for r in records if r.stage == archive.VERTEX and (not chosen or r.shader_hash in chosen)]
    if chosen - {r.shader_hash for r in selected}:
        raise ValueError("requested capture shader is absent from the stock vertex inventory")
    compiler = None if args.audit_only else archive.MetalCompiler(args.work, "macosx", args.deployment, args.math_mode)

    def prepare(record):
        variants = []
        for suffix in ("early", "late") if record.late else ("early",):
            path = args.sources / f"{record.shader_hash:016X}.{suffix}.metal"
            try:
                source = transform(path.read_text(), record.stage)
            except Unsupported as reason:
                return None, f"{record.shader_hash:016X}: {reason}"
            if compiler:
                args.work.mkdir(parents=True, exist_ok=True)
                (args.work / f"capture-{path.name}").write_text(source)
                variants.append(compiler.compile(source))
        if not compiler:
            return record, None
        return dataclasses.replace(record, early=variants[0], late=variants[1] if record.late else b""), None

    compiled, skipped = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for record, reason in pool.map(prepare, selected):
            if record is None:
                skipped.append(reason)
            else:
                compiled.append(record)
    for reason in skipped:
        print(f"raytracing_capture_variants skipped {reason}", file=sys.stderr)
    if compiler:
        archive._atomic_write(args.output, archive.build_archive(compiled))
    print(f"raytracing_capture_variants {'audited' if args.audit_only else 'compiled'}={len(compiled)} skipped={len(skipped)}")


if __name__ == "__main__":
    main()
