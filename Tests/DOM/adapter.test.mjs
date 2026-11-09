// Offline check of the embedded DOM adapter against a synthetic page. Dev-only; not part of `swift test`.
// PLAYWRIGHT_MODULE=/path/to/playwright-core/index.mjs CHROME_PATH=/path/to/chrome node --test Tests/DOM
// The app identity (dsh-app://app) is injected as a lexical `location`; the real identity check is covered by the Swift tests.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE);
const source = readFileSync(fileURLToPath(new URL('../../Sources/DSHControlCore/Page.swift', import.meta.url)), 'utf8');
const script = source.match(/#"""\n([\s\S]*?)\n\s*"""#/)[1];
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] });
test.after(() => browser.close());

const composer = (extra = '') => `<div id="area"><div data-composer-input contenteditable="true">hi</div>
  <button aria-label="Send message">s</button>${extra}</div>`;
const page = (body, lang = 'en') => `<html lang="${lang}"><body><div id="nav">
  <button data-row-key="s1">Session A · 5m ago</button><button data-row-key="s2">Session B · 6m ago</button>
  <button aria-label="Plugins">Plugins</button></div>${body}</body></html>`;

async function run(html, request) {
  const p = await browser.newPage();
  await p.setContent(html);
  // Keep the epoch fixed so separate fixture pages isolate UI changes rather than document creation.
  const call = (req) => p.evaluate(`((location, performance) => (${script}))({origin:'dsh-app://app',href:'dsh-app://app/'},{timeOrigin:1})(${JSON.stringify(req)})`);
  const snapshot = await call({ action: 'inspect', sessionId: request.sessionId });
  const result = await call({ ...request, guard: request.guard ?? snapshot.guard });
  await p.close();
  return { snapshot, result };
}
const code = ({ result }) => result.error?.code;
const ref = (snapshot, key) => snapshot.controls.find((c) => c.key === key).ref;

test('refs use row keys, not relative-time text, and hit-test normally', async () => {
  const { snapshot } = await run(page(composer()), { action: 'inspect' });
  const r = ref(snapshot, 's1');
  assert.ok(!r.includes('ago'));
  const again = await run(page(composer()).replace('5m ago', '9m ago'), { action: 'prepare', purpose: 'click', ref: r });
  assert.equal(again.result.error, undefined);
  assert.equal(code(await run(page(composer()), { action: 'prepare', purpose: 'click', ref: 'nope' })), 'ambiguous_control');
});

test('navigation works without a composer; draft does not', async () => {
  const html = page('');
  const nav = await run(html, { action: 'prepare', purpose: 'click', ref: JSON.stringify({ role: 'button', name: 'Plugins', key: null, model: null, provider: null }) });
  assert.equal(nav.result.error, undefined);
  assert.equal(code(await run(html, { action: 'prepare', purpose: 'draft' })), 'unsupported_ui');
});

test('multiple composers and unknown locales fail closed', async () => {
  const two = page(composer() + composer());
  assert.equal(code(await run(two, { action: 'prepare', purpose: 'draft' })), 'unsupported_ui');
  assert.equal(code(await run(two, { action: 'scroll', direction: 'down' })), 'unsupported_ui');
  assert.equal(code(await run(page(composer(), 'fr'), { action: 'prepare', purpose: 'click', ref: '' })), 'unsupported_ui');
});

test('guard notices overlays and running state', async () => {
  const base = await run(page(composer()), { action: 'inspect' });
  const menu = await run(page(composer() + '<div role="menu">m</div>'), { action: 'prepare', purpose: 'draft', guard: base.snapshot.guard });
  assert.equal(code(menu), 'stale_state');
  const running = await run(page(composer() + '<div data-chat-running>…</div>'), { action: 'prepare', purpose: 'draft', guard: base.snapshot.guard });
  assert.equal(code(running), 'stale_state');
});

test('two Send buttons are ambiguous', async () => {
  const html = page(composer('<button aria-label="Send message">s2</button>'));
  assert.equal(code(await run(html, { action: 'prepare', purpose: 'send' })), 'ambiguous_control');
});

