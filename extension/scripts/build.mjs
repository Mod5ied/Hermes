import { access, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const requested = process.argv[2] ?? "all";
const targets = requested === "all" ? ["chrome", "firefox"] : [requested];
if (!targets.every((target) => ["chrome", "firefox"].includes(target))) {
  throw new Error(`unknown build target: ${requested}`);
}

for (const target of targets) {
  const output = join(root, "dist", target);
  await rm(output, { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  await cp(join(root, "src"), join(output, "src"), { recursive: true });
  const contentFiles = [
    "src/shared/core.js",
    "src/render/gpu-renderer.js",
    "src/audio/pipeline.js",
    "src/content/app.js",
    "src/content/index.js",
  ];
  const contentSource = [];
  for (const file of contentFiles) {
    const source = await readFile(join(root, file), "utf8");
    contentSource.push(source.replace(/^import .*;\s*$/gm, "").replace(/^export /gm, ""));
  }
  await writeFile(join(output, "src", "content-bundle.js"), `(function hermesContentBundle(){\n${contentSource.join("\n")}\n})();\n`);
  const iconOutput = join(output, "icons");
  const nativeIcons = resolve(root, "..", "assets", "AppIcon.iconset");
  await mkdir(iconOutput, { recursive: true });
  await cp(join(nativeIcons, "icon_16x16.png"), join(iconOutput, "icon-32.png"));
  await cp(join(nativeIcons, "icon_32x32@2x.png"), join(iconOutput, "icon-128.png"));
  const wasmArtifact = join(root, "rust", "audio-dsp", "target", "wasm32-unknown-unknown", "release", "hermes_audio_dsp.wasm");
  try {
    await access(wasmArtifact);
    await mkdir(join(output, "wasm"), { recursive: true });
    await cp(wasmArtifact, join(output, "wasm", "audio_dsp.wasm"));
  } catch { /* A JS DSP fallback is always included. */ }
  if (target === "firefox") {
    await rm(join(output, "src", "background.js"), { force: true });
    await rm(join(output, "src", "audio", "offscreen.html"), { force: true });
    await rm(join(output, "src", "audio", "offscreen.js"), { force: true });
  } else {
    await rm(join(output, "src", "background-firefox.js"), { force: true });
  }
  const manifest = JSON.parse(await readFile(join(root, "manifests", `${target}.json`), "utf8"));
  await writeFile(join(output, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}
