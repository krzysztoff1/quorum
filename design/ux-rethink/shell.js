const ICON = {
  sidebar: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M6 2.5v11"/></svg>',
  search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3" stroke-linecap="round"/></svg>',
  ask: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M8 3v10M3 8h10" stroke-linecap="round"/></svg>',
  gear: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M14.2 8h-1.6M3.4 8H1.8M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7 3.6 3.6" stroke-linecap="round"/></svg>',
  folder: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2 4.5c0-.6.4-1 1-1h3.2l1.3 1.5H13c.6 0 1 .4 1 1v6c0 .6-.4 1-1 1H3c-.6 0-1-.4-1-1v-7.5Z"/></svg>',
  graph: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="3.5" cy="8" r="1.6"/><circle cx="12.5" cy="3.5" r="1.6"/><circle cx="12.5" cy="12.5" r="1.6"/><path d="M5 7.3 11 4.2M5 8.7l6 3.1"/></svg>',
  stop: '<svg viewBox="0 0 16 16" fill="currentColor"><rect x="4" y="4" width="8" height="8" rx="1.5"/></svg>',
  enter: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M12.5 3.5v5h-9m0 0 3-3m-3 3 3 3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  check: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><path d="m3.5 8.5 3 3 6-7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  copy: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="5" y="5" width="8.5" height="8.5" rx="1.5"/><path d="M11 5V3.5c0-.6-.4-1-1-1H3.5c-.6 0-1 .4-1 1V10c0 .6.4 1 1 1H5"/></svg>',
  more: '<svg viewBox="0 0 16 16" fill="currentColor"><circle cx="3.5" cy="8" r="1.2"/><circle cx="8" cy="8" r="1.2"/><circle cx="12.5" cy="8" r="1.2"/></svg>',
  bolt: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M9 1.8 3.8 9h4l-1 5.2L12.2 7h-4L9 1.8Z" stroke-linejoin="round"/></svg>',
  layers: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="m8 2 6 3.2-6 3.2-6-3.2L8 2Z" stroke-linejoin="round"/><path d="m2 8.2 6 3.2 6-3.2M2 11l6 3.2 6-3.2" stroke-linejoin="round"/></svg>',
};

const QUESTIONS = [
  { group: 'Running', id: 'predykcja', title: 'Predykcja zamówień — model generatywny', meta: '~6 min left', tier: 'deep', state: 'running', progress: 0.62 },
  { group: 'Today', id: 'personalizacja', title: 'Personalizacja w food-tech', meta: 'Moderate · 1 open conflict', tier: 'deep', state: 'unread', when: '16:24' },
  { group: 'Today', id: 'menu', title: 'Ile pozycji w menu cateringu B2B?', meta: 'Solid · 2 follow-ups', tier: 'quick', when: '11:08' },
  { group: 'Yesterday', id: 'onboarding', title: 'Onboarding u konkurencji (Wolt, Glovo)', meta: 'Solid', tier: 'quick', when: 'Wed' },
  { group: 'Yesterday', id: 'lastmile', title: 'Koszt dostawy last-mile w Warszawie', meta: 'Shaky · 2 open conflicts', tier: 'deep', when: 'Wed' },
  { group: 'This week', id: 'wiz', title: 'Wizualizacja danych o daniach', meta: 'Solid', tier: 'quick', when: 'Mon' },
  { group: 'This week', id: 'normy', title: 'Normy żywieniowe dla posiłków w pracy', meta: 'Moderate', tier: 'deep', when: 'Mon' },
  { group: 'This week', id: 'odpady', title: 'Jak sieci redukują odpady żywności?', meta: 'Solid · 1 follow-up', tier: 'quick', when: 'Mon' },
  { group: 'September', id: 'psych', title: 'Psychologia menu restauracyjnego', meta: 'Moderate', tier: 'deep', when: '28 Sep' },
  { group: 'September', id: 'deepresearch', title: 'Jak oceniać narzędzia deep research', meta: 'Solid', tier: 'deep', when: '24 Sep' },
  { group: 'September', id: 'ceny', title: 'Dynamiczne ceny w lunchach firmowych', meta: 'Shaky', tier: 'quick', when: '19 Sep' },
];

function ring(p) {
  const c = 2 * Math.PI * 5;
  return `<svg class="ring" viewBox="0 0 13 13"><circle class="bg" cx="6.5" cy="6.5" r="5"/><circle class="fg" cx="6.5" cy="6.5" r="5" stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - p)}"/></svg>`;
}

function glyph(q) {
  if (q.state === 'running') return ring(q.progress);
  if (q.state === 'unread') return '<span class="dot"></span>';
  if (q.state === 'scoping') return '<span class="dot amber"></span>';
  return '';
}

function tierTag(tier) {
  return `<span class="tier ${tier}"><span class="d"></span>${tier === 'deep' ? 'Deep' : 'Quick'}</span>`;
}

function renderSidebar(el, opts = {}) {
  const items = opts.items ?? QUESTIONS;
  const overrides = opts.overrides ?? {};
  const rows = items.map(q => ({ ...q, ...(overrides[q.id] ?? {}) }));
  const groups = [];
  for (const q of rows) {
    let g = groups.find(x => x.name === q.group);
    if (!g) { g = { name: q.group, items: [] }; groups.push(g); }
    g.items.push(q);
  }
  const list = rows.length === 0
    ? `<div class="empty-list">Your questions will collect here — newest first, running ones on top.</div>`
    : groups.map(g => `
      <div class="group">
        <div class="group-h">${g.name}${g.name === 'Running' ? `<span class="count">${g.items.length}</span>` : ''}</div>
        ${g.items.map(q => `
          <div class="q ${q.id === opts.selected ? 'sel' : ''} ${q.state === 'unread' ? 'unread' : ''}">
            <span class="glyph">${glyph(q)}</span>
            <span class="t">${q.title}</span>
            <span class="when num">${q.when ?? ''}</span>
            <span class="m">${tierTag(q.tier)}<span style="color:var(--text-4)"> · </span>${q.meta}</span>
          </div>`).join('')}
      </div>`).join('');
  el.innerHTML = `
    <div class="side-top">
      <div class="lights"><i></i><i></i><i></i></div>
      <span class="spacer"></span>
      <span class="icon-btn">${ICON.sidebar}</span>
    </div>
    <div class="ask-btn">${ICON.ask}<span class="grow">Ask a question</span><span class="kbd">N</span></div>
    <div class="list">${list}</div>
    <div class="side-foot">${ICON.folder}<span class="grow">SmartLunch brain</span><span class="icon-btn">${ICON.gear}</span></div>`;
}

function fitStage() {
  const stage = document.querySelector('.stage');
  if (!stage) return;
  const s = Math.min(1, window.innerWidth / 1440);
  stage.style.transform = `scale(${s})`;
  document.body.style.height = `${900 * s}px`;
  document.body.style.overflow = s < 1 ? 'hidden' : '';
}

document.addEventListener('DOMContentLoaded', () => {
  if (new URLSearchParams(location.search).has('clean')) document.body.classList.add('clean');
  document.querySelectorAll('[data-icon]').forEach(n => { n.innerHTML = ICON[n.dataset.icon] + n.innerHTML; });
  fitStage();
});
window.addEventListener('resize', fitStage);