test('capabilities describe actions that are currently ready', async () => {
  for (const overlay of ['<div role="dialog">Confirm</div>', '<div role="menu">Model</div>']) {
    const { snapshot, result } = await run(page(composer() + overlay), { action: 'prepare', purpose: 'send' });
    assert.equal(snapshot.capabilities.send, false);
    assert.equal(snapshot.capabilities.draft, false);
    assert.equal(result.error.code, 'blocked');
  }
  const duplicate = await run(page(composer('<button aria-label="Send message">s2</button>')), { action: 'inspect' });
  assert.equal(duplicate.snapshot.capabilities.send, false);
  const command = await run(page(composer().replace('>hi</div>', '>/help</div>')), { action: 'prepare', purpose: 'send' });
  assert.equal(command.snapshot.capabilities.send, false);
  assert.equal(command.result.error.code, 'unsupported_command');
});

const userRow = (slots, key = 'u1') => `<div data-chat-node-key="${key}" data-chat-flow-kind="user" data-chat-turn="t1">${slots}
  <div data-clock="start">Oct 21, 12:30 <button aria-label="Copy">Copy</button></div></div>`;
const slot = (t) => `<span data-slot="conversation.user.text.node" style="display: contents;"><span class="plainRun">${t}</span></span>`;

test('user body comes from text slots only, excluding timestamp and Copy', async () => {
  const one = (await run(page(composer() + userRow(slot('مرحبا 👋'))), { action: 'inspect' })).snapshot.messages[0];
  assert.equal(one.body, 'مرحبا 👋');
  assert.ok(one.text.includes('12:30'));
  const two = (await run(page(composer() + userRow(slot('line one') + slot('line two'))), { action: 'inspect' })).snapshot.messages[0];
  assert.equal(two.body, 'line one\nline two');
  const none = (await run(page(composer() + userRow('<span>hello</span>')), { action: 'inspect' })).snapshot.messages[0];
  assert.equal(none.body, null);
  const assistant = page(composer() + '<div data-chat-node-key="a1" data-chat-flow-kind="assistant">' + slot('x') + '</div>');
  assert.equal((await run(assistant, { action: 'inspect' })).snapshot.messages[0].body, null);
});

test('guard is sensitive to the renderer epoch', async () => {
  const { snapshot } = await run(page(composer()), { action: 'inspect' });
  assert.equal(typeof snapshot.guard.epoch, 'number');
  const reloaded = await run(page(composer()), { action: 'prepare', purpose: 'draft', guard: { ...snapshot.guard, epoch: snapshot.guard.epoch - 1 } });
  assert.equal(code(reloaded), 'stale_state');
});

test('Chinese labels enable send and stop', async () => {
  const zh = page('<div><div data-composer-input contenteditable="true">hi</div><button aria-label="发送消息">s</button></div>', 'zh-CN');
  const sent = await run(zh, { action: 'prepare', purpose: 'send' });
  assert.equal(sent.snapshot.capabilities.send, true);
  assert.equal(sent.result.error, undefined);
  const running = page('<div><div data-composer-input contenteditable="true"></div><button aria-label="停止生成">x</button><div data-chat-running></div></div>', 'zh');
  const stop = await run(running, { action: 'prepare', purpose: 'cancel' });
  assert.equal(stop.snapshot.capabilities.cancel, true);
  assert.equal(stop.result.error, undefined);
});

test('enabled scoped Stop control identifies a yielding turn without streaming markers', async () => {
  for (const [lang, label] of [['en', 'Stop generating'], ['zh', '停止生成']]) {
    const body = disabled => occurrence('parent', `<div><div data-composer-input contenteditable="true"></div><button aria-label="${label}" ${disabled ? 'disabled' : ''}>x</button></div>`);
    const running = await run(page(body(false), lang), { action: 'prepare', purpose: 'cancel' });
    assert.equal(running.snapshot.running, true);
    assert.equal(running.snapshot.capabilities.cancel, true);
    assert.equal(running.result.error, undefined);
    const disabled = await run(page(body(true), lang), { action: 'inspect' });
    assert.equal(disabled.snapshot.running, false);
  }
  const scoped = await run(page(occurrence('parent', composer()) + child(`<div><div data-composer-input contenteditable="true"></div><button aria-label="Stop generating">x</button></div>`)), { action: 'inspect', sessionId: 'parent' });
  assert.equal(scoped.snapshot.running, false);
});

