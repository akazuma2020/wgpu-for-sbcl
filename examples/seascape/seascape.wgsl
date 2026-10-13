/*
 * "Seascape" by Alexander Alekseev aka TDM - 2014
 * License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
 *
 * WebGPU/WGSL port based only on the supplied orig.glsl.txt.
 * iMouse.x is treated as 0.0 because the uniform layout supplies resolution and time only.
 */

struct Uniforms {
    iResolution: vec2f,
    iTime: f32,
    _padding: f32,
};

@group(0) @binding(0)
var<uniform> uniforms: Uniforms;

const NUM_STEPS: i32 = 32;
const PI: f32 = 3.141592;
const EPSILON: f32 = 1e-3;

const ITER_GEOMETRY: i32 = 3;
const ITER_FRAGMENT: i32 = 5;
const SEA_HEIGHT: f32 = 0.6;
const SEA_CHOPPY: f32 = 4.0;
const SEA_SPEED: f32 = 0.8;
const SEA_FREQ: f32 = 0.16;
const SEA_BASE: vec3f = vec3f(0.0, 0.09, 0.18);
const SEA_WATER_COLOR: vec3f = vec3f(0.8, 0.9, 0.6) * 0.6;
const octave_m: mat2x2f = mat2x2f(1.6, 1.2, -1.2, 1.6);

fn fromEuler(ang: vec3f) -> mat3x3f {
    let a1 = vec2f(sin(ang.x), cos(ang.x));
    let a2 = vec2f(sin(ang.y), cos(ang.y));
    let a3 = vec2f(sin(ang.z), cos(ang.z));

    return mat3x3f(
        vec3f(
            a1.y * a3.y + a1.x * a2.x * a3.x,
            a1.y * a2.x * a3.x + a3.y * a1.x,
            -a2.y * a3.x
        ),
        vec3f(-a2.y * a1.x, a1.y * a2.y, a2.x),
        vec3f(
            a3.y * a1.x * a2.x + a1.y * a3.x,
            a1.x * a3.x - a1.y * a3.y * a2.x,
            a2.y * a3.y
        )
    );
}

