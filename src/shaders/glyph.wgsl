@group(0) @binding(0) var glyph_atlas: texture_2d<f32>;
@group(0) @binding(1) var glyph_sampler: sampler;

struct VertexOut {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
  @location(1) color: vec4<f32>,
  @location(2) @interpolate(flat) params: vec4<f32>,
}

@vertex
fn vs_main(
  @builtin(vertex_index) vertex_index: u32,
  @location(0) rect: vec4<f32>,
  @location(1) uv_rect: vec4<f32>,
  @location(2) color: vec4<f32>,
  @location(3) params: vec4<f32>,
) -> VertexOut {
  let corners = array<vec2<f32>, 6>(
    vec2<f32>(0.0, 0.0), vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 1.0),
    vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(1.0, 0.0),
  );
  let corner = corners[vertex_index];
  var out: VertexOut;
  out.position = vec4<f32>(
    mix(rect.x, rect.z, corner.x),
    mix(rect.y, rect.w, corner.y),
    0.0,
    1.0,
  );
  out.uv = vec2<f32>(
    mix(uv_rect.x, uv_rect.z, corner.x),
    mix(uv_rect.y, uv_rect.w, corner.y),
  );
  out.color = color;
  out.params = params;
  return out;
}

@fragment
fn fs_main(input: VertexOut) -> @location(0) vec4<f32> {
  let sample = textureSample(glyph_atlas, glyph_sampler, input.uv);
  let opacity = input.params.y;
  if (input.params.x > 0.5) {
    if (sample.a > 0.0) {
      return vec4<f32>(sample.rgb / sample.a, sample.a * opacity);
    }
    return vec4<f32>(0.0);
  }
  return vec4<f32>(input.color.rgb, input.color.a * sample.a * opacity);
}