test('truncation keeps Unicode valid in messages, bodies and notices', async () => {
  const html = page(composer() + userRow(slot('a'.repeat(11999) + '😀')) +
    '<div role="dialog">' + 'a'.repeat(1499) + '😀</div><div role="alert">' + 'a'.repeat(1499) + '😀</div>');
  const { snapshot } = await run(html, { action: 'inspect' });
  const message = snapshot.messages[0];
  assert.equal(message.truncated, true);
  assert.equal(message.bodyTruncated, true);
  for (const value of [message.text, message.body, ...snapshot.dialogs, ...snapshot.alerts]) assert.equal(value.isWellFormed(), true);
});

test('modal keeps underlying chat observable while preventing interaction', async () => {
  const html = page('<div id="root" inert>' + composer() + userRow(slot('hi')) +
    '<div data-chat-running>Working</div></div><div role="dialog">Permission required</div>');
  const { snapshot, result } = await run(html, { action: 'prepare', purpose: 'draft' });
  assert.equal(snapshot.messages.length, 1);
  assert.equal(snapshot.running, true);
  assert.equal(snapshot.draft, 'hi');
  assert.equal(snapshot.status, 'blocked');
  assert.equal(snapshot.capabilities.draft, false);
  assert.equal(result.error.code, 'blocked');
});

test('rc.3 overflow entries expose current navigation and invalidate old guards', async () => {
  const navigation = current => `<nav aria-label="Global panels"><button aria-label="Plugins" aria-current="${current === 'plugins' ? 'page' : 'false'}">Plugins</button>
    <button aria-label="More" aria-haspopup="menu" aria-expanded="false">More</button></nav>
    <button aria-label="More conversation views" aria-haspopup="menu" aria-expanded="true">More views</button>
    <div role="menu"><button role="menuitem" aria-current="${current === 'trajectory' ? 'page' : 'false'}">Trajectory</button></div>`;
  const before = await run(page(composer() + navigation('plugins')), { action: 'inspect' });
  assert.equal(before.snapshot.controls.find(c => c.name === 'Plugins' && c.current)?.current, true);
  const after = await run(page(composer() + navigation('trajectory')), { action: 'inspect' });
  const trajectory = after.snapshot.controls.find(c => c.name === 'Trajectory');
  assert.equal(trajectory.current, true);
  assert.notDeepEqual(after.snapshot.guard.navigation, before.snapshot.guard.navigation);
  const stale = await run(page(composer() + navigation('trajectory')), { action: 'prepare', purpose: 'click', ref: trajectory.ref, guard: before.snapshot.guard });
  assert.equal(code(stale), 'stale_state');
  const launchers = after.snapshot.controls.filter(c => c.popup === 'menu');
  assert.equal(launchers.length, 2);
  assert.notEqual(launchers[0].ref, launchers[1].ref);
});

test('rc.3 plugin creation is blocked and scroll-following current markers do not affect navigation', async () => {
  const html = current => page(composer() + `<button aria-label="Jump to turn 1" aria-current="${current ? 'true' : 'false'}">1</button>`);
  const before = await run(html(false), { action: 'inspect' });
  const after = await run(html(true), { action: 'inspect' });
  assert.deepEqual(before.snapshot.guard.navigation, after.snapshot.guard.navigation);
  assert.equal(after.snapshot.controls.find(c => c.name === 'Jump to turn 1').current, false);
  for (const label of ['Create your plugin', '创建你的插件']) {
    const content = page(composer() + `<div role="menu"><button role="menuitem">${label}</button></div>`);
    const { snapshot } = await run(content, { action: 'inspect' });
    const blocked = await run(content, { action: 'prepare', purpose: 'click', ref: snapshot.controls.find(c => c.name === label).ref });
    assert.equal(code(blocked), 'dedicated_command');
  }
});

const occurrence = (id, content, extra = '') => `<section data-conversation-content data-conversation-session="${id}" data-content-phase="active" ${extra}>${content}</section>`;
const child = content => `<aside data-sidebar-chat>${occurrence('child', content)}</aside>`;

