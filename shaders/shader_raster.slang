// Samples a persistent, desktop-sized CPU-drawn canvas texture through the
// sub-rectangle the window currently occupies. See demo_raster.zig's
// RasterGpu and canvas.zig - the canvas is a single fixed-size surface in
// absolute desktop pixel coordinates, and the window is just a
// moving/resizing viewport onto it.

struct PushConstants {
  float2 canvasSize;
  float2 windowOffset;
};

[[vk::push_constant]]
PushConstants pushConstants;

struct VSOutput {
  float4 Pos : SV_POSITION;
};

// Full-screen triangle from just the vertex index - no vertex buffer.
[shader("vertex")]
VSOutput main(uint vertexIndex : SV_VertexID) {
  VSOutput output;
  float2 ndc = float2(
    (vertexIndex == 1) ? 3.0 : -1.0,
    (vertexIndex == 2) ? 3.0 : -1.0
  );
  output.Pos = float4(ndc, 0.0, 1.0);
  return output;
}

Sampler2D canvasTex;

[shader("fragment")]
float4 main(VSOutput input) {
  float2 uv = (pushConstants.windowOffset + input.Pos.xy) / pushConstants.canvasSize;
  return canvasTex.Sample(uv);
}
