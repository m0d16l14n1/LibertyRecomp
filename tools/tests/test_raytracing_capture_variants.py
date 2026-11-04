"""Geometry-capture variant generator (tools/metal/raytracing_capture_variants.py)."""
from __future__ import annotations
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/metal"))
import shader_archive as archive  # noqa: E402
import raytracing_capture_variants as capture  # noqa: E402

# The stock translated vertex entry-point form, reduced to what the generator touches.
VERTEX = """struct PushConstants
{
    ulong VertexShaderConstants;
    ulong PixelShaderConstants;
    ulong SharedConstants;
};
struct VertexShaderInput
{
#ifdef __air__
	float4 iPosition0 [[attribute(0)]];
#else
	[[vk::location(0)]] float4 iPosition0 : POSITION0;
#endif
};
struct Interpolators
{
#ifdef __air__
	float4 oPos [[position]] [[invariant]];
	float4 oTexCoord0 [[user(TEXCOORD0)]];
#else
	float4 oPos : SV_Position;
#endif
};
#ifdef __air__
[[vertex]]
#else
[shader("vertex")]
#endif
Interpolators shaderMain(
#ifdef __air__
	constant Texture2DDescriptorHeap* g_Texture2DDescriptorHeap [[buffer(0)]],
	constant Texture2DArrayDescriptorHeap* g_Texture2DArrayDescriptorHeap [[buffer(1)]],
	constant Texture3DDescriptorHeap* g_Texture3DDescriptorHeap [[buffer(2)]],
	constant TextureCubeDescriptorHeap* g_TextureCubeDescriptorHeap [[buffer(3)]],
	constant SamplerDescriptorHeap* g_SamplerDescriptorHeap [[buffer(4)]],
	constant PushConstants& g_PushConstants [[buffer(8)]],
	VertexShaderInput input [[stage_in]]
#else
	VertexShaderInput input
#endif
)
{
	Interpolators output = Interpolators{};
	output.oPos = input.iPosition0;
	output.oPos.xy += g_HalfPixelOffset * output.oPos.w;
	return output;
}
"""


class CaptureVariantTests(unittest.TestCase):
    def test_wraps_the_original_function(self):
        out = capture.transform(VERTEX, archive.VERTEX)
        self.assertEqual(out.count("Interpolators liberty_capture_original("), 1)
        self.assertNotIn("Interpolators shaderMain(", out)
        self.assertEqual(out.count("[[vertex]]"), 1)  # only the wrapper is an entry point
        original = out[out.index("liberty_capture_original("):out.index("{", out.index("liberty_capture_original("))]
        self.assertNotIn("[[buffer(", original)
        self.assertNotIn("[[stage_in]]", original)
        self.assertIn("output.oPos.xy += g_HalfPixelOffset", out)  # the body is untouched

    def test_wrapper_contract(self):
        out = capture.transform(VERTEX, archive.VERTEX)
        wrapper = out[out.index("[[vertex]] void shaderMain("):]
        for binding in ("constant LibertyCaptureDraw& capture [[buffer(6)]]",
                        "device float4* libertyPositions [[buffer(7)]]",
                        "constant PushConstants& g_PushConstants [[buffer(8)]]",
                        "VertexShaderInput input [[stage_in]]", "uint libertyVertex [[vertex_id]]"):
            self.assertIn(binding, wrapper)
        self.assertIn("slot>=capture.vertexCount", wrapper)
        self.assertIn(f"SharedConstants+{capture.HALF_PIXEL_OFFSET}", wrapper)  # unjittered, offset removed
        self.assertIn(f"SharedConstants+{capture.DEPTH_RANGE}", wrapper)
        self.assertIn("capture.clipToWorld[3]*clip.w", wrapper)
        self.assertIn("0x7FC00000u", wrapper)  # unplaced vertices are NaN, inactive in a build
        self.assertIn("struct LibertyCaptureDraw", out)

    def test_refusals(self):
        with self.assertRaises(ValueError):
            capture.transform(VERTEX, archive.PIXEL)
        once = capture.transform(VERTEX, archive.VERTEX)
        with self.assertRaises(ValueError):
            capture.transform(once, archive.VERTEX)
        with self.assertRaises(ValueError):
            capture.transform("struct LibertyTemporalDraw {};" + VERTEX, archive.VERTEX)
        override = VERTEX.replace("Interpolators shaderMain(", "vertex Out shaderMain(")
        with self.assertRaises(capture.Unsupported):
            capture.transform(override, archive.VERTEX)
        no_position = VERTEX.replace("float4 oPos [[position]] [[invariant]];", "float4 oPos [[user(P)]];")
        with self.assertRaises(capture.Unsupported):
            capture.transform(no_position, archive.VERTEX)

    @unittest.skipUnless(os.environ.get("LIBERTY_METAL_SOURCES"), "set LIBERTY_METAL_SOURCES to the generated sources")
    def test_generated_corpus(self):
        sources = Path(os.environ["LIBERTY_METAL_SOURCES"])
        done = skipped = 0
        for path in sorted(sources.glob("*.early.metal")):
            text = path.read_text()
            stage, _, _ = archive.source_metadata(text)
            if stage != archive.VERTEX:
                continue
            try:
                capture.transform(text, stage)
                done += 1
            except capture.Unsupported:
                skipped += 1
        self.assertGreater(done, 0)
        self.assertLess(skipped, done)


if __name__ == "__main__":
    unittest.main()
