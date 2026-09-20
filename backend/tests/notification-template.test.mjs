import test from "node:test";
import assert from "node:assert/strict";
import {renderNotificationHtml} from "../notifications/template.mjs";

test("renders a branded, mobile-friendly invitation with a safe action",()=>{
  const html=renderNotificationHtml({kind:"invitation",subject:"You’re invited to the Chauhan family",body_text:"Inder invited you to join.\nThis invitation expires on 02 Sep 2026."});
  assert.match(html,/Family Documents/);
  assert.match(html,/Open Family Documents/);
  assert.match(html,/familydocuments\.app\/app\//);
  assert.match(html,/one-time family invitation, not a marketing subscription/);
  assert.match(html,/support@familydocuments\.app/);
  assert.match(html,/viewport/);
  assert.doesNotMatch(html,/tracking|pixel/i);
});

test("escapes database content before inserting it into HTML",()=>{
  const html=renderNotificationHtml({kind:"invitation",subject:'Invite <script>alert("x")</script>',body_text:"Family & friends"});
  assert.doesNotMatch(html,/<script>/);
  assert.match(html,/&lt;script&gt;/);
  assert.match(html,/Family &amp; friends/);
});

test("keeps reminder emails free of invitation actions",()=>{
  const html=renderNotificationHtml({kind:"reminder",subject:"Passport renewal",body_text:"Due tomorrow."});
  assert.match(html,/FAMILY REMINDER/);
  assert.doesNotMatch(html,/Open Family Documents/);
  assert.match(html,/creator can change the reminder audience/);
  assert.match(html,/want email delivery stopped/);
});
