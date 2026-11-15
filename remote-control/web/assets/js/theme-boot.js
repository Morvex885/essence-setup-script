// Тема до отрисовки (без мигания); логика — как `theme.js` (`readChoice` + `resolve`).
(function () {
  var choice = null;
  try { choice = window.localStorage.getItem('essence-rc-theme'); } catch (e) { choice = null; }
  var dark = choice === 'dark' || (choice !== 'light' && !!window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.setAttribute('data-theme', dark ? 'essence-dark' : 'essence-light');
})();
