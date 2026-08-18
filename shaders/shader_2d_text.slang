// Draws textured quads sampling a single-channel (R8) glyph atlas, tinting
// the sampled coverage by a per-vertex color. Separate pipeline from
// shader_2d.slang's SDF box shader since text needs a bound texture and a
// different vertex format (pos/uv/color) instead of box geometry.

struct VSInput {
  float2 Pos;
  float2 UV;
  float4 Color;
};

struct PushConstants {
  float2 screenSize;
};

[[vk::push_constant]]
PushConstants pushConstants;

struct VSOutput {
  float4 Pos : SV_POSITION;
  float2 UV;
  float4 Color;
};

[shader("vertex")]
VSOutput main(VSInput input) {
  VSOutput output;
  float2 ndc = (input.Pos / pushConstants.screenSize) * 2.0 - 1.0;
  output.Pos = float4(ndc, 0.0, 1.0);
  output.UV = input.UV;
  output.Color = input.Color;
  return output;
}

Sampler2D atlasTex;

[shader("fragment")]
float4 main(VSOutput input) {
  float coverage = atlasTex.Sample(input.UV).r;
  return float4(input.Color.rgb, input.Color.a * coverage);
}