test('parent and child occurrences isolate editors, messages, running and interactions', async () => {
  const html = page(occurrence('parent', composer() + userRow(slot('parent body'), 'parent-user') +
    child(composer().replace('>hi</div>', '>child draft</div>') + userRow(slot('child body'), 'child-user') +
      '<div data-chat-running>Working</div><div data-approval-key="approve-child">Approve</div>')));
  const parent = (await run(html, { action: 'inspect' })).snapshot;
  assert.equal(parent.session.id, 'parent');
  assert.equal(parent.displayedSessionId, 'parent');
  assert.equal(parent.surface, 'main');
  assert.equal(parent.viewKind, 'main');
  assert.equal(parent.draft, 'hi');
  assert.equal(parent.running, false);
  assert.deepEqual(parent.messages.map(message => message.key), ['parent-user']);
  assert.deepEqual(parent.pendingInteractions, []);
  assert.equal(parent.composer.locked, false);
  assert.equal(parent.capabilities.send, true);
  assert.deepEqual(parent.subagents.map(agent => [agent.id, agent.status]), [['child', 'running']]);
  assert.equal(parent.subagents[0].loaded, true);
  const selected = await run(html, { action: 'inspect', sessionId: 'child' });
  assert.equal(selected.result.session.id, 'child');
  assert.equal(selected.result.displayedSessionId, 'parent');
  assert.equal(selected.result.surface, 'sidebar');
  assert.equal(selected.result.viewKind, 'subagent');
  assert.equal(selected.result.draft, 'child draft');
  assert.equal(selected.result.running, true);
  assert.deepEqual(selected.result.messages.map(message => message.key), ['child-user']);
  assert.equal(selected.result.pendingInteractions[0].key, 'approve-child');
  assert.equal(selected.result.composer.locked, true);
});

test('a nested child row cannot leak into a parent user body or rendered row text', async () => {
  const nested = userRow(slot('parent text') + child(userRow(slot('private child'), 'child-user')));
  const result = await run(page(occurrence('parent', composer() + nested)), { action: 'inspect' });
  assert.equal(result.snapshot.messages.length, 1);
  assert.equal(result.snapshot.messages[0].body, 'parent text');
  assert.ok(!result.snapshot.messages[0].text.includes('private child'));
});

test('success alerts are notices while approvals and questions block the selected composer', async () => {
  const base = occurrence('parent', composer());
  const toast = await run(page(base + '<div role="alert">Saved successfully</div>'), { action: 'prepare', purpose: 'send' });
  assert.equal(toast.snapshot.status, 'idle');
  assert.equal(toast.snapshot.notices[0].text, 'Saved successfully');
  assert.equal(toast.snapshot.capabilities.send, true);
  assert.equal(toast.result.error, undefined);
  for (const kind of ['approval', 'question']) {
    const html = page(occurrence('parent', composer() + `<div data-${kind}-key="pending"><button>Respond</button></div>`));
    const pending = await run(html, { action: 'prepare', purpose: 'send' });
    assert.equal(pending.snapshot.status, 'blocked');
    assert.equal(pending.snapshot.pendingInteractions[0].kind, kind);
    assert.equal(pending.snapshot.capabilities.send, false);
    assert.equal(code(pending), 'composer_locked');
  }
});

test('readonly, disabled and replacement composers refuse input before dispatch', async () => {
  for (const body of [composer().replace('contenteditable="true"', 'contenteditable="false"'),
    composer().replace('contenteditable="true"', 'contenteditable="true" aria-disabled="true"'),
    '<div data-composer-seat><div role="status">One-shot child is read-only</div></div>']) {
    const locked = await run(page(occurrence('child', body)), { action: 'prepare', purpose: 'draft' });
    assert.equal(locked.snapshot.composer.locked, true);
    assert.equal(locked.snapshot.capabilities.draft, false);
    assert.equal(code(locked), 'composer_locked');
  }
});

test('offscreen or ambiguous session occurrences never fall back to another composer', async () => {
  const html = page(occurrence('parent', composer()) + occurrence('offscreen', composer(), 'hidden'));
  const missing = await run(html, { action: 'inspect', sessionId: 'offscreen' });
  assert.equal(missing.result.uiAvailable, false);
  assert.equal(missing.result.session.id, 'offscreen');
  assert.equal(missing.result.displayedSessionId, 'parent');
  assert.equal(missing.result.surface, 'unknown');
  assert.deepEqual(missing.result.controls, []);
  assert.deepEqual(missing.result.messages, []);
  assert.equal(missing.result.capabilities.draft, false);
  const duplicate = await run(page(occurrence('same', composer()) + child(occurrence('same', composer()))), { action: 'inspect', sessionId: 'same' });
  assert.equal(duplicate.result.uiAvailable, false);
});

