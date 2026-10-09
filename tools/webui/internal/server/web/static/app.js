// Page behaviour that needs script. No inline scripts (strict CSP).

/* widgets */
document.addEventListener('keydown', function (e) {
  if (e.key !== 'Enter' || !e.target.dataset || !e.target.dataset.enter) return;
  e.preventDefault();
  var b = document.getElementById(e.target.dataset.enter);
  if (b) b.click();
});
document.addEventListener('click', function (e) {
  var b = e.target.closest && e.target.closest('[data-add-line]');
  if (!b) return;
  var t = document.getElementById(b.dataset.target);
  if (!t) return;
  var lines = t.value.split('\n').map(function (l) { return l.trim(); }).filter(Boolean);
  if (lines.indexOf(b.dataset.addLine) < 0) lines.push(b.dataset.addLine);
  t.value = lines.join('\n');
});
/* end widgets */

/* forms marked data-once: ignore repeat submits while the page loads */
document.addEventListener('submit', function (e) {
  var f = e.target;
  if (!f.hasAttribute || !f.hasAttribute('data-once')) return;
  if (f.classList.contains('busy')) { e.preventDefault(); return; }
  f.classList.add('busy');
  f.setAttribute('aria-busy', 'true');
});
/* back/forward cache restores the busy state; clear it */
window.addEventListener('pageshow', function () {
  document.querySelectorAll('form.busy').forEach(function (f) {
    f.classList.remove('busy');
    f.removeAttribute('aria-busy');
  });
});

/* raw log: follow new lines unless the user scrolled up */
document.addEventListener('DOMContentLoaded', function () {
  var log = document.getElementById('rawlog');
  if (!log || !window.MutationObserver) return;
  var follow = true;
  log.addEventListener('scroll', function () {
    follow = log.scrollHeight - log.scrollTop - log.clientHeight < 24;
  });
  new MutationObserver(function () {
    if (follow) log.scrollTop = log.scrollHeight;
  }).observe(log, { childList: true });
});

/* theme picker: system (default), light or dark, kept in localStorage */
document.addEventListener('DOMContentLoaded', function () {
  var wrap = document.getElementById('theme');
  if (!wrap) return;
  var sel = wrap.querySelector('select'), root = document.documentElement;
  sel.value = root.dataset.theme || 'system';
  wrap.hidden = false;
  sel.addEventListener('change', function () {
    try {
      if (sel.value === 'system') localStorage.removeItem('theme');
      else localStorage.setItem('theme', sel.value);
    } catch (e) { /* storage disabled: applies to this page only */ }
    if (sel.value === 'system') delete root.dataset.theme;
    else root.dataset.theme = sel.value;
  });
});

/* inputs with data-match: the form's submit buttons stay disabled until the
   typed value matches (the server checks it again) */
function syncMatch(i) {
  i.form.querySelectorAll('button[type=submit]').forEach(function (b) {
    b.disabled = i.value !== i.dataset.match;
  });
}
document.addEventListener('DOMContentLoaded', function () {
  document.querySelectorAll('input[data-match]').forEach(syncMatch);
});
document.addEventListener('input', function (e) {
  if (e.target.dataset && e.target.dataset.match !== undefined) syncMatch(e.target);
});

/* forms with data-confirm: ask in a dialog first. Capture phase, so it runs
   before the data-once handler. Cancel has the focus and Escape cancels. */
function confirmDialog(title, msg, label, ok) {
  var d = document.getElementById('confirm-dialog');
  if (!d) {
    d = document.createElement('dialog');
    d.id = 'confirm-dialog';
    d.className = 'dialog';
    d.setAttribute('aria-labelledby', 'confirm-dialog-title');
    d.innerHTML = '<form method="dialog"><h2 id="confirm-dialog-title"></h2><p></p><div class="actions">' +
      '<button value="cancel" class="secondary">Cancel</button><button value="ok" class="danger"></button></div></form>';
    document.body.appendChild(d);
  }
  d.querySelector('h2').textContent = title;
  d.querySelector('p').textContent = msg;
  d.querySelector('button.danger').textContent = label;
  d.returnValue = '';
  d.onclose = function () { if (d.returnValue === 'ok') ok(); };
  d.showModal();
  d.querySelector('button.secondary').focus();
}
document.addEventListener('submit', function (e) {
  var f = e.target;
  if (!f.dataset || !f.dataset.confirm || f.dataset.confirmed) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  confirmDialog(f.dataset.confirmTitle || 'Are you sure?', f.dataset.confirm, f.dataset.confirmLabel || 'Continue', function () {
    f.dataset.confirmed = '1';
    f.requestSubmit();
  });
}, true);
window.addEventListener('pageshow', function () {
  document.querySelectorAll('form[data-confirmed]').forEach(function (f) { delete f.dataset.confirmed; });
});
