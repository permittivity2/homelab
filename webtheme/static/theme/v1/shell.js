/* ===========================================================================
   Homelab app shell behaviour.
   Served from https://static.mailmasker.org/theme/v1/shell.js
   ---------------------------------------------------------------------------
   Deliberately NOT a port of the marketing site's main.js. That file:
     * hijacks any #contact-form submit and fires a demo alert() -- which would
       break real forms in an app;
     * hijacks anchor clicks for smooth scrolling, fighting hash-based tab
       routing (which both apps use), and only binds anchors present at load;
     * drives .fade-in, which sets opacity:0 and leaves content permanently
       invisible if the script does not run or the element arrives later.
   This is a small, self-contained replacement for the shell only.

   Everything is delegated from document, so markup injected later still works.
   =========================================================================== */
(function () {
  'use strict';

  /* --- dropdown menus ---------------------------------------------------
     Trigger:  <button class="profile-btn" data-menu="account-menu" aria-expanded="false">
     Panel:    <div class="menu" id="account-menu">
     Kept compatible with the existing accountmanage/drive markup, which uses
     .profile-btn + .menu and toggles an `open` class. */
  function closeAll(except) {
    document.querySelectorAll('.menu.open').forEach(function (m) {
      if (m === except) return;
      m.classList.remove('open');
      var t = document.querySelector('[data-menu="' + m.id + '"]');
      if (t) t.setAttribute('aria-expanded', 'false');
    });
  }

  function panelFor(trigger) {
    var id = trigger.getAttribute('data-menu');
    if (id) return document.getElementById(id);
    // fallback: the .menu inside the same .profile wrapper (existing markup)
    var wrap = trigger.closest('.profile');
    return wrap ? wrap.querySelector('.menu') : null;
  }

  document.addEventListener('click', function (e) {
    var trigger = e.target.closest('[data-menu], .profile-btn');
    if (trigger) {
      var panel = panelFor(trigger);
      if (panel) {
        e.preventDefault();
        var willOpen = !panel.classList.contains('open');
        closeAll(panel);
        panel.classList.toggle('open', willOpen);
        trigger.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
        if (willOpen) {
          var first = panel.querySelector('.menu-item, a, button');
          if (first && first.focus) first.focus();
        }
        return;
      }
    }
    // a click inside an open menu should not close it (let the item act first)
    if (e.target.closest('.menu')) return;
    closeAll(null);
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      var open = document.querySelector('.menu.open');
      if (open) {
        var t = document.querySelector('[data-menu="' + open.id + '"]');
        closeAll(null);
        if (t && t.focus) t.focus();   // return focus to the trigger
      }
      var modal = document.querySelector('.modal.open');
      if (modal) window.HomelabShell.closeModal(modal.id);
    }
  });

  /* --- modal / drawer ---------------------------------------------------- */
  function backdrop() {
    var b = document.querySelector('.backdrop');
    if (!b) { b = document.createElement('div'); b.className = 'backdrop'; document.body.appendChild(b); }
    return b;
  }
  var lastFocus = null;

  function openModal(id) {
    var m = document.getElementById(id); if (!m) return;
    lastFocus = document.activeElement;
    backdrop().classList.add('open');
    m.classList.add('open');
    var f = m.querySelector('input, button, select, textarea, [tabindex]');
    if (f && f.focus) f.focus();
  }
  function closeModal(id) {
    var m = id ? document.getElementById(id) : document.querySelector('.modal.open');
    if (m) m.classList.remove('open');
    backdrop().classList.remove('open');
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }
  document.addEventListener('click', function (e) {
    var o = e.target.closest('[data-modal-open]');
    if (o) { e.preventDefault(); openModal(o.getAttribute('data-modal-open')); return; }
    if (e.target.closest('[data-modal-close]') || e.target.classList.contains('backdrop')) closeModal();
  });

  /* --- focus trap while a modal is open ---------------------------------- */
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Tab') return;
    var m = document.querySelector('.modal.open'); if (!m) return;
    var f = m.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])');
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });

  /* --- toasts ------------------------------------------------------------ */
  function toast(message, kind, ms) {
    var host = document.querySelector('.toasts');
    if (!host) { host = document.createElement('div'); host.className = 'toasts'; document.body.appendChild(host); }
    var el = document.createElement('div');
    el.className = 'toast' + (kind ? ' toast--' + kind : '');
    el.setAttribute('role', kind === 'error' ? 'alert' : 'status');
    var span = document.createElement('span'); span.textContent = message; el.appendChild(span);
    var x = document.createElement('button');
    x.className = 'toast__close'; x.type = 'button';
    x.setAttribute('aria-label', 'Dismiss'); x.textContent = '×';
    x.addEventListener('click', function () { el.remove(); });
    el.appendChild(x);
    host.appendChild(el);
    // errors stay until dismissed; anything else self-clears
    if (kind !== 'error') setTimeout(function () { el.remove(); }, ms || 4000);
    return el;
  }

  window.HomelabShell = { toast: toast, openModal: openModal, closeModal: closeModal, closeMenus: function () { closeAll(null); } };
})();
