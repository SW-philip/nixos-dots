p: ''
/* ── about: pages and blank documents ───────────────────────── */
@-moz-document url("about:blank"), url("about:home"), url("about:newtab") {
  :root, html {
    background-color: ${p.HALL} !important;
    color: ${p.SCORE} !important;
  }
  body {
    background-color: ${p.HALL} !important;
    color: ${p.SCORE} !important;
  }
  a           { color: ${p.FIFTH} !important; }
  a:visited   { color: ${p.ROOT} !important; }
  a:hover     { color: ${p.SCORE} !important; }
}

/* ── Reader View ─────────────────────────────────────────────── */
@-moz-document url-prefix("about:reader") {
  body, .container, .content-width, .page {
    background-color: ${p.HALL} !important;
    color: ${p.SCORE} !important;
  }
  h1, h2, h3, h4, h5, h6 {
    color: ${p.SCORE} !important;
  }
  a         { color: ${p.FIFTH} !important; }
  a:visited { color: ${p.ROOT} !important; }
  blockquote {
    border-left: 3px solid ${p.ROOT} !important;
    color: ${p.REST} !important;
  }
  code, pre {
    background-color: ${p.STAGE} !important;
    color: ${p.SOTTO} !important;
    border-radius: 4px !important;
    padding: 2px 4px !important;
  }
  .toolbar {
    background-color: ${p.STAGE} !important;
    color: ${p.SCORE} !important;
    border-bottom: 1px solid ${p.WING} !important;
  }
}

/* ── PDF viewer ──────────────────────────────────────────────── */
@-moz-document url-prefix("resource://pdf.js/") {
  body {
    background-color: ${p.WING} !important;
  }
  #toolbarContainer, #secondaryToolbar {
    background-color: ${p.STAGE} !important;
    color: ${p.SCORE} !important;
    border-bottom: 1px solid ${p.MUTE} !important;
  }
  .toolbarButton, .secondaryToolbarButton {
    color: ${p.REST} !important;
  }
  .toolbarButton:hover, .secondaryToolbarButton:hover {
    background-color: ${p.MUTE} !important;
    color: ${p.SCORE} !important;
  }
  #viewerContainer {
    background-color: ${p.WING} !important;
  }
}
''
