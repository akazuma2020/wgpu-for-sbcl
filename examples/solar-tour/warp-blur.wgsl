struct Uniforms {
    resolution: vec2f, time: f32, sceneTime: f32,
    warp: f32, destination: u32, yaw: f32, pitch: f32,
    roll: f32, thrust: f32, progress: f32, warpPhase: f32,
    randomSeed: f32, showOrbit: u32, topView: u32,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var source: texture_2d<f32>;
@group(0) @binding(2) var linearSampler: sampler;
struct Output {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
};
@vertex fn blurVS(@location(0) p: vec2f) -> Output {
    var out: Output;
    // The blurred body is composited after the orbit.  Put covered pixels at
    // the foreground depth so the orbit cannot show through a planet during
    // warp; transparent pixels are discarded by compositeFS.
    out.position = vec4f(p, 0.0, 1.0);
    out.uv = p * vec2f(0.5, -0.5) + vec2f(0.5);
    return out;
}
// Two separable Gaussian passes, on premultiplied color and coverage together.
fn filtered(uv: vec2f, axis: vec2f) -> vec4f {
    let strength = smoothstep(0.0, 0.85, u.warp);
    let sigma = max(0.05, 3.0 * strength * u.resolution.y / 600.0);
    let texel = axis / vec2f(textureDimensions(source));
    let radius = ceil(3.0 * sigma);
    var value = textureSampleLevel(source, linearSampler, uv, 0.0);
    var total = 1.0;
    // Cover every texel; widening a sparse kernel creates duplicate small moons.
    // Adjacent Gaussian taps are combined into one linear-filtered sample.
    for (var i = 1.0; i <= radius; i += 2.0) {
        let a = exp(-0.5 * i * i / (sigma * sigma));
        let j = i + 1.0;
        let b = select(0.0, exp(-0.5 * j * j / (sigma * sigma)), j <= radius);
        let weight = a + b;
        let offset = texel * (i + b / max(weight, 0.0000001));
        value += (textureSampleLevel(source, linearSampler, uv + offset, 0.0)
                + textureSampleLevel(source, linearSampler, uv - offset, 0.0)) * weight;
        total += 2.0 * weight;
    }
    return value / total;
}
@fragment fn horizontalFS(input: Output) -> @location(0) vec4f {
    return filtered(input.uv, vec2f(1.0, 0.0));
}
@fragment fn compositeFS(input: Output) -> @location(0) vec4f {
    let value = filtered(input.uv, vec2f(0.0, 1.0));
    if (value.a < 0.0001) { discard; }
    return vec4f(value.rgb / max(value.a, 0.0001), value.a);
}
