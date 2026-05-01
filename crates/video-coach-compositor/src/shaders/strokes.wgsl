// Stroke pass: triangle-strip-from-line-segments.
//
// Phase 9 ships only 16:9 → 16:9 so coordinates pass through in [0,1] space —
// no active-rect uniform. The vertex shader maps [0,1] → clip space via
// (x*2-1, 1-y*2). Each segment is rendered as a quad (two triangles) wide
// enough to cover the line width plus an AA falloff; the fragment shader
// computes perpendicular distance to the segment center line and smoothsteps
// the alpha.

struct VertexIn {
    // Per-quad-corner attributes:
    @location(0) position:    vec2<f32>,  // [0,1] space — the rasterized corner of the quad
    @location(1) segment_a:   vec2<f32>,  // segment start in [0,1]
    @location(2) segment_b:   vec2<f32>,  // segment end in [0,1]
    @location(3) half_width:  f32,        // half line width in [0,1] space (along the wider axis)
    @location(4) color:       vec4<f32>,  // stroke RGBA, premult-friendly (used straight as src color)
};

struct VsOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) frag_pos:    vec2<f32>,  // [0,1] space; flat-shaded copy of position
    @location(1) segment_a:   vec2<f32>,
    @location(2) segment_b:   vec2<f32>,
    @location(3) half_width:  f32,
    @location(4) color:       vec4<f32>,
};

@vertex
fn vs_stroke(in: VertexIn) -> VsOut {
    var out: VsOut;
    // [0,1] top-left origin → clip space. Y is flipped because clip space is
    // bottom-up.
    let clip_xy = vec2<f32>(in.position.x * 2.0 - 1.0, 1.0 - in.position.y * 2.0);
    out.clip_pos = vec4<f32>(clip_xy, 0.0, 1.0);
    out.frag_pos = in.position;
    out.segment_a = in.segment_a;
    out.segment_b = in.segment_b;
    out.half_width = in.half_width;
    out.color = in.color;
    return out;
}

@fragment
fn fs_stroke(in: VsOut) -> @location(0) vec4<f32> {
    let p = in.frag_pos;
    let a = in.segment_a;
    let b = in.segment_b;
    let ab = b - a;
    let ab_len_sq = max(dot(ab, ab), 1e-12);
    // Project p onto segment AB and clamp t ∈ [0,1] so endpoints get round
    // caps (distance to nearest endpoint when off the segment span).
    let t = clamp(dot(p - a, ab) / ab_len_sq, 0.0, 1.0);
    let closest = a + ab * t;
    let dist = length(p - closest);

    // 1-px feather in [0,1] space — assume ~1080 output (1/1080 ≈ 0.00093).
    // Tighter feather looks crisper; wider risks visible banding. The exact
    // value is decoupled from output resolution since we render in [0,1].
    let feather = 0.001;
    let alpha = 1.0 - smoothstep(in.half_width - feather, in.half_width + feather, dist);

    if (alpha <= 0.0) {
        discard;
    }
    return vec4<f32>(in.color.rgb, in.color.a * alpha);
}
