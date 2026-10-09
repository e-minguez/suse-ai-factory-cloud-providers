// Applies the stored theme before the first paint (loaded without defer).
// No stored value: the system preference applies. The picker is in app.js.
(function () {
  try {
    var t = localStorage.getItem('theme');
    if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
  } catch (e) { /* storage disabled: follow the system */ }
})();