fn hash(p: vec2f) -> f32 {
    let h = dot(p, vec2f(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

fn noise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);

    return -1.0 + 2.0 * mix(
        mix(
            hash(i + vec2f(0.0, 0.0)),
            hash(i + vec2f(1.0, 0.0)),
            u.x
        ),
        mix(
            hash(i + vec2f(0.0, 1.0)),
            hash(i + vec2f(1.0, 1.0)),
            u.x
        ),
        u.y
    );
}

fn diffuse(n: vec3f, l: vec3f, p: f32) -> f32 {
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

fn specular(n: vec3f, l: vec3f, e: vec3f, s: f32) -> f32 {
    let nrm = (s + 8.0) / (PI * 8.0);
    return pow(max(dot(reflect(e, n), l), 0.0), s) * nrm;
}

fn getSkyColor(input_e: vec3f) -> vec3f {
    var e = input_e;
    e.y = (max(e.y, 0.0) * 0.8 + 0.2) * 0.8;

    return vec3f(
        pow(1.0 - e.y, 2.0),
        1.0 - e.y,
        0.6 + (1.0 - e.y) * 0.4
    ) * 1.1;
}

fn sea_octave(input_uv: vec2f, choppy: f32) -> f32 {
    var uv = input_uv;
    uv += noise(uv);

    var wv = 1.0 - abs(sin(uv));
    let swv = abs(cos(uv));
    wv = mix(wv, swv, wv);

    return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

fn map(p: vec3f) -> f32 {
    var freq = SEA_FREQ;
    var amp = SEA_HEIGHT;
    var choppy = SEA_CHOPPY;
    var uv = p.xz;
    uv.x *= 0.75;

    var h = 0.0;
    let sea_time = 1.0 + uniforms.iTime * SEA_SPEED;

    for (var i = 0; i < ITER_GEOMETRY; i++) {
        var d = sea_octave((uv + sea_time) * freq, choppy);
        d += sea_octave((uv - sea_time) * freq, choppy);
        h += d * amp;
        uv *= octave_m;
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }

    return p.y - h;
}

fn map_detailed(p: vec3f) -> f32 {
    var freq = SEA_FREQ;
    var amp = SEA_HEIGHT;
    var choppy = SEA_CHOPPY;
    var uv = p.xz;
    uv.x *= 0.75;

    var h = 0.0;
    let sea_time = 1.0 + uniforms.iTime * SEA_SPEED;

    for (var i = 0; i < ITER_FRAGMENT; i++) {
        var d = sea_octave((uv + sea_time) * freq, choppy);
        d += sea_octave((uv - sea_time) * freq, choppy);
        h += d * amp;
        uv *= octave_m;
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }

    return p.y - h;
}

fn getSeaColor(
    p: vec3f,
    n: vec3f,
    l: vec3f,
    eye: vec3f,
    dist: vec3f
) -> vec3f {
    var fresnel = clamp(1.0 - dot(n, -eye), 0.0, 1.0);
    fresnel = min(fresnel * fresnel * fresnel, 0.5);

    let reflected = getSkyColor(reflect(eye, n));
    let refracted = SEA_BASE +
        diffuse(n, l, 80.0) * SEA_WATER_COLOR * 0.12;

    var color = mix(refracted, reflected, fresnel);

    let dist_squared = dot(dist, dist);
    let atten = max(1.0 - dist_squared * 0.001, 0.0);
    color += SEA_WATER_COLOR * (p.y - SEA_HEIGHT) * 0.18 * atten;
    color += vec3f(
        specular(n, l, eye, 600.0 * inverseSqrt(dist_squared))
    );

    return color;
}

fn getNormal(p: vec3f, eps: f32) -> vec3f {
    var n: vec3f;
    n.y = map_detailed(p);
    n.x = map_detailed(vec3f(p.x + eps, p.y, p.z)) - n.y;
    n.z = map_detailed(vec3f(p.x, p.y, p.z + eps)) - n.y;
    n.y = eps;

    return normalize(n);
}

fn heightMapTracing(ori: vec3f, dir: vec3f) -> vec3f {
    var tm = 0.0;
    var tx = 1000.0;
    var hx = map(ori + dir * tx);

    if (hx > 0.0) {
        return ori + dir * tx;
    }

    var hm = map(ori);
    var p = ori;

    for (var i = 0; i < NUM_STEPS; i++) {
        let tmid = mix(tm, tx, hm / (hm - hx));
        p = ori + dir * tmid;
        let hmid = map(p);

        if (hmid < 0.0) {
            tx = tmid;
            hx = hmid;
        } else {
            tm = tmid;
            hm = hmid;
        }

        if (abs(hmid) < EPSILON) {
            break;
        }
    }

    return p;
}

fn getPixel(coord: vec2f, time: f32) -> vec3f {
    var uv = coord / uniforms.iResolution;
    uv = uv * 2.0 - 1.0;
    uv.x *= uniforms.iResolution.x / uniforms.iResolution.y;

    let ang = vec3f(
        sin(time * 3.0) * 0.1,
        sin(time) * 0.2 + 0.3,
        time
    );
    let ori = vec3f(0.0, 3.5, time * 5.0);

    var dir = normalize(vec3f(uv, -2.0));
    dir.z += length(uv) * 0.14;
    dir = normalize(dir) * fromEuler(ang);

    let traced_p = heightMapTracing(ori, dir);
    // let traced_p = floor(heightMapTracing(ori, dir) * 1024.0) / 1024.0; // for wsl + wgpu_native + d3d12

    let dist = traced_p - ori;
    let epsilon_nrm = 0.1 / uniforms.iResolution.x;
    let n = getNormal(traced_p, dot(dist, dist) * epsilon_nrm);
    let light = normalize(vec3f(0.0, 1.0, 0.8));

    return mix(
        getSkyColor(dir),
        getSeaColor(traced_p, n, light, dir, dist),
        pow(smoothstep(0.0, -0.02, dir.y), 0.2)
    );
}

@vertex
fn vsMain(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
    let positions = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f(3.0, -1.0),
        vec2f(-1.0, 3.0)
    );

    return vec4f(positions[vertex_index], 0.0, 1.0);
}

@fragment
fn fsMain(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let frag_coord = vec2f(
        position.x,
        uniforms.iResolution.y - position.y
    );

    // The supplied JavaScript has no iMouse uniform, so iMouse.x is 0.0.
    let time = uniforms.iTime * 0.3;
    let color = getPixel(frag_coord, time);

    return vec4f(pow(color, vec3f(0.65)), 1.0);
}
