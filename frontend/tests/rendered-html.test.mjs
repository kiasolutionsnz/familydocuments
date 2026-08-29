import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request(`http://localhost${path}`, { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the Family Documents SEO landing page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(response.headers.get("x-frame-options"), "DENY");
  assert.equal(response.headers.get("referrer-policy"), "strict-origin-when-cross-origin");
  const html = await response.text();
  assert.match(html, /<title>Family Documents — Organise Documents, Reminders &amp; Family Links<\/title>/i);
  assert.match(html, /Start your free trial/i);
  assert.match(html, /No credit card required/i);
  assert.match(html, /See how Family Documents works/i);
  assert.match(html, /Ⅱ Pause/i);
  assert.match(html, /Review the email suggestion/i);
  assert.match(html, /Forward an email/i);
  assert.match(html, /Choose one-off or repeating/i);
  assert.match(html, /For rental property owners/i);
  assert.match(html, /Organisation, not tax advice/i);
  assert.match(html, /href="\/prototype\/index\.html#auth"/i);
  assert.match(html, /rel="canonical" href="https:\/\/familydocuments\.app"/i);
  assert.match(html, /property="og:image" content="https:\/\/familydocuments\.app\/og\.png"/i);
  assert.doesNotMatch(html, /codex-preview|Building your site|react-loading-skeleton/i);
});

test("publishes complete privacy and terms routes", async () => {
  const [privacyResponse, termsResponse] = await Promise.all([render("/privacy"), render("/terms")]);
  assert.equal(privacyResponse.status, 200);
  assert.equal(termsResponse.status, 200);
  const [privacy, terms] = await Promise.all([privacyResponse.text(), termsResponse.text()]);
  assert.match(privacy, /Privacy Policy/);
  assert.match(privacy, /drive\.file/);
  assert.match(privacy, /Google API Services User Data Policy/);
  assert.match(privacy, /does not request permission to scan or list your whole Drive/i);
  assert.match(privacy, /support@familydocuments\.app/);
  assert.match(terms, /Terms of Service/);
  assert.match(terms, /will not be charged unless you expressly choose a paid plan/i);
  assert.match(terms, /keep your own backup/i);
  assert.match(terms, /New Zealand law/i);
});

