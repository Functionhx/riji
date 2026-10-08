// node design/icon/render.mjs <html> <png> [width] —— 用本机 Chrome 把页面渲染成 PNG（借用博客仓库里的 Playwright）。
import { createRequire } from "node:module";
import path from "node:path";
const require = createRequire("/Users/chen/Documents/blog/package.json");
const { chromium } = require("playwright");
const [input, output, width = "1200", height = "800", scale = "2"] = process.argv.slice(2);
const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage({ viewport: { width: +width, height: +height }, deviceScaleFactor: +scale });
await page.goto("file://" + path.resolve(input));
await page.waitForTimeout(300);
await page.screenshot({ path: output, fullPage: true });
await browser.close();
