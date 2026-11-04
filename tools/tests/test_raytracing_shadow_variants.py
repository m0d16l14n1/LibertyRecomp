"""Sun-shadow variant generator (tools/metal/raytracing_shadow_variants.py)."""
from __future__ import annotations
import os
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/metal"))
import shader_archive as archive  # noqa: E402
import raytracing_ao_variants as ao  # noqa: E402
import raytracing_shadow_variants as shadow  # noqa: E402

# The stock translated pixel entry-point form with lightShadowDirectional's cascade, reduced
# to what the generator reads (statements as 7B14CAC2A31D4199 has them).
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
	// GBufferTextureSampler0 GBufferTextureSampler1 gShadowZSamplerDir
	r0.x = (float)((xenosDot((float3)(r3.ywz), (float3)(-gDirectionalLight.zxy))));
	r7.xyzw = (float4)((r7.xyzw >= r6.wwww));
	r0.z = (float)((xenosDot((float4)(r7.zwxy), (float4)(c252.yyyy))));
	r1.x = (float)((-r0.z + c251.y));
	p0 = r5.w != 0.0;
	r1.x = (float)((xenosMul((float)(r4.w), (float)(r1.x)) + r0.z));
	if (p0)
		r0.xyz = (float3)((xenosMul((float3)(r3.xyz), (float3)(r1.xxx)) + r0.zyx));
	if (!p0)
		r1.yzw = (float3)((xenosMul((float3)(r0.zzz), (float3)(gLightAmbient1.zyx)) + gLightAmbient0.zyx));
	if (!p0)
		r1.yzw = (float3)((xenosMul((float3)(r3.yzw), (float3)(r1.xxx)) + r1.yzw));
	return output;
}
"""
FACTOR = "\tr1.x = libertySunShadowFactor(r1.x);"


class Transform(unittest.TestCase):
    def test_factor_combined_after_the_fade(self):
        out = shadow.transform(PIXEL, archive.PIXEL)
        self.assertEqual(out.count(FACTOR), 1)
        fade = out.index("r1.x = (float)((xenosMul((float)(r4.w), (float)(r1.x)) + r0.z));")
        self.assertLess(fade, out.index(FACTOR))
        self.assertLess(out.index(FACTOR), out.index("if (p0)\n\t\tr0.xyz"))  # before the sun uses it
        self.assertIn("libertySunShadow [[texture(1)]]", out)
        # The fetch and the macro open the body, before any use.
        self.assertLess(out.index("{\n#ifdef __air__\n\tconst float2 libertySunShadow2"), out.index(FACTOR))
        self.assertIn("#define libertySunShadowFactor(cascade) mix(min((cascade),libertySunShadow2.x),"
                      "libertySunShadow2.x,libertySunShadow2.y)", out)
        self.assertIn("#else\n\tInterpolators input\n#endif", out)  # the HLSL side is untouched
        # Off the GPU path the factor is the cascade's: g = 0, r = 1 -> min(cascade, 1).
        self.assertIn("const float2 libertySunShadow2=float2(1.0,0.0);", out)

    def test_other_registers(self):
        # FF4B1BA4B364BCD3: the average and the fade use other registers, with lines between.
        source = PIXEL.replace(
            "\tr0.z = (float)((xenosDot((float4)(r7.zwxy), (float4)(c252.yyyy))));\n"
            "\tr1.x = (float)((-r0.z + c251.y));\n\tp0 = r5.w != 0.0;\n"
            "\tr1.x = (float)((xenosMul((float)(r4.w), (float)(r1.x)) + r0.z));",
            "\tr7.x = (float)((xenosDot((float4)(r7.zwxy), (float4)(c252.yyyy))));\n"
            "\tps = max(r1.x, r1.x);\n\tr6.zw = (float2)((-r7.xy + c251.yy));\n"
            "\tr2.y = (float)((xenosMul((float)(r5.w), (float)(r6.z)) + r7.x));")
        out = shadow.transform(source, archive.PIXEL)
        self.assertIn("\tr2.y = libertySunShadowFactor(r2.y);", out)

    def test_composes_with_ao(self):
        both = shadow.transform(ao.transform(PIXEL, archive.PIXEL), archive.PIXEL)
        self.assertIn("libertyAmbientOcclusion [[texture(0)]]", both)
        self.assertIn("libertySunShadow [[texture(1)]]", both)
        self.assertEqual(both.count(FACTOR), 1)
        self.assertEqual(both.count(") * libertyAo;"), 1)

    def test_refusals(self):
        for broken in (
                PIXEL.replace("gShadowZSamplerDir", ""),                    # lightNoDirectional
                PIXEL.replace("GBufferTextureSampler0", ""),                # forward shader
                PIXEL.replace("iPos [[position]]", "iPosition"),
                PIXEL.replace(">= r6.wwww", "> r6.wwww"),                   # no cascade comparison
                PIXEL.replace("\tr7.xyzw = (float4)((r7.xyzw >= r6.wwww));",  # two comparisons
                              "\tr7.xyzw = (float4)((r7.xyzw >= r6.wwww));\n\tr8.xyzw = (float4)((r8.xyzw >= r6.wwww));"),
                PIXEL.replace("+ r0.z));\n\tif (p0)", "+ r0.w));\n\tif (p0)"),  # fade of something else
                PIXEL.replace("\tr1.x = (float)((xenosMul((float)(r4.w)",      # predicated fade
                              "\tif (p0)\n\tr1.x = (float)((xenosMul((float)(r4.w)"),
        ):
            with self.subTest(broken=broken[-400:]):
                with self.assertRaises(shadow.Unsupported):
                    shadow.transform(broken, archive.PIXEL)
        with self.assertRaises(ValueError):
            shadow.transform(PIXEL, archive.VERTEX)
        with self.assertRaises(ValueError):
            shadow.transform(shadow.transform(PIXEL, archive.PIXEL), archive.PIXEL)

    @unittest.skipUnless(os.environ.get("LIBERTY_METAL_SOURCES"), "set LIBERTY_METAL_SOURCES to the generated sources")
    def test_corpus(self):
        sources = Path(os.environ["LIBERTY_METAL_SOURCES"])
        changed = {}
        for path in sorted(sources.glob("*.metal")):
            try:
                out = shadow.transform(path.read_text(), archive.PIXEL)
            except ValueError:
                continue
            changed[path.name] = re.search(r"\n\t(r\d+\.[xyzw]) = libertySunShadowFactor", out).group(1)
        # lightShadowDirectional's global contribution, both forms; lightNoDirectional has no cascade.
        self.assertEqual(changed.get("7B14CAC2A31D4199.early.metal"), "r1.x")
        self.assertNotIn("97AC30BA76D5515F.early.metal", changed)
        self.assertLessEqual(len(changed), 8)


if __name__ == "__main__":
    unittest.main()
