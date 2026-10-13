const canvas = document.querySelector("#gpu-canvas");
const message = document.querySelector("#message");

function showError(error) {
  console.error(error);
  message.style.display = "grid";
  message.textContent = `WebGPUの初期化に失敗しました。\n\n${error.message ?? error}`;
}

async function main() {
  if (!navigator.gpu) {
    throw new Error(
      "このブラウザーではWebGPUを利用できません。" +
      "最新版のWebGPU対応ブラウザーをHTTPSまたはlocalhostで使用してください。"
    );
  }

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error("WebGPUアダプターを取得できませんでした。");
  }

  const device = await adapter.requestDevice();
  device.lost.then((info) => {
    showError(new Error(`GPUデバイスが失われました: ${info.message}`));
  });

  const context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  const response = await fetch("./seascape.wgsl");
  if (!response.ok) {
    throw new Error(`seascape.wgslを読み込めませんでした: ${response.status}`);
  }
  const shaderSource = await response.text();

  const shaderModule = device.createShaderModule({ code: shaderSource });
  const compilationInfo = await shaderModule.getCompilationInfo();
  const errors = compilationInfo.messages.filter((item) => item.type === "error");

  if (errors.length > 0) {
    const details = errors
      .map((item) => `${item.lineNum}:${item.linePos} ${item.message}`)
      .join("\n");
    throw new Error(`WGSLコンパイルエラー:\n${details}`);
  }

  const pipeline = await device.createRenderPipelineAsync({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "vsMain" },
    fragment: {
      module: shaderModule,
      entryPoint: "fsMain",
      targets: [{ format }],
    },
    primitive: { topology: "triangle-list" },
  });

  const uniformBuffer = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuffer } }],
  });

  const uniformData = new Float32Array(4);
  let width = 0;
  let height = 0;

  function resizeCanvas() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const nextWidth = Math.max(1, Math.floor(canvas.clientWidth * dpr));
    const nextHeight = Math.max(1, Math.floor(canvas.clientHeight * dpr));

    if (nextWidth !== width || nextHeight !== height) {
      width = nextWidth;
      height = nextHeight;
      canvas.width = width;
      canvas.height = height;
    }
  }

  const startTime = performance.now();

  function frame(now) {
    resizeCanvas();

    uniformData[0] = width;
    uniformData[1] = height;
    uniformData[2] = (now - startTime) * 0.001;
    uniformData[3] = 0;
    device.queue.writeBuffer(uniformBuffer, 0, uniformData);

    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: context.getCurrentTexture().createView(),
        clearValue: { r: 0.0, g: 0.0, b: 0.0, a: 1.0 },
        loadOp: "clear",
        storeOp: "store",
      }],
    });

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(3);
    pass.end();

    device.queue.submit([encoder.finish()]);
    requestAnimationFrame(frame);
  }

  requestAnimationFrame(frame);
}

main().catch(showError);

