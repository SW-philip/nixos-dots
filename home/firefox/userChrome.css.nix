p: ''
/* ── Reset Firefox chrome defaults ──────────────────────── */
:root {
  --toolbar-bgcolor: ${p.HALL} !important;
  --toolbar-color: ${p.SCORE} !important;
  --tab-selected-bgcolor: ${p.STAGE} !important;
  /* Modern URL bar variables */
  --urlbar-box-bgcolor: ${p.WING} !important;
  --urlbar-box-focus-bgcolor: ${p.WING} !important;
  --urlbar-box-hover-bgcolor: ${p.MUTE} !important;
  --urlbar-box-active-bgcolor: ${p.MUTE} !important;
  --urlbar-popup-bgcolor: ${p.STAGE} !important;
  --urlbar-popup-color: ${p.SCORE} !important;
  /* Legacy LWT variables — older Firefox builds still read these */
  --lwt-toolbar-field-background-color: ${p.WING} !important;
  --lwt-toolbar-field-focus: ${p.WING} !important;
  --lwt-toolbar-field-color: ${p.SCORE} !important;
  --lwt-toolbar-field-focus-color: ${p.SCORE} !important;
}

/* ── Tab bar ─────────────────────────────────────────────── */
#TabsToolbar {
  background-color: ${p.HALL} !important;
  border-bottom: 1px solid ${p.WING} !important;
}

.tab-background {
  background-color: transparent !important;
  border-radius: 6px 6px 0 0 !important;
  border: none !important;
}

.tabbrowser-tab[selected="true"] .tab-background {
  background-color: ${p.STAGE} !important;
  box-shadow: inset 0 2px 0 ${p.ROOT} !important;
}

.tabbrowser-tab:not([selected]):hover .tab-background {
  background-color: ${p.MUTE} !important;
}

.tab-label {
  color: ${p.REST} !important;
}

.tabbrowser-tab[selected="true"] .tab-label {
  color: ${p.SCORE} !important;
}

.tabbrowser-tab[attention] .tab-label {
  color: ${p.PIANO} !important;
}

/* ── Nav / URL bar ───────────────────────────────────────── */
#nav-bar {
  background-color: ${p.HALL} !important;
  border-bottom: 1px solid ${p.WING} !important;
  box-shadow: none !important;
}

#urlbar {
  background-color: ${p.WING} !important;
  border: 1px solid ${p.MUTE} !important;
  border-radius: 8px !important;
  color: ${p.SCORE} !important;
  -moz-appearance: none !important;
}

#urlbar[focused="true"],
#urlbar[open] {
  border-color: ${p.ROOT} !important;
  box-shadow: 0 0 0 2px rgba(${p.ROOT_RGB}, 0.25) !important;
}

/* -moz-appearance: none strips the native UA draw call that can paint white
   over background-color regardless of !important specificity. */
#urlbar-background {
  background-color: ${p.WING} !important;
  -moz-appearance: none !important;
  border: none !important;
}

#urlbar[focused="true"] #urlbar-background,
#urlbar[open] #urlbar-background {
  background-color: ${p.WING} !important;
}

#urlbar-input-container {
  background-color: transparent !important;
  color: ${p.SCORE} !important;
}

#urlbar-input {
  color: ${p.SCORE} !important;
  background-color: transparent !important;
  -moz-appearance: none !important;
}

#urlbar-input::placeholder {
  color: ${p.BAR} !important;
  opacity: 1 !important;
}

.urlbar-icon,
.urlbar-icon-wrapper {
  color: ${p.BAR} !important;
  fill: ${p.BAR} !important;
}

/* ── URL bar dropdown (suggestions panel) ────────────────── */
.urlbarView {
  background-color: ${p.STAGE} !important;
  color: ${p.SCORE} !important;
  -moz-appearance: none !important;
  border: 1px solid ${p.WING} !important;
  border-top: none !important;
  border-radius: 0 0 8px 8px !important;
}

.urlbarView-body-inner {
  background-color: transparent !important;
}

.urlbarView-results {
  background-color: transparent !important;
  padding: 4px !important;
}

.urlbarView-row {
  background-color: transparent !important;
  border-radius: 4px !important;
}

.urlbarView-row[selected],
.urlbarView-row:hover {
  background-color: ${p.MUTE} !important;
}

.urlbarView-row-inner {
  color: ${p.SCORE} !important;
}

.urlbarView-title,
.urlbarView-title-separator,
.urlbarView-secondary {
  color: ${p.REST} !important;
}

.urlbarView-url {
  color: ${p.FIFTH} !important;
}

.urlbarView-row[selected] .urlbarView-title,
.urlbarView-row[selected] .urlbarView-url,
.urlbarView-row[selected] .urlbarView-secondary {
  color: ${p.SCORE} !important;
}

/* ── Bookmarks / personal toolbar ────────────────────────── */
#PersonalToolbar {
  background-color: ${p.HALL} !important;
  border-bottom: 1px solid ${p.WING} !important;
}

.bookmark-item > .toolbarbutton-text {
  color: ${p.REST} !important;
}

.bookmark-item:hover > .toolbarbutton-text {
  color: ${p.SCORE} !important;
}

/* ── Toolbar buttons ─────────────────────────────────────── */
#nav-bar .toolbarbutton-1 {
  color: ${p.REST} !important;
  fill: ${p.REST} !important;
  border-radius: 6px !important;
}

#nav-bar .toolbarbutton-1:hover {
  background-color: ${p.MUTE} !important;
  color: ${p.SCORE} !important;
  fill: ${p.SCORE} !important;
}

#nav-bar .toolbarbutton-1[open],
#nav-bar .toolbarbutton-1:active {
  background-color: ${p.MUTE} !important;
  color: ${p.ROOT} !important;
  fill: ${p.ROOT} !important;
}

/* ── Sidebar ─────────────────────────────────────────────── */
#sidebar-box {
  background-color: ${p.STAGE} !important;
  border-right: 1px solid ${p.WING} !important;
}

#sidebar-header {
  background-color: ${p.HALL} !important;
  color: ${p.SCORE} !important;
  border-bottom: 1px solid ${p.WING} !important;
}

/* ── Find bar ────────────────────────────────────────────── */
.findbar-container {
  background-color: ${p.WING} !important;
  border-top: 1px solid ${p.MUTE} !important;
}

.findbar-textbox {
  background-color: ${p.STAGE} !important;
  color: ${p.SCORE} !important;
  border: 1px solid ${p.MUTE} !important;
  border-radius: 4px !important;
}
''
