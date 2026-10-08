// node design/icon/png.mjs —— 把 build/ 里的 SVG 渲染成各平台要的 PNG（借用博客仓库里的 Playwright 与本机 Chrome）。
import { createRequire } from "node:module";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
const require = createRequire("/Users/chen/Documents/blog/package.json");
const { chromium } = require("playwright");
const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, "../..");
const res = path.join(root, "android/app/src/main/res");
const densities = { mdpi: 108, hdpi: 162, xhdpi: 216, xxhdpi: 324, xxxhdpi: 432 };
const jobs = [];
for (const [d, px] of Object.entries(densities)) {
  for (const layer of ["foreground", "background", "monochrome"]) {
    jobs.push([`build/android-${layer}.svg`, px, path.join(res, `mipmap-${d}`, `ic_launcher_${layer}.png`)]);
  }
}
const site = path.join(root, "site/assets");
for (const [px, name] of [[512, "icon-512.png"], [180, "apple-touch-icon.png"]]) {
  jobs.push(["riji.svg", px, path.join(site, name)]);
}
const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage();
for (const [svg, px, out] of jobs) {
  mkdirSync(path.dirname(out), { recursive: true });
  await page.setViewportSize({ width: px, height: px });
  const html = path.join(here, "build", "_render.html");
  writeFileSync(html, `<html><body style="margin:0;background:transparent"><img src="${path.join(here, svg)}" style="width:${px}px;height:${px}px;display:block"></body></html>`);
  await page.goto("file://" + html);
  await page.waitForLoadState("load");
  await page.screenshot({ path: out, omitBackground: true });
}
await browser.close();
console.log(`${jobs.length} png`);
