const GPU_BUFFER_USAGE = globalThis.GPUBufferUsage;

export class HermesGPU {
  constructor(canvas) {
    this.canvas = canvas;
    this.backend = "none";
    this.device = null;
    this.context = null;
    this.pipeline = null;
    this.buffer = null;
    this.capacity = 0;
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(canvas);
  }

  async init() {
    if (navigator.gpu) {
      try {
        await this.initWebGPU();
        this.backend = "webgpu";
        return this;
      } catch { /* WebGPU can be disabled by browser/user policy. */ }
    }
    this.initWebGL();
    this.backend = "webgl2";
    return this;
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    const scale = Math.min(devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.round(rect.width * scale));
    const height = Math.max(1, Math.round(rect.height * scale));
    if (this.canvas.width === width && this.canvas.height === height) return false;
    this.canvas.width = width;
    this.canvas.height = height;
    if (this.backend === "webgpu") this.configureWebGPU();
    return true;
  }

  render(rectangles) {
    this.resize();
    const vertices = buildVertices(rectangles, this.canvas.clientWidth, this.canvas.clientHeight);
    if (this.backend === "webgpu") this.renderWebGPU(vertices);
    else if (this.backend === "webgl2") this.renderWebGL(vertices);
  }

  async initWebGPU() {
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) throw new Error("No WebGPU adapter");
    this.device = await adapter.requestDevice();
    this.context = this.canvas.getContext("webgpu");
    this.format = navigator.gpu.getPreferredCanvasFormat();
    this.pipeline = this.device.createRenderPipeline({
      layout: "auto",
      vertex: {
        module: this.device.createShaderModule({ code: `
          struct Out { @builtin(position) position: vec4f, @location(0) color: vec4f }
          @vertex fn main(@location(0) position: vec2f, @location(1) color: vec4f) -> Out {
            var out: Out;
            out.position = vec4f(position, 0.0, 1.0);
            out.color = color;
            return out;
          }` }),
        entryPoint: "main",
        buffers: [{ arrayStride: 24, attributes: [
          { shaderLocation: 0, offset: 0, format: "float32x2" },
          { shaderLocation: 1, offset: 8, format: "float32x4" },
        ] }],
      },
      fragment: {
        module: this.device.createShaderModule({ code: `
          @fragment fn main(@location(0) color: vec4f) -> @location(0) vec4f { return color; }` }),
        entryPoint: "main",
        targets: [{ format: this.format, blend: {
          color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
          alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
        } }],
      },
      primitive: { topology: "triangle-list" },
    });
    this.configureWebGPU();
  }

  configureWebGPU() {
    this.context?.configure({ device: this.device, format: this.format, alphaMode: "premultiplied" });
  }

  renderWebGPU(vertices) {
    const bytes = vertices.byteLength;
    if (!this.buffer || this.capacity < bytes) {
      this.buffer?.destroy();
      this.capacity = nextPowerOfTwo(Math.max(bytes, 1024));
      this.buffer = this.device.createBuffer({ size: this.capacity, usage: GPU_BUFFER_USAGE.VERTEX | GPU_BUFFER_USAGE.COPY_DST });
    }
    this.device.queue.writeBuffer(this.buffer, 0, vertices);
    const encoder = this.device.createCommandEncoder();
    const pass = encoder.beginRenderPass({ colorAttachments: [{
      view: this.context.getCurrentTexture().createView(),
      clearValue: { r: 0, g: 0, b: 0, a: 0 },
      loadOp: "clear",
      storeOp: "store",
    }] });
    pass.setPipeline(this.pipeline);
    pass.setVertexBuffer(0, this.buffer);
    pass.draw(vertices.length / 6);
    pass.end();
    this.device.queue.submit([encoder.finish()]);
  }

  initWebGL() {
    const gl = this.canvas.getContext("webgl2", { alpha: true, antialias: true, depth: false, stencil: false });
    if (!gl) throw new Error("Hermes requires WebGPU or WebGL2");
    this.context = gl;
    const vertex = shader(gl, gl.VERTEX_SHADER, `#version 300 es
      in vec2 position; in vec4 color; out vec4 vColor;
      void main(){ gl_Position=vec4(position,0.0,1.0); vColor=color; }`);
    const fragment = shader(gl, gl.FRAGMENT_SHADER, `#version 300 es
      precision lowp float; in vec4 vColor; out vec4 outputColor;
      void main(){ outputColor=vColor; }`);
    this.pipeline = gl.createProgram();
    gl.attachShader(this.pipeline, vertex);
    gl.attachShader(this.pipeline, fragment);
    gl.linkProgram(this.pipeline);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    this.buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    const position = gl.getAttribLocation(this.pipeline, "position");
    const color = gl.getAttribLocation(this.pipeline, "color");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(color);
    gl.vertexAttribPointer(color, 4, gl.FLOAT, false, 24, 8);
  }

  renderWebGL(vertices) {
    const gl = this.context;
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.useProgram(this.pipeline);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.DYNAMIC_DRAW);
    gl.drawArrays(gl.TRIANGLES, 0, vertices.length / 6);
  }

  destroy() {
    this.resizeObserver.disconnect();
    if (this.backend === "webgpu") this.buffer?.destroy();
    if (this.backend === "webgl2") {
      this.context?.deleteBuffer(this.buffer);
      this.context?.deleteProgram(this.pipeline);
      this.context?.getExtension("WEBGL_lose_context")?.loseContext();
    }
    this.buffer = null;
    this.pipeline = null;
    this.context = null;
  }
}

function buildVertices(rectangles, width, height) {
  const values = [];
  for (const item of rectangles) {
    const points = roundedPoints(item.x, item.y, item.width, item.height, item.radius, 8);
    const centre = [item.x + item.width / 2, item.y + item.height / 2];
    const color = item.color;
    for (let index = 0; index < points.length; index += 1) {
      push(values, centre, color, width, height);
      push(values, points[index], color, width, height);
      push(values, points[(index + 1) % points.length], color, width, height);
    }
  }
  return new Float32Array(values);
}

function roundedPoints(x, y, width, height, radius, steps) {
  const r = Math.min(radius, width / 2, height / 2);
  const corners = [[x + width - r, y + r, -Math.PI / 2], [x + width - r, y + height - r, 0], [x + r, y + height - r, Math.PI / 2], [x + r, y + r, Math.PI]];
  const points = [];
  for (const [cx, cy, start] of corners) {
    for (let step = 0; step <= steps; step += 1) {
      const angle = start + (step / steps) * (Math.PI / 2);
      points.push([cx + Math.cos(angle) * r, cy + Math.sin(angle) * r]);
    }
  }
  return points;
}

function push(output, point, color, width, height) {
  output.push((point[0] / width) * 2 - 1, 1 - (point[1] / height) * 2, ...color);
}

function shader(gl, type, source) {
  const value = gl.createShader(type);
  gl.shaderSource(value, source);
  gl.compileShader(value);
  if (!gl.getShaderParameter(value, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(value));
  return value;
}

function nextPowerOfTwo(value) {
  return 2 ** Math.ceil(Math.log2(value));
}