test("ships isolated local auth, invitation, access and category boundaries", async () => {
  const [html, css, app, auth, data, ocr, drive] = await Promise.all([
    readFile(new URL("../public/prototype/index.html", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/styles.css", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/app.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/auth-client.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/data-client.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/ocr-client.js", import.meta.url), "utf8"),
    readFile(new URL("../public/prototype/google-drive-client.js", import.meta.url), "utf8"),
  ]);
  assert.match(html, />Overview</);
  assert.match(html, />Inbox</);
  assert.match(html, />Documents</);
  assert.match(html, />Rentals</);
  assert.match(html, />Travel</);
  assert.match(html, />Saved links</);
  assert.match(html, /href="#saved" data-route="saved"/);
  assert.match(html, /data-mobile-menu-open/);
  assert.match(html, /id="mobile-menu-dialog"/);
  assert.match(html, />Storage</);
  assert.match(html, /Family &amp; Settings/);
  assert.match(html, /href="#connections" data-route="connections"/);
  assert.doesNotMatch(html, /Local test|Synthetic household data|UI prototype/);
  assert.match(html, /src="auth-client\.js\?v=20260829-email-bin"/);
  assert.doesNotMatch(app, /Continue with Google/);
  assert.doesNotMatch(app, /data-google-signin/);
  assert.match(app, /Google Drive/);
  assert.match(app, /Create account/);
  assert.match(app, /Family Documents/);
  assert.match(app, /minlength="14"/);
  assert.match(auth, /https:\/\/api-familydocuments\.servicehub\.co\.nz\/auth/);
  assert.match(auth, /\/signup/);
  assert.match(auth, /grant_type=password/);
  assert.match(auth, /\/logout/);
  assert.match(data, /https:\/\/api-familydocuments\.servicehub\.co\.nz\/rest/);
  assert.match(data, /household_snapshot/);
  assert.match(data, /record_app_hit/);
  assert.match(app, /appHitRecorded/);
  assert.match(data, /set_document_access/);
  assert.match(data, /set_document_privacy/);
  assert.match(data, /set_access_rule/);
  assert.match(data, /permission_audit_summaries/);
  assert.match(data, /document_source/);
  assert.match(data, /purge_document/);
  assert.match(data, /manage_member/);
  assert.match(data, /transfer_household_ownership/);
  assert.match(data, /confirm_extraction/);
  assert.match(data, /create_manual_document/);
  assert.match(data, /saved_link_workspace/);
  assert.match(data, /create_saved_link_category/);
  assert.match(data, /set_saved_link_shares/);
  assert.match(app, /Save privately/);
  assert.match(app, /Everything else, clearly organised/);
  assert.match(app, /function homeFocused/);
  assert.match(app, /Needs your attention/);
  assert.match(app, /Next trip/);
  assert.match(app, /Rental snapshot/);
  assert.match(app, /Original files and app data are different/);
  assert.match(app, /This release supports Google Drive only/);
  assert.match(app, /Share → Copy link/);
  assert.match(app, /data-saved-link-form/);
  assert.match(app, /data-saved-delete/);
  assert.match(app, /noopener noreferrer/);
  assert.match(data, /household_google_drive_connection_summary/);
  assert.match(data, /travel_workspace/);
  assert.match(data, /create_travel_trip/);
  assert.match(data, /create_travel_record/);
  assert.match(data, /update_travel_trip/);
  assert.match(data, /add_trip_traveller/);
  assert.match(data, /set_trip_share/);
  assert.match(data, /add_travel_cost/);
  assert.match(data, /create_travel_itinerary_entry/);
  assert.match(data, /update_travel_itinerary_entry/);
  assert.match(app, /Travel management/);
  assert.match(app, /Create a trip manually/);
  assert.match(app, /Confirmed net cost/);
  assert.match(app, /Trip sharing does not automatically reveal restricted source documents/);
  assert.match(app, /Upcoming itinerary/);
  assert.match(app, /Add itinerary item/);
  assert.match(app, /History \(/);
  assert.match(app, /Past, completed and cancelled items stay here/);
  assert.match(css, /\.date-range/);
  assert.match(app, /Create a new trip/);
  assert.match(app, /Travel booking saved to the confirmed trip/);
  assert.match(data, /set_google_drive_folder/);
  assert.match(data, /create_google_drive_document/);
  assert.match(data, /rotate_household_inbox/);
  assert.match(data, /disable_household_inbox/);
  assert.match(data, /enable_household_inbox/);
  assert.match(data, /inbound_email_summaries/);
  assert.match(data, /inbound_email_detail/);
  assert.match(data, /inbound_sender_rule_summaries/);
  assert.match(data, /move_inbound_email_to_bin/);
  assert.match(app, /mail-row-actions/);
  assert.match(app, /data-bin-restore/);
  assert.match(app, /Delete email/);
  assert.match(app, /querySelectorAll\("\[data-bin-email\]"\)/);
  assert.match(app, /Trusted senders/);
  assert.match(app, /Unknown senders are quarantined/);
  assert.match(app, /data-open-email/);
  assert.match(ocr, /https:\/\/api-familydocuments\.servicehub\.co\.nz\/ocr/);
  assert.match(ocr, /crypto\.subtle\.digest/);
  assert.match(html, /google-drive-config\.local\.js/);
  assert.match(html, /google-drive-client\.js/);
  assert.match(drive, /https:\/\/www\.googleapis\.com\/auth\/drive\.file/);
  assert.match(drive, /initCodeClient/);
  assert.match(drive, /ux_mode:"popup"/);
  assert.match(drive, /x-requested-with/);
  assert.match(drive, /api-familydocuments\.servicehub\.co\.nz\/drive/);
  assert.match(drive, /selectFolder/);
  assert.match(drive, /createFolder/);
  assert.match(drive, /content_base64/);
  assert.match(drive, /openDocument/);
  assert.match(drive, /refreshSession/);
  assert.doesNotMatch(drive, /drive\.readonly|auth\/drive["'`]/);
  assert.match(data, /register_google_drive_source/);
  assert.match(data, /link_google_drive_source/);
  assert.match(data, /update_google_drive_source/);
  assert.match(data, /edit_document_metadata/);
  assert.match(data, /merge_documents/);
  assert.match(data, /explain_document_access/);
  assert.match(data, /household_export/);
  assert.match(data, /rental_property_workspace/);
  assert.match(data, /create_rental_property/);
  assert.match(data, /create_rental_bill/);
  assert.match(data, /set_rental_bill_status/);
  assert.match(data, /rental_property_export/);
  assert.match(app, /Connect household Google Drive/);
  assert.match(app, /Reconnect Google Drive/);
  assert.match(app, /Reconnect required/);
  assert.match(drive, /drive_upload_failed/);
  assert.match(drive, /folder_unavailable/);
  assert.match(app, /do not need Google folder access/);
  assert.match(app, /Why can I see this\?/);
  assert.match(html, /document-preview-dialog/);
  assert.match(data, /disconnect_google_drive/);
  assert.match(app, /data-invite-form/);
assert.match(app, /Invite family/);
assert.match(app, /const safe=async\(task,fallback\)/);
  assert.match(app, /Default deny/);
  assert.match(app, /Default private/);
  assert.match(app, /data-access-rule-form/);
  assert.match(app, /individual shares were preserved/);
  assert.match(app, /Multi-factor protection/);
  assert.match(app, /Permanently delete this record/);
  assert.match(app, /data-member-manage/);
  assert.match(auth, /\/factors/);
  assert.match(auth, /assuranceLevel/);
  assert.match(auth, /logout\?scope=global/);
  assert.match(auth, /\/recover/);
  assert.match(auth, /\/authorize\?provider=google/);
  assert.match(auth, /family-passport-google-oauth/);
  assert.match(auth, /googleAvailable/);
  assert.doesNotMatch(auth, /localStorage/);
  assert.match(auth, /sessionStorage\.getItem\(refreshStorageKey\)/);
  assert.match(auth, /grant_type=refresh_token/);
  assert.match(auth, /restoreSession/);
  assert.match(data, /response\.status === 401/);
  assert.match(app, /setInterval\(refreshLiveStatus,15000\)/);
  assert.match(app, /visibilitychange/);
  assert.match(html, /rel="icon" type="image\/svg\+xml" href="\/favicon\.svg"/);
  assert.match(html, /class="brand-mark"[^>]*><img src="\/favicon\.svg"/);
  assert.match(app, /data-category-form/);
  assert.match(app, /data-manual-upload/);
  assert.match(app, /Upload file/);
  assert.match(app, /Upload with OCR/);
  assert.match(app, /OCR is optional/);
  assert.match(app, /capture="environment"/);
  assert.match(app, /Where documents are organised/);
  assert.match(app, /One household connection/);
  assert.match(app, /data-choose-drive-folder/);
  assert.match(app, /data-connect-drive/);
  assert.match(app, /data-create-drive-folder/);
  assert.match(app, /Create and use this folder/);
  assert.match(app, /Upload original to/);
  assert.match(app, /Google Drive — .* \(default\)/);
  assert.match(app, /Suggested category/);
  assert.match(app, /Household inbox/);
  assert.match(app, /data-copy-inbox/);
  assert.match(app, /Received email/);
  assert.match(app, /Signed in as:/);
  assert.match(app, /Help with this page/);
  assert.match(app, /setInboxAlias/);
  assert.match(app, /quarantined/);
  assert.match(app, /name="dueTime" type="time"/);
  assert.match(app, /confirmed_due_time/);
  assert.match(app, /Pacific\/Auckland time/);
  assert.match(app, /due_time_zone/);
  assert.match(app, /Add a rental property/);
  assert.match(app, /Add a rental bill/);
  assert.match(app, /Download accountant CSV/);
  assert.match(app, /Suggestions use previously confirmed providers/);
  assert.match(app, /What kind of record is this/);
  assert.match(app, /data-scope-panel="rental"/);
  assert.match(app, /data-scope-panel="financial_statement"/);
  assert.match(app, /data-reminder-fields/);
  assert.match(app, /Choose one and we’ll show only the details you need/);
  assert.match(app, /Tax\/IR supporting record/);
  assert.match(app, /Add a new rental property/);
  assert.match(app, /Invoice number/);
  assert.match(app, /Create a personal reminder/);
  assert.match(app, /Nothing saved automatically/);
  assert.match(data, /create_rental_record/);
  assert.match(css, /\.auth-page/);
  assert.match(css, /@media\(max-width:760px\)/);
  assert.match(css, /\.more-grid/);
  assert.match(css, /\.mobile-drawer/);
  assert.match(css, /\.mobile-global-search/);
  const mobileNav=html.match(/<nav class="mobile-nav"[\s\S]*?<\/nav>/)?.[0]||"";
  assert.equal((mobileNav.match(/data-route=/g)||[]).length,5);
  for(const label of ["Overview","Inbox","Favourites","Rentals","Travel"])assert.match(mobileNav,new RegExp(`>${label}<`));
  for(const label of ["Documents","Search","Storage","Family &amp; Settings","Privacy Policy","Terms","Sign out"])assert.match(html,new RegExp(label));
  assert.doesNotMatch(html, /class="mobile-add"/);
  assert.doesNotMatch(html, /class="add-button"/);
  for (const source of [html, css, app, auth, data, ocr, drive]) {
    for (const forbidden of [/localStorage/, /indexedDB/, /WebSocket/]) {
      assert.doesNotMatch(source, forbidden);
    }
  }
  for (const source of [html, css, app]) {
    for (const forbidden of [/fetch\s*\(/, /localStorage/, /sessionStorage/, /indexedDB/, /WebSocket/]) {
      assert.doesNotMatch(source, forbidden);
    }
  }
});
