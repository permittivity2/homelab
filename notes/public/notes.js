/* homelab-notes: the page script (post-cutover #71). Plain JS, no library.
   Everything comes from /api/* with the session cookie and the CSRF token
   from the boot block; the body a note shows is the server's cleaned HTML.
   This file is served by the app itself; the page's CSP allows no inline
   script, so nothing here is attached through on* attributes. */
(function () {
  'use strict';
  var BOOT = JSON.parse(document.getElementById('boot').textContent);
  function $(id) { return document.getElementById(id); }
  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      if (k === 'class') e.className = attrs[k];
      else if (k === 'text') e.textContent = attrs[k];
      else if (k === 'html') e.innerHTML = attrs[k];
      else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), attrs[k]);
      else if (attrs[k] !== null && attrs[k] !== undefined) e.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return e;
  }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function when(ts) {
    if (!ts) return '';
    if (window.hlWhen) { try { return window.hlWhen(ts); } catch (e) { /* fall through */ } }
    var d = new Date(String(ts).replace(' ', 'T').replace(/(\.\d+)?([+-]\d\d)(:?\d\d)?$/, function (m, f, h, mi) { return h + ':' + (mi ? mi.replace(':', '') : '00'); }));
    if (isNaN(d.getTime())) return String(ts).slice(0, 16);
    var now = new Date(), diff = (now - d) / 1000;
    if (diff < 60) return 'just now';
    if (diff < 3600) return Math.floor(diff / 60) + ' min ago';
    if (diff < 86400 && d.getDate() === now.getDate()) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' });
  }
  function bytes(n) { n = +n || 0; return n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB'; }

  // --- the server -----------------------------------------------------------
  function api(method, path, body) {
    var opts = { method: method, credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-CSRF-Token': BOOT.csrf } };
    if (body !== undefined) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) { var e = new Error(j.error || ('The server answered ' + r.status + '.')); e.status = r.status; e.body = j; throw e; }
        return j;
      });
    });
  }

  // --- messages ---------------------------------------------------------------
  var toastTimer = null;
  function toast(msg, action) {
    var old = document.querySelector('.undo-toast'); if (old) old.remove();
    var t = el('div', { class: 'undo-toast', role: 'status' }, [el('span', { text: msg })]);
    if (action) t.appendChild(el('button', { class: 'btn btn-sm', type: 'button', text: action.label, onclick: function () { t.remove(); action.run(); } }));
    document.body.appendChild(t);
    $('msg').textContent = msg;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.remove(); }, action ? 8000 : 3500);
  }
  function fail(e) { toast(e && e.message ? e.message : 'That did not work.'); }

  // --- dialogs ---------------------------------------------------------------
  var openModalId = null;
  function openModal(id) {
    closeMenus();
    if (openModalId) closeModal(openModalId);
    openModalId = id;
    if (window.HomelabShell && window.HomelabShell.openModal) window.HomelabShell.openModal(id); else $(id).classList.add('open');
    $('nt-backdrop').classList.add('open');
    var first = $(id).querySelector('input:not([type=hidden]), select, textarea, button:not([data-close])');
    if (first) setTimeout(function () { first.focus(); }, 30);
  }
  function closeModal(id) {
    id = id || openModalId; if (!id) return;
    if (window.HomelabShell && window.HomelabShell.closeModal) window.HomelabShell.closeModal(id); else $(id).classList.remove('open');
    $('nt-backdrop').classList.remove('open');
    openModalId = null;
  }
  document.querySelectorAll('[data-close]').forEach(function (b) { b.addEventListener('click', function () { closeModal(); }); });
  $('nt-backdrop').addEventListener('click', function () { closeModal(); closeMenus(); });

  // One question, one text box.
  function prompt(title, label, value) {
    return new Promise(function (resolve) {
      $('prompt-h').textContent = title; $('prompt-label').textContent = label; $('prompt-input').value = value || '';
      $('prompt-error').classList.add('hide');
      var form = $('prompt-form');
      function done(v) { form.onsubmit = null; closeModal('prompt-modal'); resolve(v); }
      form.onsubmit = function (ev) { ev.preventDefault(); var v = $('prompt-input').value.trim(); if (!v) { $('prompt-error').textContent = 'Give it a name.'; $('prompt-error').classList.remove('hide'); return; } done(v); };
      $('prompt-modal').querySelector('[data-close]').onclick = function () { done(null); };
      openModal('prompt-modal');
      $('prompt-input').select();
    });
  }

  // Menus (the note's, a notebook's or folder's).
  var menuTarget = null;
  function closeMenus() { document.querySelectorAll('.menu.open').forEach(function (m) { m.classList.remove('open'); }); }
  function openMenu(id, anchor, target) {
    closeMenus();
    menuTarget = target;
    var m = $(id), r = anchor.getBoundingClientRect();
    m.classList.add('open');
    var w = m.offsetWidth, left = Math.min(r.left + window.scrollX, window.scrollX + document.documentElement.clientWidth - w - 8);
    m.style.left = Math.max(8, left) + 'px';
    m.style.top = (r.bottom + window.scrollY + 4) + 'px';
  }
  document.addEventListener('click', function (ev) { if (!ev.target.closest('.menu') && !ev.target.closest('[data-menu]')) closeMenus(); });

  // --- state -----------------------------------------------------------------
  var S = { notebooks: [], nb: null, folders: [], folder: 'all', notes: [], note: null, mode: 'notebook', q: '', editing: false, dirty: false, saving: false };
  function nbById(id) { return S.notebooks.filter(function (n) { return n.id === id; })[0] || null; }
  function myNotebooks() { return S.notebooks.filter(function (n) { return n.permission === 'owner'; }); }

  // --- the notebooks column ---------------------------------------------------
  function loadNotebooks() {
    return api('GET', '/api/notebooks').then(function (r) {
      S.notebooks = r.notebooks || [];
      S.prefs = r.prefs || {};
      renderNotebooks();
    });
  }
  function renderNotebooks() {
    var own = $('nb-list'), shared = $('shared-list');
    own.innerHTML = ''; shared.innerHTML = '';
    S.notebooks.forEach(function (nb) {
      var row = el('div', { class: 'nb-item' + (S.mode === 'notebook' && S.nb && S.nb.id === nb.id ? ' is-on' : ''), role: 'button', tabindex: '0',
        onclick: function (ev) { if (ev.target.closest('.nb-more')) return; selectNotebook(nb.id); },
        onkeydown: function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); selectNotebook(nb.id); } } }, [
        el('span', { class: 'swatch', style: 'background:' + (nb.color || '#6f94b8') }),
        el('span', { class: 'nb-name', text: nb.name }),
        el('span', { class: 'nb-count', text: nb.note_count || '' }),
        nb.permission === 'owner' ? el('button', { class: 'nb-more', type: 'button', 'aria-label': 'Notebook menu', 'data-menu': '1', text: '⋯', onclick: function (ev) { ev.stopPropagation(); openMenu('nb-menu', ev.currentTarget, { kind: 'notebook', item: nb }); } }) : null
      ]);
      (nb.permission === 'owner' ? own : shared).appendChild(row);
    });
    $('shared-head').hidden = shared.children.length === 0;
  }
  function selectNotebook(id, keepNote) {
    var nb = nbById(id) || S.notebooks[0];
    if (!nb) return Promise.resolve();
    S.nb = nb; S.mode = 'notebook'; S.folder = 'all'; S.q = ''; $('q').value = '';
    closeDrawer();
    renderNotebooks();
    if (!keepNote) showList();
    api('PUT', '/api/prefs', { last_notebook_id: nb.id }).catch(function () {});
    return Promise.all([loadFolders(), loadNotes()]);
  }
  function loadFolders() {
    if (!S.nb) return Promise.resolve();
    return api('GET', '/api/notebooks/' + S.nb.id + '/folders').then(function (r) { S.folders = r.folders || []; renderFolders(); });
  }
  function renderFolders() {
    var list = $('folder-list'); list.innerHTML = '';
    var canEdit = S.nb && S.nb.permission !== 'read';
    $('btn-new-folder').classList.toggle('hide', !canEdit || S.mode !== 'notebook');
    $('folders-head').hidden = S.mode !== 'notebook';
    if (S.mode !== 'notebook') return;
    function row(label, key, count, folder) {
      var r = el('div', { class: 'nb-item' + (folder ? ' folder-item' : '') + (S.folder === key ? ' is-on' : ''), role: 'button', tabindex: '0',
        onclick: function (ev) { if (ev.target.closest('.nb-more')) return; S.folder = key; renderFolders(); showList(); loadNotes(); },
        onkeydown: function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); S.folder = key; renderFolders(); showList(); loadNotes(); } } }, [
        el('span', { class: 'nb-name', text: label }), el('span', { class: 'nb-count', text: count || '' }),
        folder && S.nb.permission === 'owner' ? el('button', { class: 'nb-more', type: 'button', 'aria-label': 'Folder menu', 'data-menu': '1', text: '⋯', onclick: function (ev) { ev.stopPropagation(); openMenu('nb-menu', ev.currentTarget, { kind: 'folder', item: folder }); } }) : null
      ]);
      list.appendChild(r);
    }
    row('All notes', 'all', S.nb ? S.nb.note_count : '');
    row('Not in a folder', '0', '');
    S.folders.forEach(function (f) { row(f.name, String(f.id), f.note_count, f); });
  }

  // --- the list ---------------------------------------------------------------
  function loadNotes() {
    var path;
    if (S.mode === 'search') path = '/api/search?q=' + encodeURIComponent(S.q);
    else if (S.mode === 'trash') path = '/api/trash';
    else if (S.mode === 'shared') path = '/api/notes';
    else if (S.nb) path = '/api/notes?notebook_id=' + S.nb.id + (S.folder !== 'all' ? '&folder_id=' + encodeURIComponent(S.folder) : '');
    else return Promise.resolve();
    return api('GET', path).then(function (r) {
      S.notes = r.notes || [];
      if (S.mode === 'shared') S.notes = S.notes.filter(function (n) { return n.permission !== 'owner'; });
      renderList();
    }).catch(fail);
  }
  function listTitle() {
    if (S.mode === 'search') return 'Search: ' + S.q;
    if (S.mode === 'trash') return 'Deleted notes';
    if (S.mode === 'shared') return 'Shared with me';
    if (!S.nb) return 'Notes';
    if (S.folder === 'all') return S.nb.name;
    if (S.folder === '0') return S.nb.name + ' › not in a folder';
    var f = S.folders.filter(function (x) { return String(x.id) === S.folder; })[0];
    return S.nb.name + ' › ' + (f ? f.name : '');
  }
  function renderList() {
    $('list-title').textContent = listTitle();
    var canAdd = S.mode === 'notebook' && S.nb && S.nb.permission !== 'read';
    $('btn-new-note').classList.toggle('hide', !canAdd);
    $('btn-new-note-m').classList.toggle('hide', !canAdd);
    var list = $('list'); list.innerHTML = '';
    var note = $('list-note');
    if (!S.notes.length) {
      note.textContent = S.mode === 'search' ? 'Nothing matches.' : S.mode === 'trash' ? 'The trash is empty.' : S.mode === 'shared' ? 'Nobody has shared a note with you.' : 'No notes here yet. Press n or + New note.';
    } else if (S.mode === 'trash') {
      note.innerHTML = '';
      note.appendChild(el('button', { class: 'btn btn-sm btn-danger', type: 'button', text: 'Empty the trash', onclick: function () {
        if (!window.confirm('Delete every note in the trash for good?')) return;
        api('POST', '/api/trash/empty').then(function (r) { toast(r.removed + ' note' + (r.removed === 1 ? '' : 's') + ' gone for good.'); loadNotes(); loadNotebooks(); }).catch(fail);
      } }));
    } else note.textContent = '';
    S.notes.forEach(function (n) {
      var row = el('button', { class: 'note-row' + (S.note && S.note.id === n.id ? ' is-on' : ''), type: 'button', onclick: function () { S.mode === 'trash' ? openTrashed(n) : openNote(n.id); } }, [
        el('div', { class: 'note-row__title' }, [n.pinned ? el('span', { class: 'pin', text: '★', title: 'Pinned' }) : null, document.createTextNode(n.title || 'Untitled note')]),
        el('div', { class: 'note-row__excerpt', html: n.snippet_html || esc(n.excerpt || '') }),
        el('div', { class: 'note-row__meta' }, [
          el('span', { text: when(n.deleted_at || n.updated_at) }),
          n.permission !== 'owner' ? el('span', { text: 'from ' + n.owner_email }) : null,
          S.mode !== 'notebook' && S.notebooks.length ? el('span', { text: (nbById(n.notebook_id) || {}).name || '' }) : null,
          el('span', { text: n.format === 'markdown' ? '' : n.format })
        ])
      ]);
      list.appendChild(el('li', null, [row]));
    });
  }
  function showList() { document.body.classList.remove('viewing'); }
  function showNote() { document.body.classList.add('viewing'); }

  // --- the note --------------------------------------------------------------
  function openNote(id, opts) {
    opts = opts || {};
    if (S.editing && S.dirty) return save().then(function () { return openNote(id, opts); });
    return api('GET', '/api/notes/' + id).then(function (n) {
      S.note = n; stopEdit(true);
      renderNote();
      showNote();
      if (!opts.noHistory && location.pathname !== '/n/' + n.id) history.pushState({ note: n.id }, '', '/n/' + n.id);
      if (S.mode === 'notebook' && S.nb && S.nb.id !== n.notebook_id && nbById(n.notebook_id)) { S.nb = nbById(n.notebook_id); S.folder = 'all'; renderNotebooks(); loadFolders(); loadNotes(); }
      else renderList();
      if (opts.edit) startEdit();
    }).catch(function (e) { fail(e); if (e.status === 404) { S.note = null; renderNote(); showList(); } });
  }
  function openTrashed(n) {
    S.note = null; renderNote();
    var v = $('view'); v.classList.remove('hide'); $('view-empty').classList.add('hide');
    $('n-title').value = n.title || 'Untitled note'; $('n-title').readOnly = true;
    $('n-meta').textContent = 'Deleted ' + when(n.deleted_at) + '. ';
    $('n-meta').appendChild(el('button', { class: 'btn btn-sm', type: 'button', text: 'Restore', onclick: function () { api('POST', '/api/notes/' + n.id + '/restore').then(function (r) { toast('Restored.'); loadNotebooks(); loadNotes(); openNote(r.id); }).catch(fail); } }));
    $('n-html').innerHTML = '<p class="muted-small">' + esc(n.excerpt || '') + '</p>';
    $('n-links').innerHTML = ''; $('link-actions').classList.add('hide'); $('btn-edit').classList.add('hide'); $('btn-more').classList.add('hide'); $('n-format').classList.add('hide');
    showNote();
  }
  function renderNote() {
    var n = S.note, v = $('view');
    if (!n) { v.classList.add('hide'); $('view-empty').classList.remove('hide'); return; }
    v.classList.remove('hide'); $('view-empty').classList.add('hide');
    var canEdit = !!n.can_edit;
    $('n-title').value = n.title; $('n-title').readOnly = !canEdit;
    $('n-format').value = n.format; $('n-format').disabled = !canEdit; $('n-format').classList.toggle('hide', !canEdit && !S.editing);
    $('btn-edit').classList.toggle('hide', !canEdit); $('btn-more').classList.remove('hide');
    $('n-readonly').classList.toggle('hide', canEdit);
    var who = n.edited_by && n.edited_by !== BOOT.me ? ' by ' + n.edited_by : '';
    $('n-meta').textContent = 'Changed ' + when(n.updated_at) + who + (n.permission !== 'owner' ? ' · shared by ' + n.owner_email + ' (' + (canEdit ? 'you may edit' : 'read only') + ')' : '') + (n.share_count ? ' · shared with ' + n.share_count : '') + (n.pinned ? ' · pinned' : '');
    $('n-html').innerHTML = n.html || '';
    renderLinks(n);
    $('link-actions').classList.toggle('hide', !canEdit);
    $('note-menu').querySelector('[data-act=pin]').textContent = n.pinned ? 'Unpin' : 'Pin';
    ['share', 'move', 'delete'].forEach(function (a) { $('note-menu').querySelector('[data-act=' + a + ']').classList.toggle('hide', !n.can_manage); });
  }
  function renderLinks(n) {
    var box = $('n-links'); box.innerHTML = '';
    (n.links || []).forEach(function (l) {
      var t = l.target || {}, title, sub;
      if (l.kind === 'mail') { title = l.label || t.subject || '(no subject)'; sub = [t.from_name || t.from_addr, (t.sent_at || '').slice(0, 10), t.mailbox].filter(Boolean).join(' · '); }
      else if (l.kind === 'drive') { title = l.label || t.filename || 'file'; sub = [t.mime_type, t.size_bytes != null ? bytes(t.size_bytes) : null].filter(Boolean).join(' · '); }
      else { title = l.label || t.url || ''; sub = l.label ? t.url : ''; }
      box.appendChild(el('div', { class: 'link-card' }, [
        el('span', { class: 'link-card__kind', text: l.kind === 'mail' ? 'Email' : l.kind === 'drive' ? 'File' : 'Web' }),
        el('div', { class: 'link-card__main' }, [el('div', { class: 'link-card__title', text: title }), el('div', { class: 'link-card__sub', text: sub })]),
        l.open_url ? el('a', { class: 'btn btn-sm', href: l.open_url, target: '_blank', rel: 'noopener noreferrer', text: l.kind === 'mail' ? 'Find it' : 'Open' }) : null,
        n.can_edit ? el('button', { class: 'btn btn-sm btn-ghost', type: 'button', 'aria-label': 'Remove this link', text: '×', onclick: function () { api('POST', '/api/links/' + l.id + '/remove').then(function () { return openNote(n.id, { noHistory: true }); }).catch(fail); } }) : null
      ]));
    });
  }
  function newNote() {
    if (!S.nb || S.nb.permission === 'read') { toast('Pick one of your notebooks first.'); return; }
    var body = { notebook_id: S.nb.id, title: '', format: (S.prefs && S.prefs.default_format) || 'markdown', body: '' };
    if (S.folder !== 'all' && S.folder !== '0') body.folder_id = +S.folder;
    api('POST', '/api/notes', body).then(function (n) { S.note = n; loadNotes(); loadNotebooks(); renderNote(); showNote(); history.pushState({ note: n.id }, '', '/n/' + n.id); startEdit(); $('n-title').focus(); }).catch(fail);
  }

  // --- editing ---------------------------------------------------------------
  var saveTimer = null, previewTimer = null;
  function startEdit() {
    if (!S.note || !S.note.can_edit) return;
    S.editing = true;
    $('editor').classList.remove('hide'); $('editor-bar').classList.remove('hide'); $('n-html').classList.add('hide');
    $('n-body').value = S.note.body || '';
    $('n-format').classList.remove('hide');
    $('btn-edit').textContent = 'Editing';
    setSaveState('');
    updatePreview(true);
    $('n-body').focus();
  }
  function stopEdit(silent) {
    S.editing = false; S.dirty = false;
    $('editor').classList.add('hide'); $('editor-bar').classList.add('hide'); $('n-html').classList.remove('hide');
    $('btn-edit').textContent = 'Edit';
    clearTimeout(saveTimer);
    if (!silent && S.note) renderNote();
  }
  function setSaveState(text, cls) { var s = $('save-state'); s.textContent = text; s.className = 'save-state' + (cls ? ' ' + cls : ''); }
  function changed() {
    if (!S.editing) return;
    S.dirty = true; setSaveState('Unsaved changes', 'is-dirty');
    clearTimeout(saveTimer); saveTimer = setTimeout(function () { save(); }, 1500);
    clearTimeout(previewTimer); previewTimer = setTimeout(function () { updatePreview(); }, 500);
  }
  function save() {
    if (!S.note || !S.dirty || S.saving) return Promise.resolve();
    S.saving = true; clearTimeout(saveTimer);
    var n = S.note, body = { title: $('n-title').value, body: $('n-body').value, format: $('n-format').value, revision: n.revision };
    return api('PATCH', '/api/notes/' + n.id, body).then(function (r) {
      S.saving = false; S.dirty = false;
      var changedAgain = $('n-body').value !== body.body || $('n-title').value !== body.title;
      S.note = r;
      setSaveState('Saved ' + when(r.updated_at), '');
      if (S.notes.some(function (x) { return x.id === r.id; })) loadNotes();
      if (changedAgain) changed();
    }).catch(function (e) {
      S.saving = false;
      if (e.status === 409 && e.body && e.body.note) {
        var theirs = e.body.note;
        setSaveState('Someone else saved this note first.', 'is-error');
        toast('Someone saved a newer copy of this note.', { label: 'Show theirs', run: function () { S.note = theirs; $('n-body').value = theirs.body; $('n-title').value = theirs.title; $('n-format').value = theirs.format; S.dirty = false; updatePreview(true); renderNote(); } });
        S.note.revision = theirs.revision;    // keep mine: the next save overwrites theirs on purpose
        return;
      }
      setSaveState(e.message, 'is-error');
    });
  }
  function updatePreview(now) {
    var ed = $('editor');
    var wide = window.matchMedia('(min-width: 861px)').matches;
    if (!wide && !ed.classList.contains('preview-on')) return;
    if (wide && ed.classList.contains('preview-off')) return;
    api('POST', '/api/preview', { format: $('n-format').value, body: $('n-body').value, notebook_id: S.note ? S.note.notebook_id : null }).then(function (r) { $('n-preview').innerHTML = r.html || ''; }).catch(function () {});
  }
  $('btn-edit').addEventListener('click', function () { S.editing ? (S.dirty ? save().then(function () { stopEdit(); }) : stopEdit()) : startEdit(); });
  $('btn-done').addEventListener('click', function () { (S.dirty ? save() : Promise.resolve()).then(function () { stopEdit(); }); });
  $('n-body').addEventListener('input', changed);
  $('n-title').addEventListener('input', function () { if (S.editing) changed(); else if (S.note && S.note.can_edit) { S.editing = true; S.dirty = true; clearTimeout(saveTimer); saveTimer = setTimeout(function () { save().then(function () { S.editing = false; }); }, 1200); } });
  $('n-title').addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); if (S.editing) $('n-body').focus(); else $('n-title').blur(); } });
  $('n-format').addEventListener('change', function () { if (!S.note || !S.note.can_edit) return; if (!S.editing) startEdit(); changed(); });
  $('btn-preview-toggle').addEventListener('click', function () {
    var ed = $('editor'), wide = window.matchMedia('(min-width: 861px)').matches;
    if (wide) { ed.classList.toggle('preview-off'); } else { ed.classList.toggle('preview-on'); }
    var on = wide ? !ed.classList.contains('preview-off') : ed.classList.contains('preview-on');
    $('btn-preview-toggle').textContent = on ? (wide ? 'Hide preview' : 'Write') : 'Preview';
    if (on) updatePreview(true);
  });
  $('n-body').addEventListener('keydown', function (ev) {
    if (ev.key === 'Tab' && !ev.shiftKey) { ev.preventDefault(); var t = ev.target, s = t.selectionStart; t.setRangeText('    ', s, t.selectionEnd, 'end'); changed(); }
    if ((ev.ctrlKey || ev.metaKey) && ev.key === 's') { ev.preventDefault(); save(); }
  });
  window.addEventListener('beforeunload', function (ev) { if (S.dirty) { ev.preventDefault(); ev.returnValue = ''; } });

  // Links between notes (#93): a [[Title]] link opens the note in place; a
  // missing one, for someone who may edit, makes that note in the same notebook.
  document.addEventListener('click', function (ev) {
    var a = ev.target.closest('#n-html a.wikilink, #n-preview a.wikilink');
    if (a) { var m = (a.getAttribute('href') || '').match(/^\/n\/(\d+)$/); if (m) { ev.preventDefault(); openNote(+m[1]); } return; }
    var miss = ev.target.closest('#n-html .wikilink--missing, #n-preview .wikilink--missing');
    if (!miss || !S.note || !S.note.can_edit) return;
    var title = miss.getAttribute('data-title') || miss.textContent;
    api('POST', '/api/notes', { notebook_id: S.note.notebook_id, title: title, format: (S.prefs && S.prefs.default_format) || 'markdown', body: '' })
      .then(function (n) { toast('Made "' + title + '".'); loadNotes(); loadNotebooks(); return openNote(n.id, { edit: true }); }).catch(fail);
  });

  // --- the note's menu ---------------------------------------------------------
  // stopPropagation, like the notebook and folder "..." buttons: the click would
  // otherwise bubble to the two document-level handlers (this page's and the
  // theme's shell.js) that close every open menu on a click outside one -- and
  // the menu they just saw opened counted as "outside" (0.2.1: the menu had
  // never opened from a real click since 0.1.0; the live check clicked the
  // hidden items directly, which is why it passed).
  $('btn-more').addEventListener('click', function (ev) { ev.stopPropagation(); openMenu('note-menu', ev.currentTarget, { kind: 'note', item: S.note }); });
  $('note-menu').addEventListener('click', function (ev) {
    var b = ev.target.closest('button'); if (!b || !S.note) return;
    closeMenus();
    var n = S.note, act = b.getAttribute('data-act');
    if (act === 'pin') api('PATCH', '/api/notes/' + n.id, { pinned: !n.pinned }).then(function (r) { S.note = r; renderNote(); loadNotes(); }).catch(fail);
    else if (act === 'share') openShare({ kind: 'note', item: n });
    else if (act === 'move') openMove(n);
    else if (act === 'history') openHistory(n);
    else if (act === 'copy-link') { navigator.clipboard && navigator.clipboard.writeText(n.url).then(function () { toast('Link copied: ' + n.url); }, function () { toast(n.url); }); }
    else if (act === 'delete') deleteNote(n);
  });
  function deleteNote(n) {
    api('POST', '/api/notes/' + n.id + '/delete').then(function () {
      S.note = null; renderNote(); showList(); history.replaceState({}, '', '/');
      loadNotes(); loadNotebooks();
      toast('Deleted "' + (n.title || 'Untitled note') + '".', { label: 'Undo', run: function () { api('POST', '/api/notes/' + n.id + '/restore').then(function () { loadNotes(); loadNotebooks(); openNote(n.id); }).catch(fail); } });
    }).catch(fail);
  }

  // --- notebooks and folders ----------------------------------------------------
  $('btn-new-notebook').addEventListener('click', function () {
    prompt('New notebook', 'Name', '').then(function (name) { if (!name) return; api('POST', '/api/notebooks', { name: name }).then(function (nb) { return loadNotebooks().then(function () { selectNotebook(nb.id); }); }).catch(fail); });
  });
  $('btn-new-folder').addEventListener('click', function () {
    if (!S.nb) return;
    prompt('New folder in ' + S.nb.name, 'Name', '').then(function (name) { if (!name) return; api('POST', '/api/notebooks/' + S.nb.id + '/folders', { name: name }).then(function (f) { S.folder = String(f.id); return loadFolders().then(loadNotes); }).catch(fail); });
  });
  $('nb-menu').addEventListener('click', function (ev) {
    var b = ev.target.closest('button'); if (!b || !menuTarget) return;
    closeMenus();
    var t = menuTarget, act = b.getAttribute('data-act');
    if (t.kind === 'notebook') {
      if (act === 'rename') prompt('Rename notebook', 'Name', t.item.name).then(function (name) { if (!name) return; api('PATCH', '/api/notebooks/' + t.item.id, { name: name }).then(function () { return loadNotebooks(); }).then(function () { if (S.nb && S.nb.id === t.item.id) { S.nb = nbById(t.item.id); renderList(); } }).catch(fail); });
      else if (act === 'share') openShare({ kind: 'notebook', item: t.item });
      else if (act === 'delete') { if (!window.confirm('Delete the notebook "' + t.item.name + '" and every note in it? They go to the trash.')) return; api('POST', '/api/notebooks/' + t.item.id + '/delete').then(function () { S.nb = null; S.note = null; renderNote(); return loadNotebooks(); }).then(function () { selectNotebook(S.notebooks[0] && S.notebooks[0].id); }).catch(fail); }
    } else if (t.kind === 'folder') {
      if (act === 'rename') prompt('Rename folder', 'Name', t.item.name).then(function (name) { if (!name) return; api('PATCH', '/api/folders/' + t.item.id, { name: name }).then(loadFolders).catch(fail); });
      else if (act === 'share') toast('Share the notebook, or a single note.');
      else if (act === 'delete') { if (!window.confirm('Delete the folder "' + t.item.name + '"? Its notes go to the trash.')) return; api('POST', '/api/folders/' + t.item.id + '/delete').then(function () { S.folder = 'all'; return Promise.all([loadFolders(), loadNotes(), loadNotebooks()]); }).catch(fail); }
    }
  });
  $('nb-menu').querySelector('[data-act=share]').addEventListener('mousedown', function () {});

  // --- sharing ------------------------------------------------------------------
  var shareTarget = null;
  function sharePath(t) { return '/api/' + (t.kind === 'note' ? 'notes' : 'notebooks') + '/' + t.item.id + '/shares'; }
  function openShare(t) {
    shareTarget = t;
    $('share-h').textContent = t.kind === 'note' ? 'Share this note' : 'Share the notebook';
    $('share-what').textContent = t.kind === 'note' ? ('"' + (t.item.title || 'Untitled note') + '". A link anyone can open shows it read only; an account can also be allowed to edit.') : ('"' + t.item.name + '" and every note in it, now and later.');
    $('share-with').value = ''; $('share-perm').value = 'read'; $('share-days').value = ''; $('share-error').classList.add('hide');
    loadShares(); openModal('share-modal');
  }
  function loadShares() {
    api('GET', sharePath(shareTarget)).then(function (r) {
      var list = $('share-list'); list.innerHTML = '';
      if (!(r.shares || []).length) list.appendChild(el('li', { class: 'muted-small', text: 'Not shared with anyone yet.' }));
      (r.shares || []).forEach(function (s) {
        list.appendChild(el('li', null, [
          el('span', { class: 'share-who', text: (s.shared_with_email || 'Anyone with the link') + ' · ' + (s.permission === 'edit' ? 'may edit' : 'may see') + (s.expires_at ? ' · until ' + String(s.expires_at).slice(0, 10) : '') + (s.access_count ? ' · opened ' + s.access_count + '×' : '') }),
          el('button', { class: 'btn btn-sm', type: 'button', text: 'Copy link', onclick: function () { navigator.clipboard && navigator.clipboard.writeText(s.url).then(function () { toast('Link copied.'); }, function () { toast(s.url); }); } }),
          el('button', { class: 'btn btn-sm btn-ghost', type: 'button', text: 'Withdraw', onclick: function () { api('POST', '/api/shares/' + s.id + '/revoke').then(loadShares).catch(fail); } }),
          el('span', { class: 'share-url', text: s.url })
        ]));
      });
    }).catch(fail);
  }
  $('share-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var body = { with: $('share-with').value.trim(), permission: $('share-perm').value, expires_days: $('share-days').value || null };
    api('POST', sharePath(shareTarget), body).then(function (s) {
      $('share-with').value = ''; $('share-error').classList.add('hide'); loadShares();
      if (!s.shared_with_email && navigator.clipboard) navigator.clipboard.writeText(s.url).then(function () { toast('Link made and copied.'); }, function () {});
      if (S.note && shareTarget.kind === 'note' && S.note.id === shareTarget.item.id) openNote(S.note.id, { noHistory: true });
    }).catch(function (e) { $('share-error').textContent = e.message; $('share-error').classList.remove('hide'); });
  });

  // --- moving ---------------------------------------------------------------------
  function openMove(n) {
    var nbs = $('move-nb'); nbs.innerHTML = '';
    myNotebooks().forEach(function (nb) { nbs.appendChild(el('option', { value: nb.id, text: nb.name })); });
    nbs.value = n.notebook_id;
    fillMoveFolders(n.notebook_id, n.folder_id);
    $('move-error').classList.add('hide');
    openModal('move-modal');
  }
  function fillMoveFolders(nbId, folderId) {
    var sel = $('move-folder'); sel.innerHTML = ''; sel.appendChild(el('option', { value: '', text: 'Not in a folder' }));
    api('GET', '/api/notebooks/' + nbId + '/folders').then(function (r) { (r.folders || []).forEach(function (f) { sel.appendChild(el('option', { value: f.id, text: f.name })); }); if (folderId) sel.value = folderId; }).catch(function () {});
  }
  $('move-nb').addEventListener('change', function () { fillMoveFolders(+$('move-nb').value, null); });
  $('move-form').addEventListener('submit', function (ev) {
    ev.preventDefault(); if (!S.note) return;
    api('POST', '/api/notes/' + S.note.id + '/move', { notebook_id: +$('move-nb').value, folder_id: $('move-folder').value || null }).then(function (r) {
      closeModal(); toast('Moved.'); loadNotebooks().then(function () { selectNotebook(r.notebook_id, true).then(function () { openNote(r.id, { noHistory: true }); }); });
    }).catch(function (e) { $('move-error').textContent = e.message; $('move-error').classList.remove('hide'); });
  });

  // --- history ---------------------------------------------------------------------
  function openHistory(n) {
    var list = $('history-list'); list.innerHTML = ''; $('history-preview').classList.add('hide');
    api('GET', '/api/notes/' + n.id + '/versions').then(function (r) {
      if (!(r.versions || []).length) list.appendChild(el('li', { class: 'muted-small', text: 'No earlier saves yet.' }));
      (r.versions || []).forEach(function (v) {
        list.appendChild(el('li', null, [
          el('div', { class: 'pick-main' }, [el('div', { class: 'pick-title', text: (v.title || 'Untitled') + ' · revision ' + v.revision }), el('div', { class: 'pick-sub', text: when(v.created_at) + (v.saved_by ? ' by ' + v.saved_by : '') + ' · ' + v.body_chars + ' characters · ' + v.format })]),
          el('button', { class: 'btn btn-sm', type: 'button', text: 'Show', onclick: function () { api('GET', '/api/versions/' + v.id).then(function (full) { var p = $('history-preview'); p.textContent = full.body; p.classList.remove('hide'); }).catch(fail); } }),
          n.can_edit ? el('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Restore', onclick: function () { api('POST', '/api/versions/' + v.id + '/restore').then(function () { closeModal(); toast('Restored revision ' + v.revision + '.'); openNote(n.id, { noHistory: true }); }).catch(fail); } }) : null
        ]));
      });
    }).catch(fail);
    openModal('history-modal');
  }

  // --- links: the pickers -----------------------------------------------------------
  var pickKind = null, driveFolder = null, driveCrumbs = [];
  function openPick(kind) {
    if (!S.note) return;
    pickKind = kind;
    $('pick-h').textContent = kind === 'mail' ? 'Link an email' : kind === 'drive' ? 'Link a file from drive' : 'Link a web page';
    $('pick-mail-form').classList.toggle('hide', kind !== 'mail'); $('pick-drive-head').classList.toggle('hide', kind !== 'drive'); $('pick-url-form').classList.toggle('hide', kind !== 'url');
    $('pick-list').innerHTML = ''; $('pick-error').classList.add('hide'); $('pick-note').classList.add('hide');
    if (kind === 'mail') { $('pick-q').value = ''; $('pick-note').textContent = 'Searches your own mail, as search.mailmasker.org does.'; $('pick-note').classList.remove('hide'); }
    if (kind === 'drive') { driveFolder = null; driveCrumbs = []; loadDrive(); }
    if (kind === 'url') { $('pick-url').value = ''; $('pick-url-label').value = ''; }
    openModal('pick-modal');
  }
  function pickError(e) { $('pick-error').textContent = e.message; $('pick-error').classList.remove('hide'); }
  function addLink(kind, target, label) {
    return api('POST', '/api/notes/' + S.note.id + '/links', { kind: kind, target: target, label: label || '' }).then(function () { closeModal(); toast('Linked.'); return openNote(S.note.id, { noHistory: true }); }).catch(pickError);
  }
  $('pick-mail-form').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var q = $('pick-q').value.trim(); if (!q) return;
    var list = $('pick-list'); list.innerHTML = ''; list.appendChild(el('li', { class: 'muted-small', text: 'Searching…' }));
    api('GET', '/api/pick/mail?q=' + encodeURIComponent(q)).then(function (r) {
      list.innerHTML = '';
      if (!(r.hits || []).length) list.appendChild(el('li', { class: 'muted-small', text: 'No mail matches.' }));
      (r.hits || []).forEach(function (h) {
        list.appendChild(el('li', null, [
          el('div', { class: 'pick-main' }, [el('div', { class: 'pick-title', text: h.subject || '(no subject)' }), el('div', { class: 'pick-sub', text: [h.from_name || h.from_addr, (h.sent_at || '').slice(0, 10), h.mailbox].filter(Boolean).join(' · ') + (h.snippet ? ' — ' + h.snippet : '') })]),
          el('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Link', onclick: function () { addLink('mail', { message_id: h.message_id, subject: h.subject, from_addr: h.from_addr, from_name: h.from_name, sent_at: h.sent_at, mailbox: h.mailbox }); } })
        ]));
      });
    }).catch(function (e) { list.innerHTML = ''; pickError(e); });
  });
  function loadDrive() {
    var list = $('pick-list'); list.innerHTML = ''; list.appendChild(el('li', { class: 'muted-small', text: 'Loading…' }));
    var crumbs = $('pick-crumbs'); crumbs.innerHTML = '';
    crumbs.appendChild(el('button', { class: 'btn btn-sm' + (driveFolder ? ' btn-ghost' : ''), type: 'button', text: 'Drive', onclick: function () { driveFolder = null; driveCrumbs = []; loadDrive(); } }));
    driveCrumbs.forEach(function (c, i) { crumbs.appendChild(el('span', { class: 'muted-small', text: '›' })); crumbs.appendChild(el('button', { class: 'btn btn-sm' + (i === driveCrumbs.length - 1 ? '' : ' btn-ghost'), type: 'button', text: c.name, onclick: function () { driveFolder = c.id; driveCrumbs = driveCrumbs.slice(0, i + 1); loadDrive(); } })); });
    api('GET', '/api/pick/drive' + (driveFolder ? '?folder_id=' + driveFolder : '')).then(function (r) {
      list.innerHTML = '';
      (r.folders || []).forEach(function (f) {
        list.appendChild(el('li', null, [el('div', { class: 'pick-main' }, [el('div', { class: 'pick-title', text: '📁 ' + f.name })]), el('button', { class: 'btn btn-sm', type: 'button', text: 'Open', onclick: function () { driveFolder = f.id; driveCrumbs.push({ id: f.id, name: f.name }); loadDrive(); } })]));
      });
      (r.files || []).forEach(function (f) {
        list.appendChild(el('li', null, [
          el('div', { class: 'pick-main' }, [el('div', { class: 'pick-title', text: f.filename }), el('div', { class: 'pick-sub', text: [f.mime_type, bytes(f.size_bytes), (f.uploaded_at || '').slice(0, 10)].filter(Boolean).join(' · ') })]),
          el('button', { class: 'btn btn-sm btn-primary', type: 'button', text: 'Link', onclick: function () { addLink('drive', { file_id: f.file_id, filename: f.filename, size_bytes: f.size_bytes, mime_type: f.mime_type, folder_path: driveCrumbs.map(function (c) { return c.name; }).join('/') }); } })
        ]));
      });
      if (!list.children.length) list.appendChild(el('li', { class: 'muted-small', text: 'Nothing here.' }));
    }).catch(function (e) { list.innerHTML = ''; pickError(e); });
  }
  $('pick-url-form').addEventListener('submit', function (ev) { ev.preventDefault(); addLink('url', { url: $('pick-url').value.trim() }, $('pick-url-label').value.trim()); });
  $('btn-link-mail').addEventListener('click', function () { openPick('mail'); });
  $('btn-link-drive').addEventListener('click', function () { openPick('drive'); });
  $('btn-link-url').addEventListener('click', function () { openPick('url'); });

  // --- search, trash, shared ----------------------------------------------------------
  function runSearch(q) {
    q = (q || '').trim();
    if (!q) { if (S.nb) selectNotebook(S.nb.id); return; }
    S.mode = 'search'; S.q = q; closeDrawer(); renderNotebooks(); renderFolders(); showList(); loadNotes();
  }
  $('q').addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); runSearch($('q').value); } });
  $('q').addEventListener('search', function () { runSearch($('q').value); });
  $('btn-search-m').addEventListener('click', function () { openDrawer(); $('q').focus(); });
  $('btn-trash').addEventListener('click', function () { S.mode = 'trash'; closeDrawer(); renderNotebooks(); renderFolders(); showList(); loadNotes(); });
  $('btn-shared-notes').addEventListener('click', function () { S.mode = 'shared'; closeDrawer(); renderNotebooks(); renderFolders(); showList(); loadNotes(); });

  // --- phones: the drawer and the two panes ------------------------------------------------
  function openDrawer() { $('nb-side').classList.add('open'); $('side-backdrop').classList.add('open'); document.body.classList.add('nb-side-open'); $('side-toggle').setAttribute('aria-expanded', 'true'); }
  function closeDrawer() { $('nb-side').classList.remove('open'); $('side-backdrop').classList.remove('open'); document.body.classList.remove('nb-side-open'); $('side-toggle').setAttribute('aria-expanded', 'false'); }
  $('side-toggle').addEventListener('click', function () { $('nb-side').classList.contains('open') ? closeDrawer() : openDrawer(); });
  $('side-close').addEventListener('click', closeDrawer);
  $('side-backdrop').addEventListener('click', closeDrawer);
  $('btn-back').addEventListener('click', function () { (S.dirty ? save() : Promise.resolve()).then(function () { stopEdit(true); showList(); history.replaceState({}, '', '/'); }); });
  $('btn-new-note').addEventListener('click', newNote);
  $('btn-new-note-m').addEventListener('click', newNote);

  // --- keys -------------------------------------------------------------------------
  document.addEventListener('keydown', function (ev) {
    var inField = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (ev.key === 'Escape') { if (openModalId) { closeModal(); return; } closeMenus(); if (document.querySelector('.menu.open')) return; if (S.editing && !inField) { (S.dirty ? save() : Promise.resolve()).then(function () { stopEdit(); }); } else if (!inField) { closeDrawer(); showList(); } return; }
    if (inField || openModalId) return;
    if (ev.key === 'n') { ev.preventDefault(); newNote(); }
    else if (ev.key === 'e' && S.note && S.note.can_edit) { ev.preventDefault(); startEdit(); }
    else if (ev.key === '/') { ev.preventDefault(); if (window.matchMedia('(max-width: 860px)').matches) openDrawer(); $('q').focus(); }
  });
  window.addEventListener('popstate', function () {
    var m = location.pathname.match(/^\/n\/(\d+)$/);
    if (m) openNote(+m[1], { noHistory: true }); else { S.note = null; renderNote(); showList(); }
  });

  // --- start -------------------------------------------------------------------------
  loadNotebooks().then(function () {
    var want = BOOT.open_note_id ? null : (S.prefs && S.prefs.last_notebook_id);
    return selectNotebook(want || (S.notebooks[0] && S.notebooks[0].id), !!BOOT.open_note_id);
  }).then(function () {
    if (BOOT.open_note_id) return openNote(BOOT.open_note_id, { noHistory: true });
  }).catch(fail);
})();
