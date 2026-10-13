struct Params {
    deltaTime: f32,
    separation: f32,
    alignment: f32,
    cohesion: f32,
    rayOrigin: vec3f,
    _pad0: f32,
    rayDirection: vec3f,
    _pad1: f32,
    resolution: vec2f,
    now: f32,
    birdCount: u32,
    cameraYaw: f32,
    cameraPitch: f32,
    cameraDistance: f32,
    _pad2: f32,
    cameraTarget: vec3f,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> positions: array<vec4f>;
@group(0) @binding(2) var<storage, read_write> velocities: array<vec4f>;
@group(0) @binding(3) var<storage, read_write> phases: array<f32>;

@group(0) @binding(4) var<storage, read> renderPositions: array<vec4f>;
@group(0) @binding(5) var<storage, read> renderVelocities: array<vec4f>;
@group(0) @binding(6) var<storage, read> renderPhases: array<f32>;

const PI: f32 = 3.141592653589793;
const PI_2: f32 = PI * 2.0;
const SPEED_LIMIT: f32 = 9.0;

@compute @workgroup_size(64)
fn computeVelocity(@builtin(global_invocation_id) id: vec3u) {
    let birdIndex = id.x;
    if (birdIndex >= params.birdCount) {
        return;
    }

    let zoneRadius = params.separation + params.alignment + params.cohesion;
    let separationThresh = params.separation / zoneRadius;
    let alignmentThresh = (params.separation + params.alignment) / zoneRadius;
    let zoneRadiusSq = zoneRadius * zoneRadius;

    let position = positions[birdIndex].xyz;
    var velocity = velocities[birdIndex].xyz;
    var limit = SPEED_LIMIT;

    let directionToRay = params.rayOrigin - position;
    let projectionLength = dot(directionToRay, params.rayDirection);
    let closestPoint = params.rayOrigin - params.rayDirection * projectionLength;
    let directionToClosestPoint = closestPoint - position;
    let distanceToClosestPoint = length(directionToClosestPoint);
    let distanceToClosestPointSq = distanceToClosestPoint * distanceToClosestPoint;
    let rayRadius = 150.0;
    let rayRadiusSq = rayRadius * rayRadius;

    if (distanceToClosestPointSq < rayRadiusSq) {
        let velocityAdjust =
            (distanceToClosestPointSq / rayRadiusSq - 1.0) * params.deltaTime * 100.0;
        velocity += normalize(directionToClosestPoint) * velocityAdjust;
        limit += 5.0;
    }

    var dirToCenter = position;
    dirToCenter.y *= 2.5;
    velocity -= normalize(dirToCenter) * params.deltaTime * 5.0;

    for (var i = 0u; i < params.birdCount; i++) {
        if (i == birdIndex) {
            continue;
        }

        let birdPosition = positions[i].xyz;
        let dirToBird = birdPosition - position;
        let distToBird = length(dirToBird);
        if (distToBird < 0.0001) {
            continue;
        }

        let distToBirdSq = distToBird * distToBird;
        if (distToBirdSq > zoneRadiusSq) {
            continue;
        }

        let percent = distToBirdSq / zoneRadiusSq;
        if (percent < separationThresh) {
            let velocityAdjust =
                (separationThresh / percent - 1.0) * params.deltaTime;
            velocity -= normalize(dirToBird) * velocityAdjust;
        } else if (percent < alignmentThresh) {
            let threshDelta = alignmentThresh - separationThresh;
            let adjustedPercent = (percent - separationThresh) / threshDelta;
            let birdVelocity = velocities[i].xyz;
            let cosRange = cos(adjustedPercent * PI_2);
            let cosRangeAdjust = 0.5 - cosRange * 0.5 + 0.5;
            let velocityAdjust = cosRangeAdjust * params.deltaTime;
            velocity += normalize(birdVelocity) * velocityAdjust;
        } else {
            let threshDelta = 1.0 - alignmentThresh;
            var adjustedPercent = 1.0;
            if (threshDelta != 0.0) {
                adjustedPercent = (percent - alignmentThresh) / threshDelta;
            }
            let cosRange = cos(adjustedPercent * PI_2);
            let adj1 = cosRange * -0.5;
            let adj2 = adj1 + 0.5;
            let adj3 = 0.5 - adj2;
            let velocityAdjust = adj3 * params.deltaTime;
            velocity += normalize(dirToBird) * velocityAdjust;
        }
    }

    if (length(velocity) > limit) {
        velocity = normalize(velocity) * limit;
    }

    velocities[birdIndex] = vec4f(velocity, 0.0);
}

@compute @workgroup_size(64)
fn computePosition(@builtin(global_invocation_id) id: vec3u) {
    let birdIndex = id.x;
    if (birdIndex >= params.birdCount) {
        return;
    }

    let velocity = velocities[birdIndex].xyz;
    positions[birdIndex] = vec4f(
        positions[birdIndex].xyz + velocity * params.deltaTime * 15.0,
        0.0
    );

    let phase = phases[birdIndex];
    let modValue = phase
        + params.deltaTime
        + length(velocity.xz) * params.deltaTime * 3.0
        + max(velocity.y, 0.0) * params.deltaTime * 6.0;
    phases[birdIndex] = modValue - 62.83 * floor(modValue / 62.83);
}


// PBR Neutralの式は維持し、白いFogを合成する前にSkyの元色を変換する。
// 白いFogまでトーンマップすると、完全なFogが灰色になってしまう。
fn neutralToneMapping(colorIn: vec3f) -> vec3f {
    let startCompression = 0.76;
    let desaturation = 0.15;
    var color = colorIn;
    let x = min(color.r, min(color.g, color.b));
    let offset = select(0.04, x - 6.25 * x * x, x < 0.08);
    color -= offset;
    let peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression) {
        return color;
    }
    let d = 1.0 - startCompression;
    let newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;
    let g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return mix(color, vec3f(newPeak), g);
}

