@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var webcam_tex: texture_2d<f32>;
@group(0) @binding(2) var lin_sampler: sampler;

struct PipParams {
    // PiP rectangle in normalized output coords (0..1, top-left origin).
    pip_x:      f32,
    pip_y:      f32,
    pip_w:      f32,
    pip_h:      f32,
};
@group(0) @binding(3) var<uniform> params: PipParams;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) idx: u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0),
    );
    var uvs = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 1.0),
        vec2<f32>(2.0, 1.0),
        vec2<f32>(0.0, -1.0),
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    out.uv  = uvs[idx];
    return out;
}

@fragment
fn fs_pip(in: VsOut) -> @location(0) vec4<f32> {
    let src = textureSample(src_tex, lin_sampler, in.uv);

    // Inside the PiP rectangle, sample the webcam and overlay it opaquely.
    if (in.uv.x >= params.pip_x && in.uv.x < params.pip_x + params.pip_w &&
        in.uv.y >= params.pip_y && in.uv.y < params.pip_y + params.pip_h) {
        let pip_uv = vec2<f32>(
            (in.uv.x - params.pip_x) / params.pip_w,
            (in.uv.y - params.pip_y) / params.pip_h,
        );
        return textureSample(webcam_tex, lin_sampler, pip_uv);
    }

    return src;
}