test('guards bind session, surface and content phase and preserve bounded metadata', async () => {
  const body = composer() + Array.from({ length: 82 }, (_, i) => userRow(slot('body'), `u${i}`)).join('');
  const before = (await run(page(occurrence('parent', body)), { action: 'inspect' })).snapshot;
  assert.equal(before.guard.conversationSession, 'parent');
  assert.equal(before.guard.surface, 'main');
  assert.equal(before.guard.contentPhase, 'active');
  assert.equal(before.messages.length, 80);
  assert.equal(before.messages[0].key, 'u2');
  const changed = await run(page(occurrence('other', composer())), { action: 'prepare', purpose: 'draft', guard: before.guard });
  assert.equal(code(changed), 'stale_state');
});

test('controls group navigation, composer and message actions and expose model provider IDs', async () => {
  const html = page(occurrence('parent', composer('<button aria-haspopup="menu" data-model-id="model" data-provider-id="provider">Model</button>') + userRow(slot('body'))));
  const { snapshot } = await run(html, { action: 'inspect' });
  assert.equal(snapshot.controls.find(control => control.key === 's1').group, 'sidebar');
  assert.equal(snapshot.controls.find(control => control.name === 'Send message').group, 'composer');
  assert.equal(snapshot.controls.find(control => control.name === 'Copy').group, 'messages');
  assert.deepEqual(snapshot.controls.filter(control => control.model).map(control => [control.model, control.provider]), [['model', 'provider']]);
});

test('generic click cannot execute slash or reference trigger menu options', async () => {
  for (const marker of ['data-trigger-menu', 'data-composer-command']) {
    const html = page(occurrence('parent', composer() + `<div ${marker}><button role="option">Run command</button></div>`));
    const { snapshot } = await run(html, { action: 'inspect' });
    const result = await run(html, { action: 'prepare', purpose: 'click', ref: snapshot.controls.find(control => control.name === 'Run command').ref });
    assert.equal(code(result), 'dedicated_command');
  }
});

test('selected native skill with no arguments remains a sendable ordinary slash prompt', async () => {
  const html = page(occurrence('parent', `<div><div data-composer-input contenteditable="true">/ponytail-help </div><button aria-label="Send message">s</button></div>`));
  const denied = await run(html, { action: 'prepare', purpose: 'send' });
  assert.equal(code(denied), 'unsupported_command');
  const allowed = await run(html, { action: 'prepare', purpose: 'send', allowSlash: true });
  assert.equal(typeof allowed.result.x, 'number');
  assert.deepEqual(allowed.snapshot.commands, []);
});

test('native file chip stays a reference and permits only an append caret after it', async () => {
  const p = await browser.newPage();
  try {
    await p.setContent(page(occurrence('parent', `<div><div data-composer-input contenteditable="true"><p><span data-composer-chip="reference" contenteditable="false"><span title="attachment-brief.md">attachment-brief.md</span></span> </p></div><button aria-label="Send message">s</button></div>`)));
    const call = req => p.evaluate(`((location, performance) => (${script}))({origin:'dsh-app://app',href:'dsh-app://app/'},{timeOrigin:1})(${JSON.stringify(req)})`);
    const snapshot = await call({ action: 'inspect' });
    assert.equal(snapshot.attachmentCount, 0);
    assert.equal(snapshot.references[0].title, 'attachment-brief.md');
    await p.locator('[data-composer-input]').focus();
    await p.evaluate(() => {
      const editor = document.querySelector('[data-composer-input]'), range = document.createRange();
      range.selectNodeContents(editor); range.collapse(false);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    });
    assert.equal((await call({ action: 'appendReady', guard: snapshot.guard })).ready, true);
    assert.equal(await p.locator('[data-composer-chip="reference"]').count(), 1);
  } finally { await p.close(); }
});

