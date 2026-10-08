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