fn linearToSrgb(value: vec3f) -> vec3f {
    let low = value * 12.92;
    let high = 1.055 * pow(max(value, vec3f(0.0)), vec3f(1.0 / 2.4)) - 0.055;
    return select(high, low, value <= vec3f(0.0031308));
}

fn finishColorWithFog(linearColor: vec3f, fogFactor: f32) -> vec4f {
    // 元の色だけをPBR Neutralで変換する。Fogの白は変換しない。
    let mappedColor = neutralToneMapping(max(linearColor, vec3f(0.0)));
    let whiteFog = vec3f(1.0, 1.0, 1.0);
    let mixedColor = mix(mappedColor, whiteFog, fogFactor);

    // BGRA8Unormへ書くため、線形値を一度だけsRGBへ変換する。
    return vec4f(linearToSrgb(mixedColor), 1.0);
}

// カメラの向きと距離から、公式OrbitControlsと同じ「原点を見る」視点を作る。
fn worldToView(worldPosition: vec3f) -> vec3f {
    let cosineYaw = cos(params.cameraYaw);
    let sineYaw = sin(params.cameraYaw);
    let cosinePitch = cos(params.cameraPitch);
    let sinePitch = sin(params.cameraPitch);

    let cameraOffset = vec3f(
        params.cameraDistance * sineYaw * cosinePitch,
        params.cameraDistance * sinePitch,
        params.cameraDistance * cosineYaw * cosinePitch
    );
    let forward = normalize(-cameraOffset);
    let right = normalize(cross(forward, vec3f(0.0, 1.0, 0.0)));
    let up = cross(right, forward);
    // パンした注視点を鳥とSkyの両方へ反映する。
    let relative = worldPosition - (cameraOffset + params.cameraTarget);

    return vec3f(dot(relative, right), dot(relative, up), -dot(relative, forward));
}

struct SkyOutput {
    @builtin(position) position: vec4f,
    @location(0) localPosition: vec3f,
    @location(1) viewDepth: f32,
};