test('selection readiness waits for scoped select-all without relying on animation frames', async () => {
  const p = await browser.newPage();
  try {
    await p.setContent(page(occurrence('parent', composer()) + child(composer())));
    const call = req => p.evaluate(`((location, performance) => (${script}))({origin:'dsh-app://app',href:'dsh-app://app/'},{timeOrigin:1})(${JSON.stringify(req)})`);
    const snapshot = await call({ action: 'inspect' });
    await p.locator('[data-conversation-session="parent"] [data-composer-input]').click();
    await p.evaluate(() => {
      window.requestAnimationFrame = () => { throw new Error('animation frame must not be required'); };
      setTimeout(() => {
        const editor = document.querySelector('[data-conversation-session="parent"] [data-composer-input]');
        const range = document.createRange();
        range.selectNodeContents(editor);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }, 50);
    });
    assert.deepEqual(await call({ action: 'selectionReady', guard: snapshot.guard }), { ready: true });
    await p.locator('[data-conversation-session="child"] [data-composer-input]').click();
    assert.deepEqual(await call({ action: 'selectionReady', guard: snapshot.guard }), { ready: false });
  } finally { await p.close(); }
});


test('an active child alone leaves the parent composer unlocked and supports explicit child scope', async () => {
  const html = page(occurrence('parent', composer()) + child(composer() + '<div data-chat-running>Working</div>'));
  const parent = await run(html, { action: 'prepare', purpose: 'draft' });
  assert.equal(parent.snapshot.running, false);
  assert.equal(parent.snapshot.composer.locked, false);
  assert.equal(parent.result.error, undefined);
  const selected = await run(html, { action: 'prepare', purpose: 'draft', sessionId: 'child' });
  assert.equal(selected.snapshot.guard.conversationSession, 'child');
  assert.equal(selected.snapshot.surface, 'sidebar');
  assert.equal(selected.result.error, undefined);
});

test('only explicit send preparation permits intentional slash and reference prefixes', async () => {
  for (const [prefix, flag, otherFlag] of [['/help', 'allowSlash', 'allowReferences'], ['@file', 'allowReferences', 'allowSlash']]) {
    const html = page(occurrence('parent', composer().replace('>hi</div>', `>${prefix}</div>`)));
    assert.equal(code(await run(html, { action: 'prepare', purpose: 'send' })), 'unsupported_command');
    assert.equal(code(await run(html, { action: 'prepare', purpose: 'send', [otherFlag]: true })), 'unsupported_command');
    assert.equal((await run(html, { action: 'prepare', purpose: 'send', [flag]: true })).result.error, undefined);
    const menu = html.replace('</section>', '<div data-trigger-menu><button role="option">Execute</button></div></section>');
    assert.equal(code(await run(menu, { action: 'prepare', purpose: 'send', [flag]: true })), 'blocked');
  }
});


test('attachment and title metadata use scoped source-owned DOM seats', async () => {
  const rail = label => `<div role="group" aria-label="${label}"><div>one</div><div>two</div></div>`;
  const card = content => `<div data-composer-card>${content}</div>`;
  const html = page('<div role="treeitem" data-row-key="session:parent"><span>Status</span><span>Parent title</span><span>time</span></div>' +
    occurrence('parent', card(composer() + rail('Pending attachments')) + child(card(composer() + rail('Pending attachments')))));
  const { snapshot } = await run(html, { action: 'inspect' });
  assert.equal(snapshot.attachmentCount, 2);
  assert.equal(snapshot.guard.attachmentCount, 2);
  assert.equal(snapshot.title, 'Parent title');
  assert.equal(snapshot.displayedTitle, 'Parent title');
  const zh = await run(page(occurrence('parent', card(composer().replace('Send message', '发送消息') + rail('待发送附件'))), 'zh'), { action: 'inspect' });
  assert.equal(zh.snapshot.attachmentCount, 2);
});


