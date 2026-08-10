import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const templateRoot = new URL("../", import.meta.url);

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the EchoScribe upload experience", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>EchoScribe — private, free audio transcription<\/title>/i);
  assert.match(html, /Turn audio into words/);
  assert.match(html, /Drop your audio here/);
  assert.match(html, /Transcribe for free/);
  assert.match(html, /Your transcript will appear here/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Building your site/i);
});

test("removes the disposable starter preview", async () => {
  const [page, layout, packageJson] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("package.json", templateRoot), "utf8"),
  ]);

  assert.match(page, /\"use client\"/);
  assert.match(page, /automatic-speech-recognition/);
  assert.match(page, /Xenova\/whisper-tiny/);
  assert.match(page, /value="spanish"/);
  assert.match(page, /language,/);
  assert.match(page, /audio\/*/);
  assert.match(page, /convertToWav/);
  assert.match(page, /AMR/);
  assert.match(page, /unpkg\.com/);
  assert.match(layout, /EchoScribe/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
});
