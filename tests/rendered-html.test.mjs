import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

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

test("server-renders the Family Passport prototype shell", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /<title>Family Passport — Interactive prototype<\/title>/i);
  assert.match(html, /src="\/prototype\/index\.html"/i);
  assert.match(html, /title="Family Passport interactive prototype"/i);
  assert.doesNotMatch(html, /codex-preview|Building your site|react-loading-skeleton/i);
});

test("ships explicit synthetic auth, invitation, access and category boundaries", async () => {
  const [html, css, app] = await Promise.all([
    readFile(new URL("../public/prototype/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/app.js", import.meta.url), "utf8"),
  ]);
  assert.match(html, /Synthetic household data · no information is saved/);
  assert.match(app, /Continue with Google/);
  assert.match(app, /Create account with email/);
  assert.match(app, /credentials are not sent or saved/);
  assert.match(app, /data-invite-form/);
  assert.match(app, /Default deny/);
  assert.match(app, /data-category-form/);
  assert.match(css, /\.auth-page/);
  assert.match(css, /@media\(max-width:760px\)/);
  for (const source of [html, css, app]) {
    for (const forbidden of [/fetch\s*\(/, /localStorage/, /sessionStorage/, /indexedDB/, /WebSocket/]) {
      assert.doesNotMatch(source, forbidden);
    }
  }
});