test('attachment and chip metadata bind guards and refuse generic sends with inline references', async () => {
  const file = status => `<div><div title="report.pdf"><span>icon</span><span aria-label="Pending file"><span>report.pdf</span><span>${status}</span></span><button aria-label="Remove report.pdf">x</button></div></div>`;
  const image = '<div><div><button><img alt="image.png"></button><button aria-label="Remove image.png">x</button></div></div>';
  const content = status => page(occurrence('parent', `<div data-composer-card>${composer()}<div role="group" aria-label="Pending attachments">${file(status)}${image}</div></div>`));
  const uploading = (await run(content('Uploading…'), { action: 'inspect' })).snapshot;
  assert.deepEqual(uploading.attachments.map(item => [item.kind, item.name, item.status]), [['file', 'report.pdf', 'uploading'], ['image', 'image.png', 'ready']]);
  const settled = (await run(content('PDF 1 KB'), { action: 'inspect' })).snapshot;
  assert.equal(settled.attachments[0].status, 'ready');
  assert.notDeepEqual(uploading.guard.attachments, settled.guard.attachments);
  const chips = page(occurrence('parent', composer().replace('>hi</div>', '>hi <span data-composer-chip="file" contenteditable="false"><span title="file.txt">file.txt</span></span></div>')));
  const referenced = await run(chips, { action: 'prepare', purpose: 'send' });
  assert.equal(referenced.snapshot.references[0].title, 'file.txt');
  assert.equal(referenced.snapshot.guard.references[0].source, 'file');
  assert.equal(referenced.snapshot.capabilities.send, false);
  assert.equal(code(referenced), 'unsupported_command');
  assert.equal((await run(chips, { action: 'prepare', purpose: 'send', allowReferences: true })).result.error, undefined);
});

const header = label => `<header><div data-conversation-header-leading></div><button aria-haspopup="tree" aria-label="${label}">${label}</button></header>`;

test('scoped child running indicators and the aggregate subagent trigger are live observation only', async () => {
  const p = await browser.newPage();
  try {
    const html = page(occurrence('parent', header('2 subagents running') + composer() +
      child(composer().replace('>hi</div>', '>child draft</div>') + '<div data-chat-running>Working</div>') +
      '<aside data-sidebar-chat>' + occurrence('child-2', composer()) + '</aside>'));
    await p.setContent(html);
    const call = req => p.evaluate(`((location, performance) => (${script}))({origin:'dsh-app://app',href:'dsh-app://app/'},{timeOrigin:1})(${JSON.stringify(req)})`);
    const before = await p.evaluate(() => document.body.innerHTML);
    const parent = await call({ action: 'inspect' });
    const after = await p.evaluate(() => document.body.innerHTML);
    assert.equal(after, before);
    assert.deepEqual(parent.subagentActivity, { available: true, running: true, declaredCount: 2, label: '2 subagents running' });
    assert.deepEqual(parent.subagents.map(agent => [agent.id, agent.status, agent.loaded]), [['child', 'running', true], ['child-2', 'idle', true]]);
    assert.equal(parent.running, false);
    assert.equal(parent.guard.running, false);
    const sidebar = await call({ action: 'inspect', sessionId: 'child' });
    assert.equal(sidebar.subagentActivity.available, false);
    assert.equal(sidebar.running, true);
  } finally { await p.close(); }
});

test('aggregate subagent trigger without the running qualifier reports observed child idle', async () => {
  const html = page(occurrence('parent', header('2 subagents') + composer() + child(composer())));
  const { result } = await run(html, { action: 'inspect' });
  assert.deepEqual(result.subagentActivity, { available: true, running: false, declaredCount: 2, label: '2 subagents' });
  assert.deepEqual(result.subagents.map(agent => [agent.id, agent.status]), [['child', 'idle']]);
});

test('a settling child placeholder stays unknown instead of inferred idle', async () => {
  const section = (content, phase) => `<aside data-sidebar-chat><section data-conversation-content data-conversation-session="child" data-content-phase="${phase}">${content}</section></aside>`;
  const html = page(occurrence('parent', composer()) + section('<div role="status">Loading</div>', 'settling'));
  const parent = await run(html, { action: 'inspect' });
  assert.deepEqual(parent.snapshot.subagents.map(agent => [agent.id, agent.status, agent.running, agent.loaded]),
    [['child', 'unknown', null, false]]);
  const child = await run(html, { action: 'inspect', sessionId: 'child' });
  assert.equal(child.result.uiAvailable, true);
  assert.equal(child.result.loaded, false);
  assert.equal(child.result.running, false);
  // Positive running evidence outranks an unloaded phase.
  const live = await run(page(occurrence('parent', composer()) + section('<div data-chat-running>Working</div>', 'settling')), { action: 'inspect' });
  assert.deepEqual(live.snapshot.subagents.map(agent => [agent.status, agent.running, agent.loaded]), [['running', true, false]]);
});
