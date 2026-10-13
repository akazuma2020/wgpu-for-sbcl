struct TourUniforms {
    resolution: vec2f,
    time: f32,
    sceneTime: f32,
    warp: f32,
    destination: u32,
    yaw: f32,
    pitch: f32,
    roll: f32,
    thrust: f32,
    progress: f32,
    warpPhase: f32,
    randomSeed: f32,
    showOrbit: u32,
    topView: u32,
};

@group(0) @binding(0) var<uniform> u: TourUniforms;

const PI: f32 = 3.141592653589793;

fn rotate2(p: vec2f, angle: f32) -> vec2f {
    let c = cos(angle);
    let s = sin(angle);
    return vec2f(c * p.x - s * p.y, s * p.x + c * p.y);
}

fn cameraEquatorialPole() -> vec3f {
    // Match each rendered body's equator; Saturn has a tilted body and rings.
    return normalize(select(vec3f(0.0, 1.0, 0.0), SATURN_POLE, u.destination == 7u));
}

fn cameraEquatorialInitial() -> vec3f {
    let pole = cameraEquatorialPole();
    return normalize(vec3f(0.0, 0.0, -1.0) + pole * pole.z);
}

fn cameraPole() -> vec3f {
    // Tilt the whole orbital plane by 30 degrees; start above the equator.
    let tilt = radians(30.0);
    return cameraEquatorialPole() * cos(tilt) - cameraEquatorialInitial() * sin(tilt);
}

fn cameraRadial() -> vec3f {
    let pole = cameraPole();
    let tilt = radians(30.0);
    let initial = cameraEquatorialInitial() * cos(tilt) + cameraEquatorialPole() * sin(tilt);
    let tangent = cross(pole, initial);
    let angle = 2.0 * PI * u.progress + u.yaw;
    return initial * cos(angle) + tangent * sin(angle);
}

fn cameraDistance() -> f32 {
    if (u.topView != 0u && u.destination != 0u) {
        var radius = 1.0;
        if (u.destination == 4u) {
            let earthCenter = destinationCenter() + earthOffsetFromMoon();
            radius = length(earthCenter - sunWorldPosition());
        } else {
            let current = heliocentricPosition(u.destination);
            let sceneRadius = length(destinationCenter() - sunWorldPosition());
            let elements = orbitalElements(u.destination);
            radius = sceneRadius * elements.a * (1.0 + elements.e) / length(current);
        }
        // Vertical field of view is about 50 degrees.  Leave a margin for the
        // line width, eccentricity approximation and window aspect changes.
        return radius * 2.75;
    }
    return destinationRadius(u.destination) * select(6.0, 8.0, u.destination == 7u);
}

fn solarNorthPole() -> vec3f {
    // IAU solar north pole (J2000): RA 286.13 deg, Dec +63.87 deg,
    // converted to the shader's ecliptic/game axes.
    let ra = radians(286.13);
    let dec = radians(63.87);
    let equatorial = vec3f(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec));
    let eps = radians(23.43928);
    let ecliptic = vec3f(equatorial.x,
        equatorial.y * cos(eps) + equatorial.z * sin(eps),
        -equatorial.y * sin(eps) + equatorial.z * cos(eps));
    return normalize(vec3f(ecliptic.x, ecliptic.z, ecliptic.y));
}

fn topViewCenter() -> vec3f {
    return sunWorldPosition();
}

fn cameraPosition() -> vec3f {
    if (u.topView != 0u && u.destination != 0u) {
        return topViewCenter() + solarNorthPole() * cameraDistance();
    }
    return destinationCenter() + cameraRadial() * cameraDistance();
}

fn cameraRight() -> vec3f {
    if (u.topView != 0u && u.destination != 0u) {
        let forward = -solarNorthPole();
        return normalize(cross(vec3f(0.0, 0.0, 1.0), forward));
    }
    return normalize(cross(cameraPole(), -cameraRadial()));
}

fn cameraForward() -> vec3f {
    if (u.topView != 0u && u.destination != 0u) {
        return -solarNorthPole();
    }
    // W/S pitch the view around the camera's local right axis while the
    // automatic 30-degree orbit and A/D azimuth remain independent.
    let baseForward = -cameraRadial();
    return normalize(baseForward * cos(u.pitch) + cameraPole() * sin(u.pitch));
}

fn cameraUp() -> vec3f {
    if (u.topView != 0u && u.destination != 0u) {
        return normalize(cross(cameraForward(), cameraRight()));
    }
    let baseForward = -cameraRadial();
    return normalize(cameraPole() * cos(u.pitch) - baseForward * sin(u.pitch));
}

fn worldDirectionToView(direction: vec3f) -> vec3f {
    return vec3f(dot(direction, cameraRight()), dot(direction, cameraUp()),
                 dot(direction, cameraForward()));
}

fn viewDirectionToWorld(direction: vec3f) -> vec3f {
    return cameraRight() * direction.x + cameraUp() * direction.y
           + cameraForward() * direction.z;
}

fn worldToView(position: vec3f) -> vec3f {
    return worldDirectionToView(position - cameraPosition());
}

fn projectView(view: vec3f) -> vec4f {
    let aspect = u.resolution.x / max(u.resolution.y, 1.0);
    let focal = 2.1445069;
    let near = 0.1;
    // The Moon scene keeps the half-scale Earth-Moon ratio for the displayed
    // Earth orbit too, so its top view extends hundreds of thousands of units.
    let far = 400000.0;
    return vec4f(focal / aspect * view.x,
                 focal * view.y,
                 far / (far - near) * view.z - far * near / (far - near),
                 view.z);
}

fn hash31(p: vec3f) -> f32 {
    return fract(sin(dot(p, vec3f(127.1, 311.7, 74.7))) * 43758.5453123);
}