// Draw the same sky sphere used by the source example.
// The input is a unit icosphere. The shader rotates it by 0.75 radians,
// enlarges it to radius 1200, and projects it with the fixed camera.
@vertex
fn skyVS(@location(0) unitPosition: vec3f) -> SkyOutput {
    let cosine = cos(0.75);
    let sine = sin(0.75);
    let rotated = vec3f(
        cosine * unitPosition.x - sine * unitPosition.y,
        sine * unitPosition.x + cosine * unitPosition.y,
        unitPosition.z
    );
    let world = rotated * 1200.0;
    let view = worldToView(world);
    let aspect = params.resolution.x / params.resolution.y;
    let focal = 2.1445069205095586;
    let near = 1.0;
    let far = 5000.0;

    var output: SkyOutput;
    output.position = vec4f(
        focal / aspect * view.x,
        focal * view.y,
        far / (near - far) * view.z + far * near / (near - far),
        -view.z
    );
    output.localPosition = unitPosition;
    output.viewDepth = -view.z;
    return output;
}

// 公式HTMLのSky用colorNodeを、そのままWGSLへ移した色式。
// positionLocal.yは単位IcosphereのローカルY座標で、頂点間を補間して使う。
@fragment
fn skyFS(input: SkyOutput) -> @location(0) vec4f {
    let skyColor = vec3f(
        0.25 - input.localPosition.y,
        -0.25 - input.localPosition.y,
        1.5 + input.localPosition.y
    );

    // カメラから遠い部分ほど白Fogを増やす。色の最終変換は共通関数で行う。
    let fogFactor = smoothstep(700.0, 3000.0, input.viewDepth);
    return finishColorWithFog(skyColor, fogFactor);
}

struct BirdOutput {
    @builtin(position) position: vec4f,
    @location(0) viewDepth: f32,
};

@vertex
fn birdVS(@location(0) inputPosition: vec3f,
          @builtin(vertex_index) vertexIndex: u32,
          @builtin(instance_index) instanceIndex: u32) -> BirdOutput {
    // 頂点座標はLisp側で作ったBirdGeometry相当の頂点バッファから受け取る。
    var modelPosition = inputPosition;
    if (vertexIndex == 4u || vertexIndex == 7u) {
        modelPosition.y = sin(renderPhases[instanceIndex]) * 5.0;
    }
    let newPosition = vec3f(modelPosition.z, modelPosition.y, -modelPosition.x);

    var newVelocity = normalize(renderVelocities[instanceIndex].xyz);
    newVelocity.z *= -1.0;

    let xz = length(newVelocity.xz);
    let x = sqrt(1.0 - newVelocity.y * newVelocity.y);
    let cosry = newVelocity.x / xz;
    let sinry = newVelocity.z / xz;
    let cosrz = x;
    let sinrz = newVelocity.y;

    let afterZ = vec3f(
        cosrz * newPosition.x - sinrz * newPosition.y,
        sinrz * newPosition.x + cosrz * newPosition.y,
        newPosition.z
    );
    let finalVert = vec3f(
        cosry * afterZ.x + sinry * afterZ.z,
        afterZ.y,
        -sinry * afterZ.x + cosry * afterZ.z
    ) + renderPositions[instanceIndex].xyz;

    let view = worldToView(finalVert);
    let aspect = params.resolution.x / params.resolution.y;
    let focal = 2.1445069205095586;
    let near = 1.0;
    let far = 5000.0;

    var output: BirdOutput;
    output.position = vec4f(
        focal / aspect * view.x,
        focal * view.y,
        far / (near - far) * view.z + far * near / (near - far),
        -view.z
    );
    output.viewDepth = -view.z;
    return output;
}

// 公式の鳥は色ノードを指定しないNodeMaterialで、比較画像では黒く描かれる。
// 白を既定色と決めつけた前回の移植を取り消し、黒から白Fogへ変化させる。
@fragment
fn birdFS(input: BirdOutput) -> @location(0) vec4f {
    let birdColor = vec3f(0.0, 0.0, 0.0);
    let fogFactor = smoothstep(700.0, 3000.0, input.viewDepth);

    // 鳥にもSkyと同じ順序の色変換を使う。
    return finishColorWithFog(birdColor, fogFactor);
}
