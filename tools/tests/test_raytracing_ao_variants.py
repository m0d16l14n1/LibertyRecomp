"""Ambient-occlusion variant generator (tools/metal/raytracing_ao_variants.py)."""
from __future__ import annotations
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/metal"))
import shader_archive as archive  # noqa: E402
import raytracing_ao_variants as ao  # noqa: E402

# The stock translated pixel entry-point form, reduced to what the generator touches.
PIXEL = """struct Interpolators
{
#ifdef __air__
	float4 iPos [[position]];
#endif
};
#ifdef __air__
[[fragment]]
#endif
PixelShaderOutput shaderMain(
#ifdef __air__
	Interpolators input [[stage_in]],
	constant SamplerDescriptorHeap* g_SamplerDescriptorHeap [[buffer(4)]],
	constant PushConstants& g_PushConstants [[buffer(8)]]
#else
	Interpolators input
#endif
)
{
	// GBufferTextureSampler0 GBufferTextureSampler1
	if (p0)
	{
		r1.yzw = (float3)((xenosMul((float3)(r1.yyy), (float3)(gLightAmbient1.zyx)) + gLightAmbient0.zyx));
	}
	if (!p0)
	{
		r1.yzw = (float3)((xenosMul((float3)(r0.zzz), (float3)(gLightAmbient1.zyx)) + gLightAmbient0.zyx));
	}
	return output;
}
"""


class Transform(unittest.TestCase):
    def test_both_branches_scaled(self):
        out = ao.transform(PIXEL, archive.PIXEL)
        self.assertEqual(out.count(") * libertyAo;"), 2)
        self.assertIn("libertyAmbientOcclusion [[texture(0)]]", out)
        # The fetch is the first thing in the body, before any use.
        body = out.index("{\n#ifdef __air__\n\tconst float libertyAo")
        self.assertLess(body, out.index(") * libertyAo;"))
        # The HLSL side keeps compiling: its parameter list is untouched.
        self.assertIn("#else\n\tInterpolators input\n#endif", out)

    def test_refusals(self):
        with self.assertRaises(ao.Unsupported):
            ao.transform(PIXEL.replace("gLightAmbient1", "gOther"), archive.PIXEL)
        with self.assertRaises(ao.Unsupported):  # forward shaders: no G-buffer
            ao.transform(PIXEL.replace("GBufferTextureSampler0", ""), archive.PIXEL)
        with self.assertRaises(ao.Unsupported):
            ao.transform(PIXEL.replace("iPos [[position]]", "iPosition"), archive.PIXEL)
        with self.assertRaises(ValueError):
            ao.transform(PIXEL, archive.VERTEX)
        with self.assertRaises(ValueError):
            ao.transform(ao.transform(PIXEL, archive.PIXEL), archive.PIXEL)

    @unittest.skipUnless(os.environ.get("LIBERTY_METAL_SOURCES"), "set LIBERTY_METAL_SOURCES to the generated sources")
    def test_corpus(self):
        sources = Path(os.environ["LIBERTY_METAL_SOURCES"])
        changed = []
        for path in sorted(sources.glob("*.early.metal")):
            try:
                ao.transform(path.read_text(), archive.PIXEL)
                changed.append(path.name[:16])
            except ValueError:
                pass
        self.assertIn("7B14CAC2A31D4199", changed)  # the global contribution (lightShadowDirectional)
        self.assertLessEqual(len(changed), 16)


if __name__ == "__main__":
    unittest.main()
