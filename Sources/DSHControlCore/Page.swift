import Foundation

/// All release-sensitive DOM knowledge lives here; no app objects or private RPCs are used.
public enum PageAdapter {
    public static let script = #"""
    async (request) => {
      const fail = (code, message) => { throw {code, message}; };
      const shown = el => el instanceof Element && !el.closest('[hidden],[aria-hidden="true"]') &&
        el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
      const visible = el => shown(el) && !el.closest('[inert]');
      const text = el => (el?.innerText || el?.textContent || '').trim();
      const cut = (value, limit) => value.slice(0, limit).toWellFormed();
      const name = el => el.getAttribute('aria-label') ||
        (el.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean).map(id => text(document.getElementById(id))).join(' ') || text(el);
      const language = document.documentElement.lang.toLowerCase().split('-')[0];
      const labels = {en:{send:'Send message',stop:'Stop generating',queue:'Queue message',steer:'Steer message'},
        zh:{send:'发送消息',stop:'停止生成',queue:'排队发送',steer:'插话发送'}}[language];
      const occurrenceSelector = '[data-conversation-content],[data-conversation-session]';
      const roots = [...document.querySelectorAll(occurrenceSelector)];
      const mainRoots = roots.filter(el => shown(el) && !el.closest('[data-sidebar-chat]'));
      const candidates = request.sessionId == null ? mainRoots : roots.filter(el => shown(el) && el.getAttribute('data-conversation-session') === request.sessionId);
      const root = candidates.length === 1 ? candidates[0] : null;
      // Old fixtures have no occurrence markers; never fall back across a real conversation root.
      const legacy = roots.length === 0 && request.sessionId == null;
      const uiAvailable = !!root || legacy;
      const belongs = el => legacy || !!root && el.closest(occurrenceSelector) === root;
      const scoped = selector => [...document.querySelectorAll(selector)].filter(belongs);
      // Nested child occurrences must not lend their running or interaction markers to an ancestor.
      const inOccurrence = (el, occurrence) => !el.closest(occurrenceSelector) || el.closest(occurrenceSelector) === occurrence;
      const conversationSession = root?.getAttribute('data-conversation-session') || null;
      const displayedSessionId = mainRoots.length === 1 ? mainRoots[0].getAttribute('data-conversation-session') : null;
      const surface = root ? root.closest('[data-sidebar-chat]') ? 'sidebar' : 'main' : 'unknown';
      const viewKind = root ? surface === 'sidebar' ? 'subagent' : 'main' : 'unknown';
      const contentPhase = root?.getAttribute('data-content-phase') || null;
      const editors = scoped('[data-composer-input]').filter(shown);
      const editor = editors.length === 1 ? editors[0] : null;
      const actionable = el => visible(el) && uiAvailable && (!el.closest(occurrenceSelector) || belongs(el));
      const buttons = [...document.querySelectorAll('button,[role="button"]')].filter(actionable);
      const reserved = new Set(Object.values(labels || {}));
      let inputArea = editor;
      while (inputArea && ![...inputArea.querySelectorAll('button')].some(el => belongs(el) && reserved.has(name(el)))) {
        if (inputArea === root) { inputArea = null; break; }
        inputArea = inputArea.parentElement;
      }
      const describe = el => {
        const model = el.matches('[data-model-id]') ? el : el.querySelector('[data-model-id]');
        return {role:el.getAttribute('role') || (el.tagName === 'BUTTON' ? 'button' : 'link'),name:name(el),
          key:el.getAttribute('data-row-key'),model:model?.getAttribute('data-model-id') || null,
          provider:model?.getAttribute('data-provider-id') || null};
      };
      // Stable identifiers outrank display text (relative times, titles) so refs survive ordinary drift.
      const refOf = el => { const d = describe(el); return JSON.stringify(d.key || d.model ? {...d,name:null} : d); };
      const elements = [...new Set(document.querySelectorAll('button,a[href],[role="button"],[role="menuitem"],[role="menuitemradio"],[role="treeitem"],[role="tab"],[role="option"]'))].filter(actionable);
      const groupOf = el => inputArea?.contains(el) || el.closest('[data-composer-seat],[data-composer-card]') ? 'composer'
        : el.closest('[data-chat-node-key]') ? 'messages' : el.closest('[data-row-key],[data-sidebar-chat],aside,nav') ? 'sidebar' : 'other';
      const controls = elements.map(el => ({...describe(el),ref:refOf(el),group:groupOf(el),
        disabled:el.matches(':disabled,[aria-disabled="true"]'),selected:el.getAttribute('aria-selected') || el.getAttribute('aria-checked'),
        current:el.getAttribute('aria-current')==='page',expanded:el.getAttribute('aria-expanded'),popup:el.getAttribute('aria-haspopup')}));
      const rows = scoped('[data-chat-node-key]').filter(shown);
      const rowText = el => {
        if (!el.querySelector(occurrenceSelector)) return text(el);
        const walker = document.createTreeWalker(el,NodeFilter.SHOW_TEXT,{acceptNode:node => belongs(node.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT});
        const parts = [];
        while (walker.nextNode()) parts.push(walker.currentNode.textContent);
        return parts.join(' ').trim();
      };
      // A user row's own text lives only in its text slots; the row text also holds a timestamp and Copy. No slot means no body, never a fallback.
      const userBody = el => {
        const slots = [...el.querySelectorAll('[data-slot="conversation.user.text.node"]')].filter((slot, _, all) => slot.closest('[data-chat-node-key]') === el && belongs(slot) && !all.some(other => other !== slot && other.contains(slot)));
        return slots.length ? slots.map(rowText).join('\n') : null;
      };
      const messages = rows.slice(-80).map(el => {
        const body = el.getAttribute('data-chat-flow-kind') === 'user' ? userBody(el) : null, renderedText = rowText(el);
        return {key:el.getAttribute('data-chat-node-key'),kind:el.getAttribute('data-chat-flow-kind'),
          turn:el.getAttribute('data-chat-turn'),part:el.getAttribute('data-chat-group-part'),answer:el.hasAttribute('data-turn-process-answer'),
          text:cut(renderedText,12000),truncated:renderedText.length>12000,body:body===null?null:cut(body,12000),bodyTruncated:(body?.length ?? 0)>12000};
      });
      const dialogs = [...document.querySelectorAll('[role="dialog"],[role="alertdialog"]')].filter(visible).map(el => cut(text(el),1500));
      const noticeElements = [...document.querySelectorAll('[role="alert"],[role="status"]')].filter(el => shown(el) &&
        (!el.closest(occurrenceSelector) || belongs(el)) && !el.closest('[data-approval-key],[data-question-key]'));
      const notices = noticeElements.map(el => ({role:el.getAttribute('role'),text:cut(text(el),1500)})).filter(notice => notice.text);
      const alerts = notices.filter(notice => notice.role === 'alert').map(notice => notice.text);
      const pendingInteractions = scoped('[data-approval-key],[data-question-key]').filter(shown).map(el => ({
        kind:el.hasAttribute('data-approval-key') ? 'approval' : 'question',
        key:el.getAttribute('data-approval-key') ?? el.getAttribute('data-question-key'),text:cut(text(el),1500)}));
      const running = scoped('[data-chat-running],[data-streaming="true"]').some(shown) || buttons.some(el => inputArea?.contains(el) && name(el) === labels?.stop && !el.matches(':disabled,[aria-disabled="true"]'));
      const runningIn = occurrence => [...occurrence.querySelectorAll('[data-chat-running],[data-streaming="true"]')].some(el => shown(el) && inOccurrence(el, occurrence)) ||
        [...occurrence.querySelectorAll('button,[role="button"]')].some(el => shown(el) && inOccurrence(el, occurrence) && name(el) === labels?.stop && !el.matches(':disabled,[aria-disabled="true"]'));
      const blockedIn = occurrence => [...occurrence.querySelectorAll('[data-approval-key],[data-question-key]')].some(el => shown(el) && inOccurrence(el, occurrence));
      // A rendered occurrence is not loaded until real content exists and no placeholder phase is showing.
      const placeholderPhases = new Set(['loading','settling']);
      const hasLoadedContent = occurrence => !!occurrence && !placeholderPhases.has(occurrence.getAttribute('data-content-phase') || '') &&
        (!!occurrence.querySelector('[data-composer-input],[data-composer-seat]') ||
         [...occurrence.querySelectorAll('[data-chat-node-key]')].some(el => shown(el) && inOccurrence(el, occurrence)));
      const loaded = legacy || hasLoadedContent(root);
      const menus = [...document.querySelectorAll('[role="menu"],[data-trigger-menu]')].filter(actionable);
      const subagents = roots.filter(el => shown(el) && el.closest('[data-sidebar-chat]')).map(el => {
        const active = runningIn(el), blocked = !active && blockedIn(el), childLoaded = hasLoadedContent(el);
        return {id:el.getAttribute('data-conversation-session'),status:active?'running':blocked?'blocked':childLoaded?'idle':'unknown',
          running:active?true:childLoaded&&!blocked?false:null,blocked,loaded:childLoaded,uiAvailable:true};
      }).filter(child => child.id);
      // The displayed main header's own "N subagents (running)" trigger is the supported aggregate
      // child indicator. Sidebar targets have no aggregate of their own, so they stay unavailable.
      const subagentActivity = (() => {
        const unavailable = {available:false,running:false,declaredCount:null};
        if (!root || surface !== 'main' || !displayedSessionId || displayedSessionId !== conversationSession) return unavailable;
        const headers = [...document.querySelectorAll('header')].filter(el => shown(el) && !el.closest('[data-sidebar-chat]') && el.querySelector('[data-conversation-header-leading]'));
        if (headers.length !== 1) return unavailable;
        const pattern = /^(\d+)\s+(?:subagents?|个子智能体)(?:\s*(?:running|，正在运行))?$/;
        const triggers = [...headers[0].querySelectorAll('button,[role="button"]')].filter(shown).map(el => {
          const label = name(el), match = pattern.exec(label);
          return match ? {label, count:Number(match[1])} : null;
        }).filter(Boolean);
        if (triggers.length !== 1) return unavailable;
        return {available:true,running:/running|正在运行/.test(triggers[0].label),declaredCount:triggers[0].count,label:triggers[0].label};
      })();
      const selectedRows = [...document.querySelectorAll('[data-row-key][aria-selected="true"]')].map(el => el.getAttribute('data-row-key')).sort();
      const navigation = controls.filter(control => control.current || (control.role === 'tab' && control.selected === 'true')).map(control => control.ref).sort();
      const context = buttons.filter(el => inputArea?.contains(el) && !reserved.has(name(el))).map(name);
      const workspace = buttons.filter(el => /^(Choose workspace|选择工作区)$/.test(name(el))).map(el => text(el));
      const lastUserMessage = messages.filter(message => message.kind === 'user').at(-1);
      const lastUser = lastUserMessage?.key || null, lastUserTurn = lastUserMessage?.turn || null;
      const draft = editor ? (editor.innerText.trim() ? editor.innerText : '') : '';
      const attachmentLabel = language === 'zh' ? '待发送附件' : 'Pending attachments';
      const attachments = scoped('[data-composer-card] [role="group"]').filter(el => shown(el) && el.getAttribute('aria-label') === attachmentLabel)
        .flatMap(rail => [...rail.children]).map(item => {
          const image = item.querySelector('img'), card = item.firstElementChild, body = card?.children[1];
          const kind = image ? 'image' : card?.hasAttribute('title') ? 'file' : 'unknown';
          const status = image ? 'ready' : kind !== 'file' ? 'unknown' : body?.tagName === 'BUTTON' ? 'error'
            : text(body?.lastElementChild) === (language === 'zh' ? '上传中…' : 'Uploading…') ? 'uploading'
            : body?.matches('span[aria-label]') ? 'ready' : 'unknown';
          return {kind,name:image?.getAttribute('alt') ?? card?.getAttribute('title') ?? null,status,text:cut(text(item),1500)};
        });
      const attachmentCount = uiAvailable ? attachments.length : null;
      const commands = scoped('[data-composer-command]').map(el => ({name:el.getAttribute('data-composer-command'),text:cut(text(el),1500)}));
      const references = scoped('[data-composer-chip]').map(el => ({source:el.getAttribute('data-composer-chip'),id:el.id||null,
        title:el.getAttribute('title') || el.querySelector('[title]')?.getAttribute('title') || null,text:cut(text(el),1500)}));
      const composerPhase = editor?.getAttribute('data-phase') || null;
      const titleOf = id => {
        const matching = [...document.querySelectorAll('[data-row-key]')].filter(el => shown(el) && el.getAttribute('data-row-key') === `session:${id}`);
        return id && matching.length === 1 ? text([...matching[0].children].filter(el => el.tagName === 'SPAN')[1]) || null : null;
      };
      const title = titleOf(conversationSession), displayedTitle = titleOf(displayedSessionId);
      // timeOrigin changes on renderer reload, so a token from before a reload cannot match the same-looking page.
      const guard = {url:location.href,epoch:performance.timeOrigin,language,conversationSession,surface,contentPhase,editors:editors.length,draft,attachmentCount,attachments,commands,references,composerPhase,title,displayedTitle,selectedRows,navigation,context,workspace,lastUser,lastUserTurn,
        menus:menus.length,dialogs,pendingInteractions,running};
      const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
        ? Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])) : value;
      const same = (a,b) => JSON.stringify(canonical(a))===JSON.stringify(canonical(b));
      const known = location.origin === 'dsh-app://app' && !!labels;
      const supported = known && uiAvailable && editors.length === 1 && !!inputArea;
      const editable = editor?.getAttribute('contenteditable') === 'true' && !editor.matches('[aria-disabled="true"],[aria-readonly="true"]');
      const composerReason = !uiAvailable ? 'session_not_displayed' : editors.length > 1 ? 'ambiguous_composer'
        : !editor || !inputArea ? 'composer_unavailable' : !editable ? 'read_only'
        : pendingInteractions.length ? 'pending_interaction' : contentPhase === 'settling' ? 'settling' : null;
      const composer = {available:!!editor && !!inputArea,locked:!!composerReason,reason:composerReason};
      const actionButtons = label => buttons.filter(el => inputArea?.contains(el) && name(el) === label && !el.disabled);
      // Navigation (click/scroll) may leave the chat view, where no composer exists; text actions need one.
      const composerAction = ['selectionReady','appendReady'].includes(request.action) || request.action !== 'scroll' && ['draft','send','cancel'].includes(request.purpose);
      const usable = composerAction ? supported : known && uiAvailable && editors.length <= 1;
      const snapshot = {guard,supported,uiAvailable,loaded,session:{id:conversationSession ?? request.sessionId ?? null,sessionKind:surface==='sidebar'?'subagent':'unknown'},displayedSessionId,title,displayedTitle,attachmentCount,attachments,commands,references,viewKind,surface,composer,subagents,subagentActivity,
        language,status:dialogs.length||pendingInteractions.length?'blocked':running?'running':'idle',running,draft,editable,
        dialogs,alerts,notices,pendingInteractions,menus:menus.length,controls,messages,coverage:'rendered DOM only; virtualized history may be absent',
        capabilities:{inspect:true,draft:supported&&!composer.locked&&visible(editor)&&!dialogs.length&&!menus.length,
          send:supported&&!composer.locked&&!running&&!dialogs.length&&!menus.length&&!!guard.draft.trim()&&!/^\s*[\/@]/.test(guard.draft)&&!commands.length&&!references.length&&actionButtons(labels.send).length===1,
          cancel:supported&&!composer.locked&&running&&!dialogs.length&&!menus.length&&actionButtons(labels.stop).length===1}};
      try {
        if (request.action === 'inspect') return snapshot;
        if (composerAction && roots.length && composer.locked) fail('composer_locked','The selected conversation composer is unavailable or read-only.');
        if (!usable) fail('unsupported_ui','Expected the Harness app, a known locale and, for text actions, one composer with its primary action area; inspect the UI before updating the adapter.');
        if (!same(request.guard,guard)) fail('stale_state','The displayed conversation, draft, workspace, or controls changed; inspect again.');
        if (request.action === 'selectionReady' || request.action === 'appendReady') {
          if (composer.locked || !visible(editor) || dialogs.length || menus.length) fail('blocked','The composer cannot accept text.');
          const deadline = Date.now() + 1000;
          let selectionObserved = false;
          while (true) {
            if (!editor.isConnected || !belongs(editor) || (editor.innerText.trim() ? editor.innerText : '') !== draft ||
              root && ((root.getAttribute('data-conversation-session') || null) !== conversationSession || (root.getAttribute('data-content-phase') || null) !== contentPhase) || !editor.isContentEditable || editor.matches('[aria-disabled="true"],[aria-readonly="true"]')) fail('stale_state','The selected composer changed while waiting for selection.');
            const selection = window.getSelection();
            if (document.activeElement === editor && selection?.rangeCount === 1 && editor.contains(selection.anchorNode) && editor.contains(selection.focusNode)) {
              const range = selection.getRangeAt(0), full = document.createRange();
              full.selectNodeContents(editor);
              const suffix = full.cloneRange();
              suffix.setStart(range.endContainer,range.endOffset);
              if (request.action === 'appendReady' ? range.collapsed && suffix.toString()==='' && !suffix.cloneContents().querySelector('[data-composer-chip]') : range.toString() === full.toString()) {
                if (selectionObserved) return {ready:true};
                selectionObserved = true;
              } else selectionObserved = false;
            }
            if (Date.now() >= deadline) return {ready:false};
            // A task turn lets Lexical consume selectionchange even when renderer animation frames are throttled.
            await new Promise(resolve => setTimeout(resolve,25));
          }
        }
        if (request.action === 'scroll') {
          if (dialogs.length) fail('blocked','A dialog is open.');
          let area = rows.at(-1)?.parentElement;
          while (area && !(area.scrollHeight > area.clientHeight && /auto|scroll/.test(getComputedStyle(area).overflowY))) area = area.parentElement;
          if (!area) fail('unsupported_ui','No rendered conversation scroll area was found.');
          area.scrollBy({top:area.clientHeight*(request.direction==='up'?-0.8:0.8),behavior:'instant'});
          return {scrolled:true};
        }
        let element;
        if (request.purpose === 'draft') {
          if (!snapshot.editable || !visible(editor) || dialogs.length || menus.length) fail('blocked','The composer is read-only or an overlay is open.');
          element = editor;
        } else if (request.purpose === 'send') {
          if (running || dialogs.length || pendingInteractions.length || menus.length || !guard.draft.trim()) fail('blocked','Sending requires an idle conversation, a draft, and no overlay or error.');
          if ((/^\s*\//.test(guard.draft) || commands.length) && request.allowSlash !== true || (/^\s*@/.test(guard.draft) || references.length) && request.allowReferences !== true) fail('unsupported_command','Slash commands and leading references require a dedicated receipt-aware command.');
          const candidates = actionButtons(labels.send);
          if (candidates.length!==1) fail('ambiguous_control','Expected one enabled Send message button.');
          element=candidates[0];
        } else if (request.purpose === 'cancel') {
          if (!running || dialogs.length || menus.length) fail('blocked','There is no unblocked running turn.');
          const candidates=actionButtons(labels.stop);
          if (candidates.length!==1) fail('ambiguous_control','Expected one enabled Stop generating button; a nonempty draft may expose Queue instead.');
          element=candidates[0];
        } else {
          const candidates=elements.filter(el=>refOf(el)===request.ref);
          if (candidates.length!==1) fail('ambiguous_control','The inspected control is missing or ambiguous.');
          element=candidates[0];
          if (element.closest('[data-trigger-menu],[data-composer-command]')) fail('dedicated_command','Composer commands and reference selections require a receipt-aware command.');
          if (reserved.has(name(element))) fail('dedicated_command','Use send or cancel so their safety checks and receipts apply.');
          if (/^(Create your plugin|创建你的插件)$/.test(name(element))) fail('dedicated_command','Plugin creation changes drafts and presets; use the app manually for this action.');
          if (inputArea?.contains(element)&&!element.hasAttribute('aria-haspopup')) fail('dedicated_command','Composer actions require a dedicated command; only its menus support generic click.');
        }
        if (element.matches(':disabled,[aria-disabled="true"]')) fail('disabled','The requested control is disabled.');
        element.scrollIntoView({block:'nearest',inline:'nearest'});
        const rect=element.getBoundingClientRect(), x=Math.max(0,Math.min(innerWidth-1,rect.x+rect.width/2)), y=Math.max(0,Math.min(innerHeight-1,rect.y+rect.height/2));
        const hit=document.elementFromPoint(x,y);
        if (!hit || !element.contains(hit)) fail('obstructed','The requested control is covered; no input was dispatched.');
        return {x,y};
      } catch(error) {
        return {error:{code:error.code||'ui_error',message:error.message||'The DOM probe failed.'}};
      }
    }
    """#
}
