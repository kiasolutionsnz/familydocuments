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

test("ships isolated local auth, invitation, access and category boundaries", async () => {
  const [html, css, app, auth, data, ocr] = await Promise.all([
    readFile(new URL("../public/prototype/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/app.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/auth-client.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/data-client.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/ocr-client.js", import.meta.url), "utf8"),
  ]);
  assert.match(html, /accounts use isolated local authentication/);
  assert.match(html, /src="auth-client\.js"/);
  assert.match(app, /Continue with Google/);
  assert.match(app, /Create local account/);
  assert.match(app, /127\.0\.0\.1:55321/);
  assert.match(app, /minlength="14"/);
  assert.match(auth, /http:\/\/127\.0\.0\.1:55321/);
  assert.match(auth, /\/signup/);
  assert.match(auth, /grant_type=password/);
  assert.match(auth, /\/logout/);
  assert.match(data, /http:\/\/127\.0\.0\.1:55322/);
  assert.match(data, /household_snapshot/);
  assert.match(data, /set_document_access/);
  assert.match(data, /confirm_extraction/);
  assert.match(ocr, /http:\/\/127\.0\.0\.1:55323/);
  assert.match(ocr, /crypto\.subtle\.digest/);
  assert.match(app, /data-invite-form/);
  assert.match(app, /Default deny/);
  assert.match(app, /data-category-form/);
  assert.match(css, /\.auth-page/);
  assert.match(css, /@media\(max-width:760px\)/);
  for (const source of [html, css, app, auth, data, ocr]) {
    for (const forbidden of [/localStorage/, /sessionStorage/, /indexedDB/, /WebSocket/]) {
      assert.doesNotMatch(source, forbidden);
    }
  }
  for (const source of [html, css, app]) {
    for (const forbidden of [/fetch\s*\(/, /localStorage/, /sessionStorage/, /indexedDB/, /WebSocket/]) {
      assert.doesNotMatch(source, forbidden);
    }
  }
});
