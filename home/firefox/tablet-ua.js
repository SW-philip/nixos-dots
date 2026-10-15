// Tablet mode (Type Cover detached, per surface-kbd-monitor's state file):
// present as Firefox for Android on a tablet so sites serve their mobile layout.
// Polled because nothing else can tell a running Firefox about the cover.
// Plain XPCOM file reads: IOUtils isn't exposed in the autoconfig sandbox global.
Services.obs.addObserver(function init() {
  Services.obs.removeObserver(init, "final-ui-startup");
  const { setInterval } = ChromeUtils.importESModule("resource://gre/modules/Timer.sys.mjs");
  const dir = Services.env.get("XDG_RUNTIME_DIR");
  if (!dir) return;
  const v = Services.appinfo.version;
  // No "Mobile" token: Android sites read that as tablet and keep the wider layout.
  const ua = "Mozilla/5.0 (Android 14; Tablet; rv:" + v + ") Gecko/" + v + " Firefox/" + v;
  const read = () => {
    const f = Components.classes["@mozilla.org/file/local;1"]
      .createInstance(Components.interfaces.nsIFile);
    f.initWithPath(dir + "/surface-cover");
    if (!f.exists()) return "";
    const fs = Components.classes["@mozilla.org/network/file-input-stream;1"]
      .createInstance(Components.interfaces.nsIFileInputStream);
    fs.init(f, 1, 0, 0);
    const sis = Components.classes["@mozilla.org/scriptableinputstream;1"]
      .createInstance(Components.interfaces.nsIScriptableInputStream);
    sis.init(fs);
    try { return sis.read(sis.available()); } finally { sis.close(); }
  };
  let last = null;
  setInterval(() => {
    let tablet;
    try {
      tablet = read().trim() === "detached";
    } catch (e) {
      Services.console.logStringMessage("tablet-ua: " + e);
      return;
    }
    if (tablet === last) return;
    last = tablet;
    if (tablet) Services.prefs.setStringPref("general.useragent.override", ua);
    else Services.prefs.clearUserPref("general.useragent.override");
  }, 2000);
}, "final-ui-startup");
