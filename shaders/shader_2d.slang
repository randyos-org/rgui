// Draws a single anti-aliased, optionally-rounded, optionally-bordered box
// per quad, using a signed-distance-field (SDF) evaluated in the fragment
// shader (Inigo Quilez's rounded-box SDF). Blur=0 gives a crisp 1px-AA
// edge; a larger blur with FillColor==BorderColor and BorderWidth=0 gives
// a soft drop shadow. This one primitive covers flat rects, rounded
// widgets, circles (Radius == half of HalfSize), and shadows - see
// src/demo/widgets.zig's appendBox/appendShadow.

struct VSInput {
  float2 Pos;
  float2 Local;
  float2 HalfSize;
  float Radius;
  float BorderWidth;
  float Blur;
  float4 FillColor;
  float4 BorderColor;
};

struct PushConstants {
  float2 screenSize;
};

[[vk::push_constant]]
PushConstants pushConstants;

struct VSOutput {
  float4 Pos : SV_POSITION;
  float2 Local;
  float2 HalfSize;
  float Radius;
  float BorderWidth;
  float Blur;
  float4 FillColor;
  float4 BorderColor;
};

[shader("vertex")]
VSOutput main(VSInput input) {
  VSOutput output;
  float2 ndc = (input.Pos / pushConstants.screenSize) * 2.0 - 1.0;
  output.Pos = float4(ndc, 0.0, 1.0);
  output.Local = input.Local;
  output.HalfSize = input.HalfSize;
  output.Radius = input.Radius;
  output.BorderWidth = input.BorderWidth;
  output.Blur = input.Blur;
  output.FillColor = input.FillColor;
  output.BorderColor = input.BorderColor;
  return output;
}

float sdRoundedBox(float2 p, float2 b, float r) {
  float2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

[shader("fragment")]
float4 main(VSOutput input) {
  float d = sdRoundedBox(input.Local, input.HalfSize, input.Radius);

  // Fixed 1px antialiasing width regardless of blur, so crisp widget
  // edges (blur left at its ~1px default) stay crisp; `edge` is how far
  // outside the shape the fill fades to fully transparent - either just
  // the AA width, or the full shadow blur radius.
  float aa = 1.0;
  float edge = max(input.Blur, aa);
  float borderInner = -input.BorderWidth;

  float fillT = 1.0 - smoothstep(borderInner - aa, borderInner + aa, d);
  float shapeAlpha = 1.0 - smoothstep(-aa, edge, d);

  float4 color = lerp(input.BorderColor, input.FillColor, fillT);
  color.a *= shapeAlpha;
  return color;
}