fn valueNoise(p: vec3f) -> f32 {
    let i = floor(p);
    let f0 = fract(p);
    let f = f0 * f0 * (3.0 - 2.0 * f0);
    let n000 = hash31(i + vec3f(0.0, 0.0, 0.0));
    let n100 = hash31(i + vec3f(1.0, 0.0, 0.0));
    let n010 = hash31(i + vec3f(0.0, 1.0, 0.0));
    let n110 = hash31(i + vec3f(1.0, 1.0, 0.0));
    let n001 = hash31(i + vec3f(0.0, 0.0, 1.0));
    let n101 = hash31(i + vec3f(1.0, 0.0, 1.0));
    let n011 = hash31(i + vec3f(0.0, 1.0, 1.0));
    let n111 = hash31(i + vec3f(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

fn fbm(p0: vec3f) -> f32 {
    var p = p0;
    var sum = 0.0;
    var amplitude = 0.5;
    for (var octave = 0; octave < 5; octave++) {
        sum += valueNoise(p) * amplitude;
        p = p * 2.03 + vec3f(17.1, 9.2, 13.7);
        amplitude *= 0.5;
    }
    return sum;
}

fn toneMap(color: vec3f) -> vec3f {
    let x = max(color, vec3f(0.0));
    let mapped = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    return pow(clamp(mapped, vec3f(0.0), vec3f(1.0)), vec3f(1.0 / 2.2));
}

// --------------------------------------------------------------------------
// CPU側で線形合同法を使って星の方向を生成し、球面格子状の並びを防ぐ。

struct StarOutput {
    @builtin(position) position: vec4f,
    @location(0) corner: vec2f,
    @location(1) brightness: f32,
    @location(2) temperature: f32,
};

@vertex
fn starVS(@location(0) direction: vec3f,
          @location(1) corner: vec2f,
          @location(2) size: f32,
          @location(3) temperature: f32) -> StarOutput {
    let view = worldDirectionToView(direction);
    var output: StarOutput;
    if (view.z <= 0.001) {
        output.position = vec4f(2.0, 2.0, 1.0, 1.0);
    } else {
        let aspect = u.resolution.x / max(u.resolution.y, 1.0);
        let projected = vec2f(2.1445069 / aspect * view.x / view.z,
                              2.1445069 * view.y / view.z);
        // 通常航行では一定速度で外へ流す。ワープ開始では星の先端を止めたまま
        // 軌跡を伸ばし、白幕の裏で切り替えた後は消失点へ収束させる。
        let emitted = size < 0.0;
        let starSize = abs(size);
        // 遠方の星は通常航行でほとんど視差がない。共通の投影基準を使い、
        // 開始と終了を対称にする（以前の進行度倍率では開始側が最大9倍長かった）。
        let cruiseCenter = projected;
        // 同じ長さの線形補間を時間反転で使い、開始と終了の見え方を揃える。
        let entry = clamp(u.warpPhase * 2.0, 0.0, 1.0);
        let exit = clamp((u.warpPhase - 0.5) * 2.0, 0.0, 1.0);
        // 開始側では星の先端を開始前の座標に保ち、尾だけを伸ばす。
        // 中央で白幕が画面を覆い、拡大後の星野へ切り替わる。
        let warpScale = select(1.0,
                               mix(5.5, 1.0, exit),
                               u.warpPhase >= 0.5);
        var center = cruiseCenter * warpScale;
        var emittedVisible = false;
        if (emitted) {
            // 開始側は終了側の時間反転とし、拡大率、航跡、星の数を一致させる。
            // 位相0では通常の星と重なり、外へ移動しながら尾が中央へ伸びる。
            emittedVisible = u.warpPhase > 0.0 && u.warpPhase < 0.5;
            center = cruiseCenter * mix(1.0, 5.5, entry);
        }
        let pixel = vec2f(2.0 / max(u.resolution.x, 1.0),
                           2.0 / max(u.resolution.y, 1.0));
        let centerLength = length(center);
        let radial = center / max(centerLength, 0.0001);
        let tangent = vec2f(-radial.y, radial.x);
        // 12角形で星を丸く描き、ワープ時だけローカル軸を放射方向へ向ける。
        let warpBlur = smoothstep(0.0, 0.65, u.warp);
        let transverseSpread = mix(1.0, 4.0, warpBlur);
        var offset = (tangent * corner.x * transverseSpread + radial * corner.y)
                     * pixel * starSize;
        // ワープ中は点をカメラ中央へ向かう長い航跡に広げる。
        // 以前のNDC延長量0.018では800x600画面で数ピクセルしかなかった。
        let streakLength = (0.12 + centerLength * 0.10 + starSize * 0.018) * 4.0
                           * u.warp * u.warp;
        if (emitted || u.warpPhase >= 0.5) {
            // 開始側と終了側で航跡形状を一致させる。船の後方へ現長の4倍、
            // 消失点側へ10分の1を伸ばし、先端の移動方向だけを反転する。
            let backwardLength = streakLength * 4.0;
            let forwardLength = streakLength * 0.1;
            let backward = max(corner.y, 0.0) * backwardLength;
            let forward = min(corner.y, 0.0) * forwardLength;
            offset += radial * (backward + forward);
        }
        let fixedHiddenForEntry = !emitted && u.warpPhase > 0.0
                                  && u.warpPhase < 0.5;
        if ((emitted && !emittedVisible) || fixedHiddenForEntry) {
            output.position = vec4f(2.0, 2.0, 1.0, 1.0);
        } else {
            output.position = vec4f(center + offset, 1.0, 1.0);
        }
    }
    output.corner = corner;
    output.brightness = abs(size);
    output.temperature = temperature;
    return output;
}

@fragment
fn starFS(input: StarOutput) -> @location(0) vec4f {
    let radius = length(input.corner);
    if (radius > 0.98) { discard; }
    let brightTier = smoothstep(2.35, 4.80, input.brightness);
    let microTier = smoothstep(0.58, 1.35, input.brightness);
    let warpBlur = smoothstep(0.0, 0.65, u.warp);
    let transverseSpread = mix(1.0, 4.0, warpBlur);
    // Keep the original luminous core width inside the expanded geometry.
    let coreRadius = length(vec2f(input.corner.x * transverseSpread, input.corner.y));
    let core = 1.0 - smoothstep(0.08, mix(0.64, 0.30, brightTier), coreRadius);
    // 明るい星の一部だけに、写真のような淡く広い光輪を付ける。
    // 大半の星は点のままにし、画面全体が粒で埋まるのを防ぐ。
    let halo = pow(max(1.0 - radius, 0.0), 2.8) * brightTier;
    // Soft transverse Gaussian, tapered along the streak and at its boundary.
    // The same star mesh supplies the glow; no extra fullscreen blur pass.
    let streakGlow = exp(-0.5 * pow(input.corner.x / 0.34, 2.0))
                     * pow(max(1.0 - input.corner.y * input.corner.y, 0.0), 1.5)
                     * (1.0 - smoothstep(0.70, 0.98, radius)) * warpBlur;
    let cool = vec3f(0.62, 0.78, 1.0);
    let warm = vec3f(1.0, 0.78, 0.52);
    let starColor = mix(cool, warm, input.temperature);
    let alpha = clamp((core * mix(0.13, 0.92, microTier)
                       + halo * 0.36
                       + streakGlow * mix(0.07, 0.22, microTier)) * 1.80, 0.0, 1.0);
    // Warp-only glow surrounds the crisp core; normal star rendering is unchanged.
    return vec4f(starColor, alpha);
}

// --------------------------------------------------------------------------
// 惑星と衛星のポリゴン描画。

fn destinationRadius(index: u32) -> f32 {
    switch index {
        case 0u: { return 3.20; }
        case 1u: { return 1.70; }
        case 2u: { return 2.35; }
        case 3u: { return 2.30; }
        case 4u: { return 1.95; }
        case 5u: { return 2.12; }
        case 6u: { return 3.18; }
        case 7u: { return 2.78; }
        case 8u: { return 2.52; }
        default: { return 2.52; }
    }
}

fn destinationCenter() -> vec3f {
    // The target stays fixed; only the camera travels around its equator.
    return vec3f(5.44, 0.70, 31.05);
}

// Named satellites: JPL SSD mean radii and mean orbital elements.
// Radius = 2 * real satellite/planet radius ratio.
// Orbital scale = 0.5 * real planet-centered distance, except Mimas/Enceladus (0.75).
struct Satellite {
    id: u32,
    radiusKm: f32,
    semimajorKm: f32,
    eccentricity: f32,
    inclinationDeg: f32,
    periodDays: f32,
    meanAnomalyDeg: f32,
    periapsisDeg: f32,
    nodeDeg: f32,
    poleRADeg: f32,
    poleDecDeg: f32,
    epochJD: f32,
};
const SATELLITES: array<Satellite, 13> = array<Satellite, 13>(
    // Phobos (IAU 401)
    Satellite(401u, 11.08, 9375.0, 0.015, 1.1, 0.3187, 189.7, 216.3, 169.2, 317.7, 52.9, 2451545.0),
    // Deimos (IAU 402)
    Satellite(402u, 6.2, 23457.0, 0.0, 1.8, 1.2625, 205.0, 0.0, 54.3, 316.6, 53.5, 2451545.0),
    // Io (IAU 501)
    Satellite(501u, 1821.49, 421800.0, 0.004, 0.0, 1.762732, 330.9, 49.1, 0.0, 268.1, 64.5, 2451545.0),
    // Europa (IAU 502)
    Satellite(502u, 1560.8, 671100.0, 0.009, 0.5, 3.525463, 345.4, 45.0, 184.0, 268.1, 64.5, 2451545.0),
    // Ganymede (IAU 503)
    Satellite(503u, 2631.2, 1070400.0, 0.001, 0.2, 7.155588, 324.8, 198.3, 58.5, 268.2, 64.6, 2451545.0),
    // Callisto (IAU 504)
    Satellite(504u, 2410.3, 1882700.0, 0.007, 0.3, 16.69044, 87.4, 43.8, 309.1, 268.7, 64.8, 2451545.0),
    // Titan (IAU 606)
    Satellite(606u, 2574.76, 1221900.0, 0.029, 0.3, 15.945448, 11.7, 78.3, 78.6, 36.4, 84.0, 2451545.0),
    // Enceladus (IAU 602)
    Satellite(602u, 252.1, 238400.0, 0.005, 0.0, 1.370218, 57.0, 119.5, 0.0, 40.6, 83.5, 2451545.0),
    // Mimas (IAU 601)
    Satellite(601u, 198.2, 186000.0, 0.02, 1.6, 0.942422, 275.3, 160.4, 66.2, 40.6, 83.5, 2451545.0),
    // Iapetus (IAU 608)
    Satellite(608u, 734.3, 3561700.0, 0.028, 7.6, 79.331002, 74.8, 254.5, 86.5, 288.7, 78.9, 2451545.0),
    // Triton (IAU 801)
    Satellite(801u, 1352.6, 354800.0, 0.0, 157.3, 5.876994, 63.0, 0.0, 178.1, 299.8, 43.1, 2451545.0),
    // Proteus (IAU 808)
    Satellite(808u, 208.0, 117600.0, 0.0, 0.0, 1.122315, 276.8, 0.0, 0.0, 299.8, 42.6, 2451545.0),
    // Nereid (IAU 802)
    Satellite(802u, 170.0, 5513900.0, 0.751, 5.1, 360.133039, 318.5, 296.8, 319.5, 0.0, 90.0, 2458849.5)
);

fn satelliteCount(body: u32) -> u32 {
    switch body {
        case 5u: { return 2u; }
        case 6u, 7u: { return 4u; }
        case 9u: { return 3u; }
        default: { return 0u; }
    }
}

fn satelliteData(body: u32, slot: u32) -> Satellite {
    var first = 0u;
    switch body {
        case 6u: { first = 2u; }
        case 7u: { first = 6u; }
        case 9u: { first = 10u; }
        default: {}
    }
    return SATELLITES[min(first + slot, 12u)];
}

fn planetEquatorialRadiusKm(body: u32) -> f32 {
    switch body {
        case 5u: { return 3396.19; }
        case 6u: { return 71492.0; }
        case 7u: { return 60268.0; }
        default: { return 24764.0; }
    }
}

fn satelliteRadius(body: u32, slot: u32) -> f32 {
    return destinationRadius(body) * 2.0 * satelliteData(body, slot).radiusKm
           / planetEquatorialRadiusKm(body);
}

// J2000 equatorial pole -> the same ecliptic game axes as heliocentricPositionAt.
fn satellitePole(data: Satellite) -> vec3f {
    let ra = radians(data.poleRADeg);
    let dec = radians(data.poleDecDeg);
    let equatorial = vec3f(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec));
    let eps = radians(23.43928);
    let ecliptic = vec3f(equatorial.x,
        equatorial.y * cos(eps) + equatorial.z * sin(eps),
        -equatorial.y * sin(eps) + equatorial.z * cos(eps));
    return normalize(vec3f(ecliptic.x, ecliptic.z, ecliptic.y));
}

fn satelliteOffset(body: u32, slot: u32) -> vec3f {
    let data = satelliteData(body, slot);
    // Split epoch subtraction to preserve elapsed seconds with f32 Julian dates.
    let days = (2461324.0 - data.epochJD) + u.time / 86400.0;
    let meanAnomaly = radians(data.meanAnomalyDeg)
        + fract(days / data.periodDays) * 2.0 * PI;
    var anomaly = meanAnomaly;
    for (var step = 0u; step < 12u; step += 1u) {
        anomaly -= (anomaly - data.eccentricity * sin(anomaly) - meanAnomaly)
                 / (1.0 - data.eccentricity * cos(anomaly));
    }
    let orbitScale = select(0.5, 0.75, data.id == 601u || data.id == 602u);
    let a = destinationRadius(body) * orbitScale * data.semimajorKm
            / planetEquatorialRadiusKm(body);
    var orbital = vec2f(a * (cos(anomaly) - data.eccentricity),
                        a * sqrt(1.0 - data.eccentricity * data.eccentricity) * sin(anomaly));
    orbital = rotate2(orbital, radians(data.periapsisDeg));
    let pole = satellitePole(data);
    // Ascending node reference is the J2000 equator; Nereid uses the ecliptic.
    var referencePole = vec3f(0.0, cos(radians(23.43928)), sin(radians(23.43928)));
    if (data.id == 802u) { referencePole = vec3f(0.0, 1.0, 0.0); }
    var basisX = cross(referencePole, pole);
    if (length(basisX) < 0.00001) { basisX = vec3f(1.0, 0.0, 0.0); }
    basisX = normalize(basisX);
    let basisZ = normalize(cross(basisX, pole));
    let node = radians(data.nodeDeg);
    let axisX = basisX * cos(node) + basisZ * sin(node);
    let along = -basisX * sin(node) + basisZ * cos(node);
    let axisZ = along * cos(radians(data.inclinationDeg))
                + pole * sin(radians(data.inclinationDeg));
    return axisX * orbital.x + axisZ * orbital.y;
}

fn satelliteSlot(instance: u32) -> u32 {
    return select(instance - 3u, 0u, instance == 1u);
}

fn isSatelliteInstance(instance: u32) -> bool {
    return instance == 1u || instance >= 4u;
}

// Earth's Moon retains its existing display dimensions and placement.
fn moonRadius(index: u32) -> f32 {
    return select(0.0, 0.34, index == 3u);
}

fn moonOffset(index: u32) -> vec3f {
    // Earth scene presentation distance: five times the original offset.
    return select(vec3f(0.0), vec3f(-15.75, 5.50, -1.25), index == 3u);
}

// Moon scene: body radii keep their mean-radius ratio; the Earth-Moon
// separation is compressed to half scale for the tour composition.
fn earthRadiusFromMoon() -> f32 {
    return destinationRadius(4u) * (6371.0 / 1737.4);
}

fn lunarOrbitNormal() -> vec3f {
    // Mean lunar orbit referred to the J2000 ecliptic.  In game coordinates
    // the ecliptic is XZ and +Y is ecliptic north.
    let inclination = radians(5.145);
    let ascendingNode = radians(125.08);
    let nodeAxis = vec3f(cos(ascendingNode), 0.0, sin(ascendingNode));
    let eclipticNorth = vec3f(0.0, 1.0, 0.0);
    return normalize(eclipticNorth * cos(inclination)
                     + cross(nodeAxis, eclipticNorth) * sin(inclination));
}

fn earthOffsetFromMoon() -> vec3f {
    // Preserve the established composition direction, but constrain the
    // Earth-Moon radial vector to the physical lunar orbital plane.
    let pole = lunarOrbitNormal();
    let previous = vec3f(-3.15, 1.10, -0.25);
    let direction = normalize(previous - pole * dot(previous, pole));
    return direction * destinationRadius(4u) * (384400.0 / 1737.4) * 0.5;
}

// JPLの惑星軌道要素の近似値（1800～2050年）。J2000平均黄道・春分点基準。
// 基準値と変化率はユリウス世紀単位。基準時刻は2026-10-10 12:00 UTC
// （JD 2461324.0）で、実経過秒を加えて実行中も方向を連続させる。
struct OrbitalElements {
    a: f32,
    e: f32,
    inclination: f32,
    longitude: f32,
    perihelion: f32,
    node: f32,
    aRate: f32,
    eRate: f32,
    inclinationRate: f32,
    longitudeRate: f32,
    perihelionRate: f32,
    nodeRate: f32,
};

fn orbitalElements(index: u32) -> OrbitalElements {
    switch index {
        case 1u: { return OrbitalElements(0.38709927, 0.20563593, 7.00497902,
            252.25032350, 77.45779628, 48.33076593, 0.00000037, 0.00001906,
            -0.00594749, 149472.67411175, 0.16047689, -0.12534081); }
        case 2u: { return OrbitalElements(0.72333566, 0.00677672, 3.39467605,
            181.97909950, 131.60246718, 76.67984255, 0.00000390, -0.00004107,
            -0.00078890, 58517.81538729, 0.00268329, -0.27769418); }
        case 3u, 4u: { return OrbitalElements(1.00000261, 0.01671123, -0.00001531,
            100.46457166, 102.93768193, 0.0, 0.00000562, -0.00004392,
            -0.01294668, 35999.37244981, 0.32327364, 0.0); }
        case 5u: { return OrbitalElements(1.52371034, 0.09339410, 1.84969142,
            -4.55343205, -23.94362959, 49.55953891, 0.00001847, 0.00007882,
            -0.00813131, 19140.30268499, 0.44441088, -0.29257343); }
        case 6u: { return OrbitalElements(5.20288700, 0.04838624, 1.30439695,
            34.39644051, 14.72847983, 100.47390909, -0.00011607, -0.00013253,
            -0.00183714, 3034.74612775, 0.21252668, 0.20469106); }
        case 7u: { return OrbitalElements(9.53667594, 0.05386179, 2.48599187,
            49.95424423, 92.59887831, 113.66242448, -0.00125060, -0.00050991,
            0.00193609, 1222.49362201, -0.41897216, -0.28867794); }
        case 8u: { return OrbitalElements(19.18916464, 0.04725744, 0.77263783,
            313.23810451, 170.95427630, 74.01692503, -0.00196176, -0.00004397,
            -0.00242939, 428.48202785, 0.40805281, 0.04240589); }
        default: { return OrbitalElements(30.06992276, 0.00859048, 1.77004347,
            -55.12002969, 44.96476227, 131.78422574, 0.00026291, 0.00005105,
            0.00035372, 218.45945325, -0.32241464, -0.00508664); }
    }
}

fn heliocentricPositionAt(index: u32, orbitFraction: f32) -> vec3f {
    let elements = orbitalElements(index);
    let centuries = 0.2677344285 + u.time / 3155760000.0;
    let a = elements.a + elements.aRate * centuries;
    let e = elements.e + elements.eRate * centuries;
    let inclination = radians(elements.inclination
                              + elements.inclinationRate * centuries);
    let longitude = radians(elements.longitude + elements.longitudeRate * centuries);
    let perihelion = radians(elements.perihelion
                             + elements.perihelionRate * centuries);
    let node = radians(elements.node + elements.nodeRate * centuries);
    let meanAnomaly = longitude - perihelion;
    var eccentricAnomaly = meanAnomaly + e * sin(meanAnomaly);
    for (var iteration = 0; iteration < 6; iteration++) {
        eccentricAnomaly -= (eccentricAnomaly - e * sin(eccentricAnomaly)
                             - meanAnomaly)
                            / (1.0 - e * cos(eccentricAnomaly));
    }
    if (orbitFraction >= 0.0) { eccentricAnomaly = orbitFraction * 2.0 * PI; }
    let orbitalX = a * (cos(eccentricAnomaly) - e);
    let orbitalY = a * sqrt(1.0 - e * e) * sin(eccentricAnomaly);
    let omega = perihelion - node;
    let cosOmega = cos(omega);
    let sinOmega = sin(omega);
    let cosNode = cos(node);
    let sinNode = sin(node);
    let cosInclination = cos(inclination);
    let sinInclination = sin(inclination);
    let eclipticX = (cosOmega * cosNode - sinOmega * sinNode * cosInclination)
                    * orbitalX
                    + (-sinOmega * cosNode - cosOmega * sinNode * cosInclination)
                    * orbitalY;
    let eclipticY = (cosOmega * sinNode + sinOmega * cosNode * cosInclination)
                    * orbitalX
                    + (-sinOmega * sinNode + cosOmega * cosNode * cosInclination)
                    * orbitalY;
    let eclipticZ = sinOmega * sinInclination * orbitalX
                    + cosOmega * sinInclination * orbitalY;
    // ゲーム座標ではYを上、Zを前方とする。
    return vec3f(eclipticX, eclipticZ, eclipticY);
}

fn heliocentricPosition(index: u32) -> vec3f {
    return heliocentricPositionAt(index, -1.0);
}

fn moonSceneOrbitNormal() -> vec3f {
    return lunarOrbitNormal();
}

// Rotate the orbit's radial axis onto the scaled scene's Sun-to-planet axis.
// This keeps both the displayed Sun and the visited body on the same ellipse.
fn orbitScenePosition(fraction: f32, track: u32) -> vec3f {
    if (u.destination == 4u && track == 0u) {
        // The Moon orbits the Earth displayed in this scene, not the Sun.
        let earthCenter = destinationCenter() + earthOffsetFromMoon();
        let radial = destinationCenter() - earthCenter;
        let tangent = normalize(cross(moonSceneOrbitNormal(), radial)) * length(radial);
        let angle = fraction * 2.0 * PI;
        return earthCenter + radial * cos(angle) + tangent * sin(angle);
    }
    // Track 1 in the Moon scene falls through to the same J2000 ecliptic
    // calculation as Earth's normal heliocentric orbit.  It must not inherit
    // the presentation plane used for the Moon's planet-centred orbit.
    let body = select(u.destination, 3u, u.destination == 4u);
    let center = destinationCenter()
        + select(vec3f(0.0), earthOffsetFromMoon(), u.destination == 4u);
    let current = heliocentricPosition(body);
    let originalAxis = normalize(current);
    let sceneRadial = center - sunWorldPosition();
    let sceneAxis = normalize(sceneRadial);
    let p = heliocentricPositionAt(body, fraction);
    let v = cross(originalAxis, sceneAxis);
    let c = dot(originalAxis, sceneAxis);
    var rotated = p;
    if (c > -0.9999) {
        rotated = p + cross(v, p) + cross(v, cross(v, p)) / (1.0 + c);
    } else {
        let reference = select(vec3f(0.0, 1.0, 0.0), vec3f(1.0, 0.0, 0.0),
                               abs(originalAxis.y) > 0.9);
        let axis = normalize(cross(originalAxis, reference));
        rotated = 2.0 * axis * dot(axis, p) - p;
    }
    return sunWorldPosition() + rotated * length(sceneRadial) / length(current);
}

struct OrbitOutput {
    @builtin(position) position: vec4f,
    @location(0) side: f32,
};

@vertex
fn orbitVS(@builtin(vertex_index) vertex: u32) -> OrbitOutput {
    var output: OrbitOutput;
    output.position = vec4f(2.0, 2.0, 1.0, 1.0);
    output.side = 0.0;
    if ((u.showOrbit == 0u && u.topView == 0u) || u.destination == 0u) { return output; }
    let track = vertex / (512u * 6u);
    if (track > 0u && u.destination != 4u) { return output; }
    let segment = (vertex / 6u) % 512u;
    let corner = vertex % 6u;
    var a = worldToView(orbitScenePosition(f32(segment) / 512.0, track));
    var b = worldToView(orbitScenePosition(f32(segment + 1u) / 512.0, track));
    if (a.z <= 0.12 && b.z <= 0.12) { return output; }
    let originalA = a;
    let originalB = b;
    if (originalA.z < 0.12) {
        a = mix(originalA, originalB,
                (0.12 - originalA.z) / (originalB.z - originalA.z));
    }
    if (originalB.z < 0.12) {
        b = mix(originalB, originalA,
                (0.12 - originalB.z) / (originalA.z - originalB.z));
    }
    let clipA = projectView(a);
    let clipB = projectView(b);
    let delta = (clipB.xy / clipB.w - clipA.xy / clipA.w) * u.resolution;
    let perpendicular = vec2f(-delta.y, delta.x) / max(length(delta), 0.00001);
    let end = corner == 2u || corner == 4u || corner == 5u;
    let side = select(-1.0, 1.0, corner == 1u || corner == 3u || corner == 5u);
    var clip = select(clipA, clipB, end);
    clip = vec4f(clip.xy + perpendicular * side * 2.4 / u.resolution * clip.w,
                 clip.z, clip.w);
    output.position = clip;
    output.side = side;
    return output;
}

@fragment
fn orbitFS(input: OrbitOutput) -> @location(0) vec4f {
    let alpha = (1.0 - smoothstep(0.30, 1.0, abs(input.side))) * 0.38;
    return vec4f(0.32, 0.66, 0.82, alpha);
}

// --------------------------------------------------------------------------
// 星の間が真っ黒な平面に見えないよう、銀河の淡い光、雲状の濃淡、
// 途切れた吸収帯を遠景に加える。

struct SpaceOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
};

@vertex
fn spaceVS(@location(0) position: vec2f) -> SpaceOutput {
    var output: SpaceOutput;
    output.position = vec4f(position, 1.0, 1.0);
    output.uv = position * 0.5 + vec2f(0.5);
    return output;
}

struct ProminenceMotion {
    start: vec3f,
    tangent: vec3f,
    arcAngle: f32,
    height: f32,
    shapeSeed: f32,
    cycle: f32,
    secondsAfterLanding: f32,
}

fn prominencePathRandom(index: f32, seed: f32) -> f32 {
    return fract(sin(index * 127.1 + seed * 311.7) * 43758.5453) * 2.0 - 1.0;
}

fn prominencePathNoise(path: f32, seed: f32) -> f32 {
    let scaled = clamp(path, 0.0, 1.0) * 20.0;
    let index = floor(scaled);
    let fraction = fract(scaled);
    // Cubic B-spline filtering retains the event's random control points,
    // without forcing the curve through every abrupt random extremum.
    let t = fraction;
    let t2 = t * t;
    let t3 = t2 * t;
    return (prominencePathRandom(index - 1.0, seed) * pow(1.0 - t, 3.0)
          + prominencePathRandom(index, seed) * (3.0 * t3 - 6.0 * t2 + 4.0)
          + prominencePathRandom(index + 1.0, seed) * (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0)
          + prominencePathRandom(index + 2.0, seed) * t3) / 6.0;
}

fn parabolaArcPrimitive(value: f32) -> f32 {
    let absoluteValue = abs(value);
    let root = sqrt(1.0 + value * value);
    let inverseHyperbolicSine = sign(value) * log(absoluteValue + root);
    return 0.5 * (value * root + inverseHyperbolicSine);
}

fn uniformParabolaParameter(timeProgress: f32, height: f32,
                            arcAngle: f32) -> f32 {
    let progress = clamp(timeProgress, 0.0, 1.0);
    if (height <= 0.0001) {
        return progress;
    }
    // 放物線の弧長を解析式で反転し、等しい時間で等しい距離だけ進める。
    let horizontalScale = max(arcAngle * (1.0 + height * 0.6666667), 0.001);
    let slopeScale = 4.0 * height / horizontalScale;
    let targetPrimitive = parabolaArcPrimitive(slopeScale) * (1.0 - 2.0 * progress);
    var slope = slopeScale * (1.0 - 2.0 * progress);
    for (var iteration = 0u; iteration < 2u; iteration += 1u) {
        let error = parabolaArcPrimitive(slope) - targetPrimitive;
        slope -= error / sqrt(1.0 + slope * slope);
    }
    return clamp(0.5 * (1.0 - slope / slopeScale), 0.0, 1.0);
}

fn makeProminenceMotion(event: u32, generation: u32) -> ProminenceMotion {
    // 発生時刻をイベントごとにランダム化する。
    let period = 15.0;
    // 15秒周期に0〜5秒の個別オフセットを加え、隣り合う間隔を10〜20秒にする。
    let eventIndex = floor(u.time / period) - f32(generation);
    let timingSeed = u.randomSeed * 0.013 + eventIndex * 73.17
                     + f32(event) * 19.19 + 11.7;
    let randomTiming = fract(sin(timingSeed) * 43758.5453) / 3.0;
    let eventStartTime = (eventIndex + randomTiming) * period;
    let eventAge = max(u.time - eventStartTime, 0.0);
    // 飛行時間は通常周期64秒で使っていた時間軸を維持する。
    let cycle = eventAge / 64.0;
    let seed = u.randomSeed * 0.017 + eventIndex * 127.1
               + f32(event) * 311.7 + 43.7;
    let randomA = fract(sin(seed) * 43758.5453);
    let randomB = fract(sin(seed + 19.19) * 24634.6345);
    let randomC = fract(sin(seed + 71.73) * 56445.2341);
    let randomD = fract(sin(seed + 137.37) * 19341.417);
    let randomE = fract(sin(seed + 219.91) * 32817.231);


    let y = randomA * 2.0 - 1.0;
    let azimuth = randomB * 2.0 * PI;
    let horizontal = sqrt(max(1.0 - y * y, 0.0));
    let start = vec3f(horizontal * cos(azimuth), y, horizontal * sin(azimuth));
    let reference = select(vec3f(0.0, 1.0, 0.0), vec3f(1.0, 0.0, 0.0), abs(y) > 0.92);
    let basisA = normalize(cross(reference, start));
    let basisB = normalize(cross(start, basisA));
    let tangentAngle = randomC * 2.0 * PI;
    let tangent = normalize(basisA * cos(tangentAngle) + basisB * sin(tangentAngle));
    var output: ProminenceMotion;
    output.start = start;
    output.tangent = tangent;
    // 1.5 times the original angular travel (0.08625..0.255 radians).

    output.arcAngle = (0.2275 + (randomD - 0.5) * 0.225) * 0.75;

    // Two thirds of the previous height (about 0.02133..0.36267 solar radii).
    output.height = max(0.04, 0.32 + (randomE - 0.5) * 0.72) * (0.8 * 2.0 / 3.0);
    output.shapeSeed = fract(seed * 0.1031) * 1000.0;
    output.cycle = cycle;
    // 残光の減衰時計も運動時計に合わせて半速で進める。
    output.secondsAfterLanding = max(cycle - 0.17, 0.0) * 16.0;
    return output;
}

fn prominenceWorldPosition(path: f32, motion: ProminenceMotion, center: vec3f,
                           radius: f32, spinAngle: f32) -> vec3f {
    let curveProgress = uniformParabolaParameter(
        path, motion.height, motion.arcAngle);
    let angle = motion.arcAngle * curveProgress;
    let surfaceDirection = normalize(motion.start * cos(angle) + motion.tangent * sin(angle));
    // イベントごとの高さを持つ放物線を基調に、時間間隔の等しい小さな方向変化を重ねる。
    let height = 4.0 * motion.height * curveProgress * (1.0 - curveProgress);
    let smallBends = (prominencePathNoise(path, motion.shapeSeed)
                      - prominencePathNoise(0.0, motion.shapeSeed)) * 0.028;

    let side = normalize(cross(surfaceDirection, motion.tangent));
    let local = surfaceDirection * (1.0 + height)
                + side * smallBends;
    let rotated = rotate2(local.xz, spinAngle);
    return center + vec3f(rotated.x, local.y, rotated.y) * radius;
}

fn raySegmentDistance(rayDirection: vec3f, start: vec3f,
                      end: vec3f) -> vec2f {
    let segment = end - start;
    let segmentLength2 = max(dot(segment, segment), 0.000001);
    var bestAlong = 0.0;
    let startRayAlong = max(dot(start, rayDirection), 0.0);
    var bestDistance2 = dot(start - rayDirection * startRayAlong,
                            start - rayDirection * startRayAlong);

    // 線分両端と、視点原点に最も近い線分上の点を候補にする。
    let endRayAlong = max(dot(end, rayDirection), 0.0);
    let endDelta = end - rayDirection * endRayAlong;
    let endDistance2 = dot(endDelta, endDelta);
    if (endDistance2 < bestDistance2) {
        bestDistance2 = endDistance2;
        bestAlong = 1.0;
    }
    let originAlong = clamp(-dot(segment, start) / segmentLength2, 0.0, 1.0);
    let originPoint = mix(start, end, originAlong);
    let originDistance2 = dot(originPoint, originPoint);
    if (originDistance2 < bestDistance2) {
        bestDistance2 = originDistance2;
        bestAlong = originAlong;
    }

    // 直線同士の解は、前方の半直線と線分の内側にある場合だけ採用する。
    // ほぼ平行なら除算せず、上記の境界候補から最短値を選ぶ。
    let raySegment = dot(rayDirection, segment);
    let denominator = segmentLength2 - raySegment * raySegment;
    if (denominator > segmentLength2 * 0.00001) {
        let lineAlong = (raySegment * dot(rayDirection, start)
                         - dot(segment, start)) / denominator;
        if (lineAlong >= 0.0 && lineAlong <= 1.0) {
            let linePoint = mix(start, end, lineAlong);
            let lineRayAlong = dot(linePoint, rayDirection);
            if (lineRayAlong >= 0.0) {
                let lineDelta = linePoint - rayDirection * lineRayAlong;
                let lineDistance2 = dot(lineDelta, lineDelta);
                if (lineDistance2 < bestDistance2) {
                    bestDistance2 = lineDistance2;
                    bestAlong = lineAlong;
                }
            }
        }
    }
    return vec2f(sqrt(bestDistance2), bestAlong);
}

// Shared source for the visible Sun and every direct-light calculation.
fn sunWorldPosition() -> vec3f {
    if (u.destination == 0u) { return destinationCenter(); }
    if (u.destination == 4u) {
        // Presentation scale: keep the Sun safely outside the lunar orbit,
        // while retaining enough separation to see Earth and Moon together in
        // the full-orbit top view.  Align the direction with Earth's actual
        // heliocentric vector so its J2000 orbital plane stays intact.
        let earthCenter = destinationCenter() + earthOffsetFromMoon();
        let distance = length(earthOffsetFromMoon()) * 6.0;
        return earthCenter + normalize(-heliocentricPosition(3u)) * distance;
    }
    return normalize(-heliocentricPosition(u.destination)) * 24.0;
}

fn sunWorldRadius() -> f32 {
    if (u.destination == 0u) { return destinationRadius(0u); }
    let distanceAu = max(length(heliocentricPosition(u.destination)), 0.01);
    return clamp(0.1116 / distanceAu, 0.035, 0.285);
}

fn solarDirection(worldPosition: vec3f) -> vec3f {
    let delta = sunWorldPosition() - worldPosition;
    return delta / max(length(delta), 0.00001);
}

fn prominenceEvent(rayDirection: vec3f, center: vec3f, radius: f32,
                   spinAngle: f32, surfaceDepth: f32,
                   overlayOnSurface: bool) -> vec3f {
    var color = vec3f(0.0);
    let launchTime = 0.0175;
    let landingTime = 0.17;
    let trailWidth = radius * 0.034;
    // Keep the tour's staggered births and lifetime; use the test's 20-segment
    // noisy path and luminous-capsule union in camera coordinates.
    for (var generation = 0u; generation < 3u; generation += 1u) {
        let motion = makeProminenceMotion(0u, generation);
        if (motion.cycle < launchTime || motion.cycle >= 0.50) {
            continue;
        }
        let growth = clamp((motion.cycle - launchTime)
                           / (landingTime - launchTime), 0.0, 1.0);
        let trailExtent = smoothstep(0.0, 1.0, growth);
        let phase = clamp((motion.cycle - launchTime) / (0.50 - launchTime), 0.0, 1.0);
        let fadeProgress = smoothstep(0.42, 1.0, phase);
        let originWorld = prominenceWorldPosition(0.0, motion, center, radius, spinAngle);
        let tipWorld = prominenceWorldPosition(trailExtent, motion, center, radius, spinAngle);
        let emergence = smoothstep(0.0, trailWidth, distance(originWorld, tipWorld));
        var emission = vec3f(0.0);
        var previousView = worldToView(originWorld);
        for (var segmentIndex = 0u; segmentIndex < 20u; segmentIndex += 1u) {
            let s0 = trailExtent * f32(segmentIndex) / 20.0;
            let s1 = trailExtent * f32(segmentIndex + 1u) / 20.0;
            let nextView = worldToView(prominenceWorldPosition(
                s1, motion, center, radius, spinAngle));
            if (previousView.z > 0.1 && nextView.z > 0.1) {
                let closest = raySegmentDistance(rayDirection, previousView, nextView);
                let path = mix(s0, s1, closest.y);
                var visibility = 1.0;
                if (overlayOnSurface) {
                    let segmentDepth = mix(previousView.z, nextView.z, closest.y);
                    visibility = smoothstep(-trailWidth, trailWidth,
                                            surfaceDepth - segmentDepth);
                }
                let bulge = 0.72 + 0.48 * sin(PI * clamp(path, 0.0, 1.0));
                let width = trailWidth * bulge;
                let core = exp(-0.5 * pow(closest.x / (width * 0.72), 2.0)) * 0.81;
                let glow = exp(-0.5 * pow(closest.x / (width * 1.5), 2.0));
                let bloom = exp(-0.5 * pow(closest.x / (width * 2.5), 2.0));
                let fadeFront = fadeProgress * 1.20;
                let fade = select(1.0, smoothstep(fadeFront - 0.10,
                                                fadeFront + 0.10, path),
                                  fadeProgress > 0.0);
                let segmentEmission = vec3f(1.0, 0.34, 0.055)
                    * (core + glow * 0.72 + bloom * 0.48) * fade * visibility;
                emission = max(emission, segmentEmission);
            }
            previousView = nextView;
        }
        color += emission * emergence;
    }
    return color;
}
@fragment
fn spaceFS(input: SpaceOutput) -> @location(0) vec4f {
    let ndc = input.uv * 2.0 - vec2f(1.0);
    let aspect = u.resolution.x / max(u.resolution.y, 1.0);
    let viewRay = normalize(vec3f(ndc.x * aspect / 2.1445069,
                                  ndc.y / 2.1445069, 1.0));
    let direction = normalize(viewDirectionToWorld(viewRay));

    // CPU側の星表と同じ0.55ラジアン傾いた極を使い、星の密度と
    // 拡散した天の川の位置を一致させる。
    let galacticPole = normalize(vec3f(-sin(0.55), cos(0.55), 0.0));
    let latitude = abs(dot(direction, galacticPole));
    let broadBand = 1.0 - smoothstep(0.035, 0.34, latitude);
    let denseBand = 1.0 - smoothstep(0.008, 0.115, latitude);
    let largeCloud = fbm(direction * 2.4 + vec3f(8.1, 17.7, 3.4));
    let fineCloud = fbm(direction * 8.5 + vec3f(31.0, 4.0, 19.0));
    let cloud = smoothstep(0.31, 0.76, largeCloud * 0.72 + fineCloud * 0.28);

    // 空全体に広がる雲状成分で、以前のツアーの濃紺背景を再現する。
    // 天の川帯より広く、黒い宇宙空間が主役になる濃さに抑える。
    let deepVolume = fbm(direction * 1.18 + vec3f(4.7, 23.0, 12.6));
    let middleVolume = fbm(direction * 3.9 + vec3f(37.0, 6.2, 14.0));
    let blueNebula = smoothstep(0.43, 0.70,
        deepVolume * 0.78 + middleVolume * 0.22);
    let wisps = smoothstep(0.48, 0.72, middleVolume)
                * smoothstep(0.36, 0.62, deepVolume);

    // 中央の暗黒帯を幾何学的な直線ではなく、途切れた模様にする。
    // 背景光を弱めるが、完全な黒にはしない。
    let dustShape = 1.0 - smoothstep(0.006, 0.050 + largeCloud * 0.028, latitude);
    let dustBreakup = smoothstep(0.34, 0.67,
        fbm(direction * 13.0 + vec3f(2.0, 41.0, 7.0)));
    let dust = dustShape * mix(0.38, 0.88, dustBreakup);

    var color = vec3f(0.00032, 0.00062, 0.0021);
    color += vec3f(0.0024, 0.0058, 0.0180) * blueNebula;
    color += vec3f(0.0020, 0.0035, 0.0120) * wisps;
    // 銀河面は星や雲の密度に反映し、塗りつぶした帯にはしない。
    // 見える構造の大半は上記の広い雲状成分が担う。
    color += vec3f(0.006, 0.009, 0.019) * broadBand * (0.30 + cloud * 0.70);
    color += vec3f(0.011, 0.010, 0.020) * denseBand * cloud * 0.58;
    color *= 1.0 - dust * 0.78;

    // 太陽全体の静的な滲みを描く。外縁を揺らす時間変化は加えない。
    let sunWorld = sunWorldPosition();
    let sunRadius = sunWorldRadius();
    let sunView = worldToView(sunWorld);
    if (sunView.z > 0.1) {
        let sunCenter = vec2f(2.1445069 / aspect * sunView.x / sunView.z,
                              2.1445069 * sunView.y / sunView.z);
        let minimumRadius = 4.4 / max(u.resolution.y, 1.0);
        let projectedRadius = max(2.1445069 * sunRadius / sunView.z,
                                  minimumRadius);
        let solarDelta = vec2f((ndc.x - sunCenter.x) * aspect,
                               ndc.y - sunCenter.y);
        let solarDistance = length(solarDelta);
        let pixelNdc = 2.0 / max(u.resolution.y, 1.0);
        let wideRadius = max(projectedRadius * 5.0, pixelNdc * 96.0);
        let middleRadius = max(projectedRadius * 2.85, pixelNdc * 44.0);
        let tightRadius = max(projectedRadius * 1.50, pixelNdc * 10.0);
        let wideGlow = pow(max(1.0 - solarDistance / wideRadius, 0.0), 2.25);
        let middleGlow = pow(max(1.0 - solarDistance / middleRadius, 0.0), 2.15);
        let tightGlow = pow(max(1.0 - solarDistance / tightRadius, 0.0), 1.8);
        color += vec3f(0.92, 0.16, 0.018) * wideGlow * 0.11;
        color += vec3f(1.00, 0.46, 0.060) * middleGlow * 0.30;
        color += vec3f(1.00, 0.86, 0.46) * tightGlow * 0.58;

        // 球の外に出た軌道部分を背景側に描く。球面上の部分は後段の不透明な太陽が覆う。
        let spinAngle = u.time * (0.018 + f32(u.destination) * 0.001);
        let relativeSolarDistance = solarDistance / projectedRadius;
        let prominenceRegionFade = 1.0 - smoothstep(2.0, 2.5,
                                                     relativeSolarDistance);
        if (relativeSolarDistance < 2.5) {
            color += prominenceEvent(viewRay, sunWorld, sunRadius, spinAngle,
                                     0.0, false)
                     * prominenceRegionFade;
        }

    }

    return vec4f(toneMap(color), 1.0);
}

struct PlanetOutput {
    @builtin(position) position: vec4f,
    @location(0) worldNormal: vec3f,
    @location(1) localNormal: vec3f,
    @location(2) uv: vec2f,
    @location(3) @interpolate(flat) instanceIndex: u32,
    @location(4) viewPosition: vec3f,
};

// ツアー基準時刻での土星本体座標系。JPL/NAIFの北極モデルはJ2000赤道座標で
// 赤経RA = 40.589 - 0.036 T度、赤緯DEC = 83.537 - 0.004 T度。
// 2026-10-10にシェーダーのJ2000黄道ゲーム座標へ変換した単位極ベクトルを使う。
const SATURN_POLE: vec3f = vec3f(0.085505257, 0.882518798, 0.462438560);
const SATURN_POLAR_RATIO: f32 = 0.901992;

fn saturnBasisX() -> vec3f {
    return normalize(cross(SATURN_POLE, vec3f(0.0, 0.0, 1.0)));
}

fn saturnToWorld(local: vec3f) -> vec3f {
    let basisX = saturnBasisX();
    let basisZ = normalize(cross(basisX, SATURN_POLE));
    return basisX * local.x + SATURN_POLE * local.y + basisZ * local.z;
}

fn worldToSaturn(world: vec3f) -> vec3f {
    let basisX = saturnBasisX();
    let basisZ = normalize(cross(basisX, SATURN_POLE));
    return vec3f(dot(world, basisX), dot(world, SATURN_POLE), dot(world, basisZ));
}

// A single radial opacity profile for the visible rings and transmitted sunlight.
// Radius is measured in Saturn equatorial radii, in the ring's own plane.
fn ringOpacity(radius: f32) -> f32 {
    if (radius <= 1.239 || radius >= 2.270) { return 0.0; }
    let radial = (radius - 1.239) / 1.031;
    let broad = 0.70 + 0.30 * sin(radial * 31.0 + 0.7);
    let fine = 0.82 + 0.18 * sin(radial * 137.0);
    let cassini = 1.0 - 0.92 * (1.0 - smoothstep(0.025, 0.045, abs(radial - 0.728)));
    let edge = smoothstep(0.0, 0.06, radial)
               * (1.0 - smoothstep(0.90, 1.0, radial));
    let opacity = (0.34 + 0.38 * broad) * fine * cassini * edge;
    return select(opacity, 0.0, opacity < 0.015);
}

fn ringShadowOnSaturn(surface: vec3f) -> f32 {
    let sun = worldToSaturn(sunWorldPosition() - destinationCenter()) / destinationRadius(7u);
    let toSun = sun - surface;
    if (abs(toSun.y) < 0.00001) { return 0.0; }
    // Intersect the finite surface-to-Sun segment with the equatorial plane.
    let fraction = -surface.y / toSun.y;
    if (fraction <= 0.0 || fraction >= 1.0) { return 0.0; }
    let hit = surface + toSun * fraction;
    return ringOpacity(length(hit.xz));
}

fn saturnShadowOnRing(localPosition: vec3f) -> f32 {
    let toSun = worldToSaturn(sunWorldPosition() - destinationCenter()) / destinationRadius(7u)
                - localPosition;
    // 扁球の座標を単位球へ変換し、環の粒子から太陽へ向かう光線との交差を調べる。
    let origin = vec3f(localPosition.x,
                       localPosition.y / SATURN_POLAR_RATIO,
                       localPosition.z);
    let scaledToSun = vec3f(toSun.x, toSun.y / SATURN_POLAR_RATIO, toSun.z);
    let sunDistance = length(scaledToSun);
    let ray = scaledToSun / max(sunDistance, 0.00001);
    let b = dot(origin, ray);
    let c = dot(origin, origin) - 1.0;
    let discriminant = b * b - c;
    if (discriminant <= 0.0) { return 0.0; }
    let nearDistance = -b - sqrt(discriminant);
    return select(0.0, 1.0, nearDistance > 0.0 && nearDistance < sunDistance);
}

@vertex
fn planetVS(@location(0) position: vec3f,
            @location(1) normal: vec3f,
            @location(2) uv: vec2f,
            @builtin(instance_index) instanceIndex: u32) -> PlanetOutput {
    let mainRadius = destinationRadius(u.destination);
    var radius = mainRadius;
    var center = destinationCenter();
    if (isSatelliteInstance(instanceIndex)) {
        let slot = satelliteSlot(instanceIndex);
        radius = 0.0;
        if (u.destination == 3u && slot == 0u) {
            radius = moonRadius(u.destination);
            center += moonOffset(u.destination);
        } else if (slot < satelliteCount(u.destination)) {
            radius = satelliteRadius(u.destination, slot);
            center += satelliteOffset(u.destination, slot);
        }
    } else if (instanceIndex == 3u) {
        // 月の場面では地球を別の球として描き、月の空に配置する。
        // それ以外の目的地では表示しない。
        radius = select(0.0, earthRadiusFromMoon(), u.destination == 4u);
        center += earthOffsetFromMoon();
    } else if (instanceIndex == 2u) {
        center = sunWorldPosition();
        // 見かけの半径は距離に反比例する。外惑星からも800x600画面で
        // 描画できるよう最小半径を設ける。
        radius = sunWorldRadius();
        if (u.destination == 0u) { radius = 0.0; }
    }
    if (u.topView != 0u && u.destination == 4u
        && (instanceIndex == 0u || instanceIndex == 3u)) {
        // At full Earth-orbit scale the physical radii are sub-pixel.  Enlarge
        // only the two focus bodies; their centres and both orbits stay fixed.
        radius *= 3.0;
    }
    let spinAngle = u.time * (0.018 + f32(u.destination) * 0.001);
    var bodyPosition = position;
    var bodyNormal = normal;
    if (isSatelliteInstance(instanceIndex) && u.destination != 3u && radius > 0.0) {
        let id = satelliteData(u.destination, satelliteSlot(instanceIndex)).id;
        var axes = vec3f(1.0);
        if (id == 401u) { axes = vec3f(1.23, 1.04, 0.78); }
        if (id == 402u) { axes = vec3f(1.22, 0.99, 0.83); }
        if (id == 808u) { axes = vec3f(1.10, 1.02, 0.90); }
        axes /= pow(axes.x * axes.y * axes.z, 1.0 / 3.0);
        bodyPosition *= axes;
        bodyNormal = normalize(normal / axes);
    }
    let rotation = rotate2(bodyPosition.xz, spinAngle);
    var rotatedLocal = vec3f(rotation.x, bodyPosition.y, rotation.y);
    let normalRotation = rotate2(bodyNormal.xz, spinAngle);
    var rotatedNormal = normalize(vec3f(normalRotation.x, bodyNormal.y, normalRotation.y));
    // Sample in body coordinates so surface features rotate with the body.
    var textureNormal = position;
    if (u.destination == 7u && instanceIndex == 0u) {
        // 土星は球ではなく扁球で、極半径は54,364 km、赤道半径は60,268 km。
        // 本体の扁平化と法線に、下記の環と同じ極座標系を使う。
        let bodyLocal = vec3f(rotation.x,
                              position.y * SATURN_POLAR_RATIO,
                              rotation.y);
        let bodyNormal = normalize(vec3f(normalRotation.x,
                                          normal.y / SATURN_POLAR_RATIO,
                                          normalRotation.y));
        rotatedLocal = saturnToWorld(bodyLocal);
        rotatedNormal = normalize(saturnToWorld(bodyNormal));
        textureNormal = position;
    }
    let world = center + rotatedLocal * radius;
    var output: PlanetOutput;
    let viewPosition = worldToView(world);
    output.position = projectView(viewPosition);
    if (radius <= 0.0) { output.position = vec4f(2.0, 2.0, 1.0, 1.0); }
    output.viewPosition = viewPosition;
    output.worldNormal = rotatedNormal;
    output.localNormal = textureNormal;
    output.uv = uv;
    output.instanceIndex = instanceIndex;
    return output;
}

// Local 3D crater cells avoid longitude seams and polar stretching.
// x: bowl/rim relief, y: directional relief shading.
fn craterField(n: vec3f, scale: f32, seed: f32, light: vec3f) -> vec2f {
    let p = n * scale;
    let cell = floor(p);
    let tangentLight = light - n * dot(light, n);
    var relief = 0.0;
    var shading = 0.0;
    for (var z = -1; z <= 1; z += 1) {
        for (var y = -1; y <= 1; y += 1) {
            for (var x = -1; x <= 1; x += 1) {
                let id = cell + vec3f(f32(x), f32(y), f32(z));
                let h = hash31(id + vec3f(seed));
                let center = id + vec3f(h, hash31(id + vec3f(seed + 17.0)),
                                        hash31(id + vec3f(seed + 43.0)));
                let delta = p - center;
                let size = mix(0.20, 0.47, h);
                let r = length(delta) / size;
                let bowl = -0.32 * (1.0 - smoothstep(0.0, 0.88, r));
                let rim = 0.19 * exp(-pow((r - 0.93) / 0.13, 2.0));
                relief += bowl + rim;
                let slope = (exp(-pow((r - 0.62) / 0.25, 2.0))
                             - 0.7 * exp(-pow((r - 1.05) / 0.13, 2.0)))
                            * dot(delta / max(length(delta), 0.001), tangentLight);
                shading += slope * 0.25;
            }
        }
    }
    return vec2f(relief, shading);
}

fn geographyLobe(lon: f32, lat: f32, center: vec2f, extent: vec2f) -> f32 {
    let wrapped = atan2(sin(lon - center.x), cos(lon - center.x));
    return 1.0 - length(vec2f(wrapped, lat - center.y) / extent);
}

fn earthLand(n: vec3f) -> f32 {
    let lon = atan2(n.z, n.x);
    let lat = asin(clamp(n.y, -1.0, 1.0));
    // Broad geographic silhouettes, with multiscale irregular coastlines.
    var field = geographyLobe(lon, lat, vec2f(-1.85, 0.78), vec2f(0.65, 0.48));
    field = max(field, geographyLobe(lon, lat, vec2f(-1.08, -0.28), vec2f(0.31, 0.65)));
    field = max(field, geographyLobe(lon, lat, vec2f(0.30, 0.08), vec2f(0.40, 0.66)));
    field = max(field, geographyLobe(lon, lat, vec2f(1.20, 0.83), vec2f(1.12, 0.43)));
    field = max(field, geographyLobe(lon, lat, vec2f(1.35, 0.32), vec2f(0.26, 0.38)));
    field = max(field, geographyLobe(lon, lat, vec2f(2.34, -0.46), vec2f(0.39, 0.28)));
    field = max(field, geographyLobe(lon, lat, vec2f(-0.72, 1.22), vec2f(0.27, 0.22)));
    field = max(field, (-lat - 1.19) * 4.0);
    return field + (fbm(n * 19.0) - 0.48) * 0.36;
}

fn earthCloud(n: vec3f) -> f32 {
    let wind = rotate2(n.xz, u.time * 0.0015);
    let p = vec3f(wind.x, n.y, wind.y);
    let distortion = vec3f(valueNoise(p * 5.0), valueNoise(p * 5.0 + 17.0),
                           valueNoise(p * 5.0 + 41.0)) - 0.5;
    let field = fbm(p * vec3f(8.0, 13.0, 8.0) + distortion * 2.0);
    let wisps = valueNoise(p * 67.0 + distortion * 4.0);
    return smoothstep(0.48, 0.65, field + (wisps - 0.5) * 0.10);
}

fn destinationColor(index: u32, n: vec3f, localLight: vec3f) -> vec3f {
    let longitude = atan2(n.z, n.x);
    let latitude = asin(clamp(n.y, -1.0, 1.0));
    let terrain = fbm(n * 5.0);
    let detail = fbm(n * 17.0 + vec3f(3.0));
    var color = vec3f(0.5);
    switch index {
        case 0u: {
            let textureRotation = rotate2(n.xz, u.time * 0.01945);
            let animatedNormal = vec3f(textureRotation.x, n.y, textureRotation.y);
            let cells = fbm(animatedNormal * 9.0);
            let granules = fbm(animatedNormal * 31.0);
            let hotCells = smoothstep(0.36, 0.66,
                                       cells * 0.72 + granules * 0.28);
            color = mix(vec3f(1.18, 0.075, 0.008),
                        vec3f(2.10, 1.18, 0.20), hotCells);
            color += vec3f(0.72, 0.20, 0.018)
                     * smoothstep(0.58, 0.82, granules) * 0.20;
        }
        case 1u: {
            let craters = craterField(n, 7.0, 4.0, localLight) + craterField(n, 19.0, 31.0, localLight) * 0.45;
            color = mix(vec3f(0.23, 0.21, 0.19), vec3f(0.49, 0.46, 0.41), terrain);
            let basin = smoothstep(0.57, 0.72, fbm(n * 3.0 + 11.0));
            color *= (1.0 - basin * 0.25) * (0.87 + detail * 0.26);
            color *= clamp(1.0 + craters.x * 0.65 + craters.y * 1.8, 0.4, 1.5);
        }
        case 2u: {
            let flow = fbm(n * vec3f(4.0, 11.0, 4.0) + terrain * 2.0);
            let clouds = sin(latitude * 13.0 + flow * 3.0 + longitude * 0.7) * 0.5 + 0.5;
            color = mix(vec3f(0.65, 0.55, 0.37), vec3f(0.94, 0.87, 0.67),
                        0.35 + clouds * 0.35 + detail * 0.20);
        }
        case 3u: {
            let coast = earthLand(n);
            let continents = smoothstep(-0.035, 0.035, coast);
            let dry = exp(-pow((abs(latitude) - 0.42) / 0.23, 2.0))
                      * smoothstep(0.35, 0.62, terrain);
            var land = mix(vec3f(0.035, 0.15, 0.045), vec3f(0.45, 0.32, 0.16), dry);
            let mountains = smoothstep(0.57, 0.72, fbm(n * 31.0));
            land = mix(land, vec3f(0.32, 0.29, 0.24), mountains * 0.65);
            land *= 0.78 + detail * 0.40;
            let shelf = exp(-abs(coast) * 22.0);
            let ocean = mix(vec3f(0.004, 0.022, 0.075), vec3f(0.018, 0.18, 0.23), shelf * 0.7);
            color = mix(ocean, land, continents);
            let ice = smoothstep(0.80 + (terrain - 0.5) * 0.10, 0.96, abs(n.y));
            color = mix(color, vec3f(0.80, 0.86, 0.90), ice);
            let cloud = earthCloud(n);
            let shadow = earthCloud(normalize(n + localLight * 0.018));
            color *= 1.0 - shadow * 0.20;
            color = mix(color, vec3f(0.88, 0.91, 0.94), cloud * 0.92);
        }
        case 4u: {
            let maria = smoothstep(0.49, 0.62, fbm(n * 3.2 + vec3f(8.0, 2.0, 1.0)));
            let craters = craterField(n, 6.0, 13.0, localLight) + craterField(n, 18.0, 39.0, localLight) * 0.45;
            color = mix(vec3f(0.50, 0.48, 0.44), vec3f(0.20, 0.21, 0.22), maria);
            color *= (0.82 + detail * 0.35)
                     * clamp(1.0 + craters.x * 0.8 + craters.y * 2.0, 0.35, 1.6);
        }
        case 5u: {
            color = mix(vec3f(0.37, 0.085, 0.025), vec3f(0.91, 0.34, 0.075),
                        smoothstep(0.44, 0.65, terrain));
            color = mix(color, vec3f(0.96, 0.84, 0.68), smoothstep(0.89, 0.98, abs(n.y)));
            let darkRock = smoothstep(0.48, 0.65, fbm(n * 7.0 + vec3f(19.0, 3.0, 8.0)));
            color = mix(color, vec3f(0.20, 0.11, 0.065), darkRock * 0.66);
            let craters = craterField(n, 13.0, 27.0, localLight);
            color *= (0.85 + detail * 0.30) * clamp(1.0 + craters.x * 0.35 + craters.y, 0.5, 1.4);
        }
        case 6u: {
            let flow = fbm(n * vec3f(12.0, 5.0, 12.0));
            let bands = sin(latitude * 36.0 + (flow - 0.5) * 5.0) * 0.5 + 0.5;
            let fineBands = sin(latitude * 110.0 + flow * 9.0 + detail * 3.0) * 0.5 + 0.5;
            color = mix(vec3f(0.34, 0.13, 0.055),
                        vec3f(0.92, 0.68, 0.40), bands);
            color = mix(color, vec3f(0.88, 0.82, 0.70), fineBands * 0.22);
            let spotDelta = vec2f(atan2(sin(longitude - 0.15), cos(longitude - 0.15)) / 0.24,
                                  (latitude + 0.28) / 0.11);
            let spotRadius = length(spotDelta);
            let spot = 1.0 - smoothstep(0.80, 1.12, spotRadius);
            let spiral = sin(atan2(spotDelta.y, spotDelta.x) * 2.0
                             + spotRadius * 15.0 + detail * 4.0) * 0.5 + 0.5;
            color = mix(color, mix(vec3f(0.47, 0.19, 0.10), vec3f(0.78, 0.43, 0.24), spiral), spot * 0.88);
            color *= 0.86 + detail * 0.28;
        }
        case 7u: {
            let flow = fbm(n * vec3f(10.0, 4.0, 10.0));
            let bands = sin(latitude * 34.0 + flow * 2.2) * 0.5 + 0.5;
            color = mix(vec3f(0.54, 0.40, 0.23),
                        vec3f(0.88, 0.76, 0.54), bands * 0.52);
            color *= 0.92 + detail * 0.12;
            let fine = sin(latitude * 125.0 + flow * 6.0) * 0.5 + 0.5;
            color *= 0.93 + fine * 0.09;
        }
        case 8u: {
            let bands = sin(latitude * 22.0 + terrain) * 0.5 + 0.5;
            color = mix(vec3f(0.27, 0.58, 0.61), vec3f(0.46, 0.73, 0.73), bands * 0.12 + 0.30);
            color = mix(color, vec3f(0.60, 0.79, 0.78), smoothstep(0.50, 0.95, abs(n.y)) * 0.24);
        }
        default: {
            let bands = sin(latitude * 34.0 + terrain * 2.0) * 0.5 + 0.5;
            color = mix(vec3f(0.025, 0.13, 0.55), vec3f(0.12, 0.47, 0.98), bands * 0.52);
            let stormDelta = vec2f(atan2(sin(longitude + 0.7), cos(longitude + 0.7)) / 0.22,
                                   (latitude + 0.35) / 0.12);
            color *= 1.0 - (1.0 - smoothstep(0.6, 1.1, length(stormDelta))) * 0.40;
            let wisps = smoothstep(0.60, 0.73, fbm(n * vec3f(8.0, 30.0, 8.0) + 23.0));
            color = mix(color, vec3f(0.58, 0.72, 0.86), wisps * 0.55);
        }
    }
    return color;
}

// Procedural visual approximations for satellite surfaces.
fn satelliteColor(id: u32, n: vec3f, light: vec3f) -> vec3f {
    let seed = f32(id) * 0.13;
    let broad = fbm(n * 5.0 + seed);
    let fine = fbm(n * 36.0 + seed);
    let craters = craterField(n, 9.0, seed, light)
                  + craterField(n, 25.0, seed + 19.0, light) * 0.45;
    var color = mix(vec3f(0.22, 0.21, 0.20), vec3f(0.52, 0.50, 0.46), broad);
    switch id {
        case 401u, 402u: {
            color = mix(vec3f(0.16, 0.13, 0.10), vec3f(0.34, 0.29, 0.23), broad);
            if (id == 401u) {
                let stickney = acos(clamp(dot(n, normalize(vec3f(0.7, 0.2, 0.6))), -1.0, 1.0));
                color *= 1.0 - (1.0 - smoothstep(0.25, 0.40, stickney)) * 0.45;
                color += vec3f(0.08) * exp(-pow((stickney - 0.36) / 0.045, 2.0));
                let grooves = pow(0.5 + 0.5 * sin(n.y * 90.0 + broad * 5.0), 14.0);
                color *= 1.0 - grooves * 0.14;
            }
        }
        case 501u: {
            // Io: sulfur plains, red deposits and dark volcanic calderas.
            color = mix(vec3f(0.66, 0.30, 0.07), vec3f(0.94, 0.82, 0.38), broad);
            let vents = smoothstep(0.67, 0.78, fbm(n * 19.0 + 37.0));
            color = mix(color, vec3f(0.15, 0.055, 0.025), vents);
            color = mix(color, vec3f(0.64, 0.16, 0.045),
                        smoothstep(0.56, 0.69, fine) * 0.45);
            return color * (0.88 + fine * 0.22);
        }
        case 502u: {
            // Europa: pale ice crossed by thin, branching brown fractures.
            color = mix(vec3f(0.65, 0.60, 0.49), vec3f(0.94, 0.92, 0.84), broad);
            let bent = n + vec3f(broad * 0.12);
            let cracksA = abs(sin(dot(bent, vec3f(31.0, 19.0, 23.0))));
            let cracksB = abs(sin(dot(bent, vec3f(-17.0, 37.0, 11.0)) + fine * 0.3));
            let cracks = 1.0 - smoothstep(0.015, 0.075, min(cracksA, cracksB));
            return mix(color, vec3f(0.28, 0.15, 0.085), cracks * 0.75);
        }
        case 503u: {
            // Ganymede: dark old terrain and bright grooved ice.
            let ice = smoothstep(0.43, 0.62, broad);
            color = mix(vec3f(0.24, 0.21, 0.18), vec3f(0.67, 0.64, 0.55), ice);
            let grooves = 0.5 + 0.5 * sin(n.x * 110.0 + n.z * 70.0 + broad * 17.0);
            color *= 0.86 + grooves * ice * 0.22;
        }
        case 504u: {
            // Callisto: dark, heavily cratered surface with bright impact rims.
            color = mix(vec3f(0.13, 0.12, 0.10), vec3f(0.35, 0.32, 0.27), broad);
            color += vec3f(0.75, 0.72, 0.64) * max(craters.x, 0.0) * 2.0;
        }
        case 606u: {
            // Titan's visible disk is dominated by its opaque orange haze.
            let bands = fbm(n * vec3f(4.0, 14.0, 4.0) + seed);
            color = mix(vec3f(0.58, 0.30, 0.08), vec3f(0.89, 0.62, 0.24), bands * 0.55 + 0.25);
            return color;
        }
        case 602u: {
            color = mix(vec3f(0.77, 0.83, 0.85), vec3f(0.98, 0.98, 0.94), broad);
            let south = 1.0 - smoothstep(-0.85, -0.45, n.y);
            let stripes = 1.0 - smoothstep(0.02, 0.10,
                abs(sin(n.x * 36.0 + broad * 4.0)));
            color = mix(color, vec3f(0.31, 0.47, 0.51), south * stripes * 0.5);
        }
        case 601u: {
            color = mix(vec3f(0.49, 0.48, 0.46), vec3f(0.82, 0.81, 0.77), broad);
            let herschel = acos(clamp(dot(n, normalize(vec3f(0.7, 0.1, 0.7))), -1.0, 1.0));
            color *= 1.0 - (1.0 - smoothstep(0.25, 0.42, herschel)) * 0.46;
            color += vec3f(0.20) * exp(-pow((herschel - 0.38) / 0.035, 2.0));
        }
        case 608u: {
            let dark = smoothstep(-0.10, 0.12, n.x + (broad - 0.5) * 0.35);
            color = mix(vec3f(0.78, 0.75, 0.67), vec3f(0.12, 0.09, 0.065), dark);
            color *= 1.0 + exp(-pow(n.y / 0.035, 2.0)) * 0.15;
        }
        case 801u: {
            color = mix(vec3f(0.64, 0.57, 0.54), vec3f(0.86, 0.85, 0.78), broad);
            let cap = smoothstep(0.25, 0.65, -n.y + broad * 0.2);
            color = mix(color, vec3f(0.91, 0.84, 0.82), cap * 0.7);
            let streaks = pow(0.5 + 0.5 * sin(n.x * 79.0 + broad * 12.0), 20.0);
            color *= 1.0 - streaks * cap * 0.20;
        }
        case 808u: {
            color = mix(vec3f(0.12, 0.12, 0.115), vec3f(0.32, 0.31, 0.29), broad);
        }
        case 802u: {
            // Nereid is unresolved in available close-range imagery: generic icy rock.
            color = mix(vec3f(0.28, 0.27, 0.24), vec3f(0.54, 0.52, 0.47), broad);
        }
        default: {}
    }
    return color * (0.88 + fine * 0.24)
        * clamp(1.0 + craters.x * 0.65 + craters.y * 1.8, 0.45, 1.45);
}

@fragment
fn planetFS(input: PlanetOutput) -> @location(0) vec4f {
    let n = normalize(input.worldNormal);
    let worldPosition = cameraPosition() + viewDirectionToWorld(input.viewPosition);
    let lightDirection = solarDirection(worldPosition);
    var bodyLight = lightDirection;
    if (u.destination == 7u && input.instanceIndex == 0u) {
        bodyLight = worldToSaturn(bodyLight);
    }
    let spinAngle = u.time * (0.018 + f32(u.destination) * 0.001);
    let lightXZ = rotate2(bodyLight.xz, -spinAngle);
    let localLight = normalize(vec3f(lightXZ.x, bodyLight.y, lightXZ.y));
    let diffuse = max(dot(n, lightDirection), 0.0);
    var base: vec3f;
    if (input.instanceIndex == 2u) {
        base = destinationColor(0u, normalize(input.localNormal), localLight);
    } else if (isSatelliteInstance(input.instanceIndex)) {
        if (u.destination == 3u) {
            base = destinationColor(4u, normalize(input.localNormal), localLight);
        } else {
            base = satelliteColor(satelliteData(u.destination,
                satelliteSlot(input.instanceIndex)).id, normalize(input.localNormal), localLight);
        }
    } else if (input.instanceIndex == 3u) {
        base = destinationColor(3u, normalize(input.localNormal), localLight);
    } else {
        base = destinationColor(u.destination, normalize(input.localNormal), localLight);
    }
    var color = base * (0.028 + diffuse * 1.13);
    if ((u.destination == 3u && input.instanceIndex == 0u)
        || input.instanceIndex == 3u) {
        let local = normalize(input.localNormal);
        let ocean = 1.0 - smoothstep(-0.035, 0.035, earthLand(local));
        let viewDirection = normalize(-input.viewPosition);
        let halfDirection = normalize(worldDirectionToView(lightDirection) + viewDirection);
        let specular = pow(max(dot(normalize(worldDirectionToView(n)), halfDirection), 0.0), 100.0);
        color += vec3f(1.0, 0.91, 0.76) * specular * ocean
                 * (1.0 - earthCloud(local)) * diffuse * 0.75;
    }
    if (input.instanceIndex == 2u) {
        color = base * 1.72;
    } else if (u.destination == 0u && input.instanceIndex == 0u) {
        let viewNormal = normalize(worldDirectionToView(n));
        let facing = clamp(-viewNormal.z, 0.0, 1.0);
        // 光球を明るく保ちながら周辺減光を弱く加える。
        // 全周に加える琥珀色の縁光は不自然だったため使わない。
        color = base * (1.46 + facing * 0.28);
    } else if (input.instanceIndex == 0u || input.instanceIndex == 3u) {
        // ユーザーの比較指示により、本体への輪の影を一時的に無効化。
        // 通常の太陽光による陰影は上で計算した color を使う。
        let viewNormal = normalize(worldDirectionToView(n));
        let rim = pow(1.0 - max(-viewNormal.z, 0.0), 3.2);
        var atmosphere = vec3f(0.12, 0.25, 0.50);
        if (u.destination == 2u) { atmosphere = vec3f(1.0, 0.48, 0.12); }
        if (u.destination == 3u || input.instanceIndex == 3u) {
            atmosphere = vec3f(0.12, 0.42, 1.0);
        }
        if (u.destination == 5u) { atmosphere = vec3f(0.82, 0.18, 0.045); }
        if (u.destination == 6u) { atmosphere = vec3f(0.62, 0.30, 0.12); }
        if (u.destination == 7u) { atmosphere = vec3f(0.62, 0.46, 0.24); }
        if (u.destination == 8u) { atmosphere = vec3f(0.12, 0.90, 1.0); }
        var atmosphereStrength = 0.34;
        // Airless rocky bodies have no painted blue atmospheric rim.
        if ((u.destination == 1u || u.destination == 4u)
            && input.instanceIndex == 0u) { atmosphereStrength = 0.0; }
        if (u.destination == 5u) { atmosphereStrength = 0.10; }
        color += atmosphere * rim * (0.18 + diffuse) * atmosphereStrength;
    }

    // 太陽面より手前にある軌道を表面へ重ね、裏側の軌道は深度で除外する。
    if ((u.destination == 0u && input.instanceIndex == 0u)
        || (u.destination != 0u && input.instanceIndex == 2u)) {
        let sunWorld = sunWorldPosition();
        let sunRadius = sunWorldRadius();
        let sunSpinAngle = u.time * (0.018 + f32(u.destination) * 0.001);
        color += prominenceEvent(normalize(input.viewPosition), sunWorld,
            sunRadius, sunSpinAngle, input.viewPosition.z, true);
    }
    return vec4f(toneMap(color), 1.0);
}

// --------------------------------------------------------------------------
// 土星の環のメッシュ。

struct RingOutput {
    @builtin(position) position: vec4f,
    @location(0) radial: f32,
    @location(1) visible: f32,
    @location(2) localPosition: vec3f,
};

@vertex
fn ringVS(@location(0) position: vec3f,
          @location(1) normal: vec3f,
          @location(2) uv: vec2f) -> RingOutput {
    var output: RingOutput;
    if (u.destination != 7u) {
        output.position = vec4f(2.0, 2.0, 1.0, 1.0);
        output.visible = 0.0;
    } else {
        let radius = destinationRadius(u.destination);
        // 環をJPL極座標系に基づく土星赤道面上に構築する。
        // そのため、カメラが回転しても環の中心は土星中心と一致する。
        let local = saturnToWorld(position) * radius;
        output.position = projectView(worldToView(destinationCenter() + local));
        output.visible = 1.0;
    }
    output.radial = uv.x;
    output.localPosition = position;
    return output;
}

@fragment
fn ringFS(input: RingOutput) -> @location(0) vec4f {
    if (input.visible < 0.5) { discard; }
    let broad = 0.70 + 0.30 * sin(input.radial * 31.0 + 0.7);
    let ringWorld = destinationCenter()
                    + saturnToWorld(input.localPosition) * destinationRadius(7u);
    let lightDirection = solarDirection(ringWorld);
    let grazingLight = abs(dot(SATURN_POLE, lightDirection));
    let planetShadow = saturnShadowOnRing(input.localPosition);
    let illumination = 0.38 + 0.62 * sqrt(grazingLight) * (1.0 - planetShadow);
    let alpha = ringOpacity(length(input.localPosition.xz));
    if (alpha < 0.015) { discard; }
    var color = mix(vec3f(0.48, 0.38, 0.25), vec3f(0.86, 0.77, 0.60), broad);
    color *= illumination;
    return vec4f(toneMap(color), alpha);
}

// --------------------------------------------------------------------------
// 全画面ワープ幕。不透明な白のピークで目的地の切り替えを隠し、
// 前後は半透明にして星の航跡を見せる。

struct WarpOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
};

@vertex
fn warpVS(@location(0) position: vec2f) -> WarpOutput {
    var output: WarpOutput;
    output.position = vec4f(position, 0.0, 1.0);
    output.uv = position * 0.5 + vec2f(0.5);
    return output;
}

@fragment
fn warpFS(input: WarpOutput) -> @location(0) vec4f {
    if (u.warp < 0.002) { discard; }
    let energy = smoothstep(0.05, 0.72, u.warp);
    // 立ち上がりと解除を3秒の中央で対称にする。
    // 0.5秒で白くなり始め、星の動きが反転する中央で最大、5.5秒で消える。
    let flashIn = smoothstep(0.08333333, 0.5, u.warpPhase);
    let flashOut = 1.0 - smoothstep(0.5, 0.91666667, u.warpPhase);
    let flash = min(flashIn, flashOut);
    // 一様な半透明の幕と切り替え時の閃光だけを使う。
    // 以前の放射状の筋と描き足した縁の暗がりは削除済み。
    let veil = vec3f(0.025, 0.060, 0.14) * energy;
    let color = mix(veil, vec3f(1.0), flash);
    let alpha = max(energy * 0.16, flash);
    return vec4f(toneMap(color * 1.35), clamp(alpha, 0.0, 1.0));
}

