import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveRelativeDueDate,resolveRelativeDueTime,resolveRelativeDue} from '../email-ingestion/relative-date.mjs';

const reference=new Date('2026-08-24T00:17:11Z'); // 12:17 PM in Auckland.
test('resolves tomorrow in Pacific/Auckland',()=>assert.equal(resolveRelativeDueDate('remind me tomorrow at 12pm',reference),'2026-08-25'));
test('resolves next Friday strictly after the reference day',()=>assert.equal(resolveRelativeDueDate('renew this next Friday',reference),'2026-08-28'));
test('resolves word-number week intervals',()=>assert.equal(resolveRelativeDueDate('check again in two weeks',reference),'2026-09-07'));
test('resolves numeric week intervals',()=>assert.equal(resolveRelativeDueDate('check again in 2 weeks',reference),'2026-09-07'));
test('leaves unsupported wording for human review',()=>assert.equal(resolveRelativeDueDate('sometime soon',reference),null));
test('extracts noon as structured local time',()=>assert.equal(resolveRelativeDueTime('remind me tomorrow at 12pm'),'12:00:00'));
test('extracts midnight correctly',()=>assert.equal(resolveRelativeDueTime('tomorrow 12:15 am'),'00:15:00'));
test('extracts 24-hour time only with an at prefix',()=>assert.equal(resolveRelativeDueTime('renew next Friday at 09:30'),'09:30:00'));
test('returns a date, time and explicit timezone together',()=>assert.deepEqual(resolveRelativeDue('tomorrow at 12pm',reference),{date:'2026-08-25',time:'12:00:00',timeZone:'Pacific/Auckland'}));
