// Talks to wroopmark natively, routes captures from the page hooks, and
// backs the popup and the context menu.
//
// Chromium: a long-lived port to the `wroopmark` native-messaging host.
// Safari:   one message per call to the extension's own native handler
//           (SafariWebExtensionHandler), which runs the same Rust core.

const HOST = "com.wroopmark.host";
const IS_SAFARI = chrome.runtime.getURL("").startsWith("safari-web-extension:");
const IDLE_MS = 90_000; // let the host process exit when nothing happens

let port = null;
let seq = 0;
let idleTimer = null;
const pending = new Map();

function connect() {
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    const done = pending.get(msg.rid);
    if (done) {
      pending.delete(msg.rid);
      done(msg);
    }
  });
  port.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message || "wroopmark bağlantısı koptu";
    port = null;
    for (const done of pending.values()) done({ ok: false, error });
    pending.clear();
  });
}

// Closes the port after a quiet spell, but never under a running request
// (a URL capture with a video can take minutes).
function armIdle() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => (pending.size ? armIdle() : port?.disconnect()), IDLE_MS);
}

function call(cmd, args = {}) {
  if (IS_SAFARI) {
    return browser.runtime
      .sendNativeMessage(HOST, { ...args, cmd })
      .then((r) => r ?? { ok: false, error: "wroopmark yanıt vermedi" }, (e) => ({ ok: false, error: String(e) }));
  }
  armIdle();
  return new Promise((resolve) => {
    try {
      if (!port) connect();
      const rid = ++seq;
      pending.set(rid, resolve);
      port.postMessage({ ...args, cmd, rid });
    } catch (e) {
      resolve({ ok: false, error: String(e) });
    }
  });
}

// --- badge ------------------------------------------------------------------

async function bump(report) {
  const { session = { new: 0, updated: 0, errors: 0, last: null } } = await chrome.storage.session.get("session");
  if (report.ok) {
    session.new += report.data?.new ?? (report.data?.id ? 1 : 0);
    session.updated += report.data?.updated ?? 0;
  } else {
    session.errors += 1;
  }
  session.last = report.ok ? null : report.error;
  await chrome.storage.session.set({ session });
  chrome.action.setBadgeBackgroundColor({ color: report.ok ? "#774aed" : "#b3261e" });
  chrome.action.setBadgeText({ text: report.ok ? (session.new ? String(session.new) : "✓") : "!" });
}

// --- captures from hook.js --------------------------------------------------

// One line in the library's host.log; shows what the extensions see.
function log(line) {
  return call("log", { line: `${IS_SAFARI ? "safari" : "chrome"} ${line}` });
}

async function onCapture(msg, tabId) {
  if (msg.kind === "diag") {
    log(JSON.stringify(msg.payload));
    return;
  }
  try {
    await handleCapture(msg, tabId);
  } catch (e) {
    log(`${msg.kind}: işlenemedi: ${e && e.stack ? e.stack.split("\n")[0] : e}`);
  }
}

// Everything the hook forwards is the user's own: X bookmarks, and TikTok
// lists from the user's own profile tabs (the hook skips other profiles).
async function handleCapture({ kind, payload }, tabId) {
  let report;
  switch (kind) {
    case "x_timeline":
    case "x_tweet":
      report = await call("import_x", { payload });
      break;
    case "x_url":
      report = await call("add_url", { url: `https://x.com/i/status/${payload}` });
      break;
    case "tiktok_list":
    case "tiktok_item":
      log(`${kind} alındı: ${payload.itemList.length} öğe, ${Math.round(JSON.stringify(payload).length / 1024)} KB`);
      report = await call("import_tiktok", { payload });
      log(`${kind}: ${report.ok ? `${report.data.new} yeni, ${report.data.updated} güncellendi` : `HATA ${report.error}`}`);
      if (report.ok && tabId != null) fetchMissingVideos(tabId, report.data.ids);
      break;
    case "tiktok_url":
      report = await call("add_url", { url: `https://m.tiktok.com/v/${payload}.html` });
      break;
    default:
      return;
  }
  // An empty bookmarks page (end of list) is not news.
  if (report.ok && (kind === "x_timeline" || kind === "tiktok_list") && !report.data.new && !report.data.updated) return;
  await bump(report);
}

// TikTok videos can only be downloaded by TikTok's own page; ask it to send
// the ones the library lacks (see sendVideos in hook.js).
async function fetchMissingVideos(tabId, ids) {
  const needed = await call("videos_needed", { ids });
  if (needed.ok && needed.data.length) {
    chrome.tabs.sendMessage(tabId, { type: "fetch_videos", ids: needed.data }).catch(() => {});
  }
}

// --- saving the current tab ---------------------------------------------------

// Injected into the page: what the reader sees, including behind logins
// (Facebook, Pinterest boards, paywalled articles).
function capturePage(selection) {
  const meta = (...keys) => {
    for (const k of keys) {
      const el = document.querySelector(`meta[property="${k}"],meta[name="${k}"]`);
      if (el && el.content && el.content.trim()) return el.content.trim();
    }
    return null;
  };
  const abs = (u) => {
    try {
      return new URL(u, location.href).href;
    } catch {
      return null;
    }
  };
  const root = document.querySelector('[role="article"]') || document.querySelector("article") || document.querySelector("main") || document.body;
  const media = [];
  const og = meta("og:image", "twitter:image");
  if (og && abs(og)) media.push({ kind: "image", url: abs(og) });
  for (const img of root.querySelectorAll("img")) {
    const src = img.currentSrc || img.src;
    if (img.naturalWidth < 300 || img.naturalHeight < 200 || !src.startsWith("http")) continue;
    if (media.some((m) => m.url === src) || media.length >= 6) continue;
    media.push({ kind: "image", url: src, width: img.naturalWidth, height: img.naturalHeight, alt: img.alt || undefined });
  }
  const published = Date.parse(meta("article:published_time") || "");
  return {
    url: location.href,
    title: meta("og:title", "twitter:title") || document.title || null,
    text: (selection || "").trim() || meta("og:description", "twitter:description", "description") || "",
    extra: (root.innerText || "").trim().slice(0, 20000) || null,
    author_name: meta("author", "article:author"),
    created_at: Number.isFinite(published) ? Math.floor(published / 1000) : null,
    media,
  };
}

const POST_ID = [
  { re: /^https:\/\/(?:x|twitter)\.com\/[^/]+\/status\/(\d+)/, kind: "x" },
  { re: /^https:\/\/www\.tiktok\.com\/@[^/]+\/(?:video|photo)\/(\d+)/, kind: "tiktok" },
];

// Polls the library until the item is there (the hook saves it through
// its own message); false after `ms`.
async function waitSaved(id, ms) {
  for (const end = Date.now() + ms; Date.now() < end; ) {
    const r = await call("get", { id });
    if (r.ok && r.data) return true;
    await sleep(500);
  }
  return false;
}

async function saveTab(tab, { tags = [], note = null, selection = null } = {}) {
  for (const { re, kind } of POST_ID) {
    const m = tab.url.match(re);
    if (!m) continue;
    // The hook knows the post if the page loaded it, or falls back to a URL
    // capture; either way it lands in the library through onCapture. Tags
    // and the note go on once it is really there.
    const id = `${kind}:${m[1]}`;
    const before = await call("get", { id });
    const known = before.ok && before.data;
    const asked = await chrome.tabs.sendMessage(tab.id, { type: "save_cached", kind, id: m[1] }).catch(() => null);
    if (!asked) break;
    // A URL capture downloads media first, so this can take a while.
    if (!known && !(await waitSaved(id, 45_000))) {
      return { ok: false, error: "Gönderi henüz kütüphanede görünmüyor. Sayfayı yenileyip tekrar dene." };
    }
    if (tags.length) await call("edit_tags", { ids: [id], add: tags });
    if (note) await call("set_note", { id, note });
    return { ok: true, data: { id } };
  }
  let item;
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: capturePage, args: [selection] });
    item = res.result;
  } catch {
    // chrome:// pages, the Web Store, PDFs: let the core fetch it instead.
    const report = await call("add_url", { url: tab.url, tags, note });
    await bump(report);
    return report;
  }
  item.note = note;
  const report = await call("import_items", { items: [item], tags });
  await bump(report);
  return report.ok ? { ok: true, data: { id: report.data.ids[0] } } : report;
}

// --- context menu -------------------------------------------------------------

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "save", title: "wroopmark'a kaydet", contexts: ["page", "selection", "link", "image"] });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.mediaType === "image" && info.srcUrl) {
    const item = { url: info.srcUrl, title: tab?.title ?? null, text: "", media: [{ kind: "image", url: info.srcUrl }], links: [info.pageUrl] };
    await bump(await call("import_items", { items: [item] }));
  } else if (info.linkUrl) {
    await bump(await call("add_url", { url: info.linkUrl }));
  } else if (tab) {
    await saveTab(tab, { selection: info.selectionText ?? null });
  }
});

// --- messages from relay.js and the popup -----------------------------------

// Messages that act on the library directly come only from the extension's
// own pages (the popup, which has no tab); content scripts on x.com and
// tiktok.com may only hand over captures and video chunks.
const EXT_ORIGIN = chrome.runtime.getURL("");
const fromExtensionPage = (sender) => !sender.tab && (!sender.url || sender.url.startsWith(EXT_ORIGIN));
const POPUP_ONLY = new Set(["call", "save_tab", "scan_x", "scan_tiktok", "stop_scan"]);

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (POPUP_ONLY.has(msg.type) && !fromExtensionPage(sender)) {
    reply({ ok: false, error: "izin yok" });
    return false;
  }
  switch (msg.type) {
    case "capture":
      onCapture(msg, sender.tab?.id);
      return false;
    case "video_chunk":
      call("upload_chunk", msg.chunk).then(reply);
      return true;
    case "autoscroll_done":
      onScrollDone();
      return false;
    case "call":
      call(msg.cmd, msg.args).then(reply);
      return true;
    case "save_tab":
      chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => saveTab(tab, msg).then(reply));
      return true;
    case "scan_x":
      scanX().then(reply);
      return true;
    case "scan_tiktok":
      scanTikTok().then(reply);
      return true;
    case "stop_scan":
      chrome.storage.session.get("scanTab").then(({ scanTab }) => {
        if (scanTab) chrome.tabs.sendMessage(scanTab, { type: "autoscroll", on: false }).catch(() => {});
        chrome.storage.session.set({ scanning: false });
        reply({ ok: true });
      });
      return true;
  }
  return false;
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function waitLoaded(tabId) {
  return new Promise((resolve) => {
    const check = (id, info) => {
      if (id === tabId && info.status === "complete") {
        chrome.tabs.onUpdated.removeListener(check);
        resolve();
      }
    };
    chrome.tabs.onUpdated.addListener(check);
    chrome.tabs.get(tabId).then((t) => t.status === "complete" && check(tabId, { status: "complete" }));
  });
}

async function startScroll(tabId, platform) {
  await chrome.storage.session.set({ scanning: platform, scanTab: tabId });
  return chrome.tabs.sendMessage(tabId, { type: "autoscroll", on: true }).catch((e) => ({ ok: false, error: String(e) }));
}

// Opens the signed-in user's profile, switches to Favorites and scrolls to
// the end, then does the same with Liked (see onScrollDone); hook.js
// forwards each page of both lists, and their videos.
async function scanTikTok() {
  // Start from an open TikTok tab if there is one (it may already be the
  // profile); otherwise open TikTok.
  let [tab] = await chrome.tabs.query({ active: true, currentWindow: true, url: "https://www.tiktok.com/*" });
  if (!tab) [tab] = await chrome.tabs.query({ url: "https://www.tiktok.com/*" });
  if (tab) {
    await chrome.tabs.update(tab.id, { active: true });
  } else {
    tab = await chrome.tabs.create({ url: "https://www.tiktok.com/" });
    await waitLoaded(tab.id);
    await sleep(2500);
  }
  const profile = await chrome.tabs.sendMessage(tab.id, { type: "profile_url" }).catch(() => null);
  if (!profile || !profile.url) {
    log("tiktok tarama: profil bağlantısı bulunamadı (giriş yapılmamış ya da site izni yok)");
    return { ok: false, error: "TikTok'ta profil bulunamadı: giriş yapılmış mı, eklentinin tiktok.com izni var mı?" };
  }
  log(`tiktok tarama: profil ${profile.url}`);
  const current = (await chrome.tabs.get(tab.id)).url || "";
  if (!current.startsWith(profile.url)) {
    await chrome.tabs.update(tab.id, { url: profile.url });
    await waitLoaded(tab.id);
    await sleep(3000);
  }
  const opened = await chrome.tabs.sendMessage(tab.id, { type: "open_tab", tab: "favorites-tab" }).catch(() => null);
  log(`tiktok tarama: ${profile.url} favoriler sekmesi ${opened && opened.ok ? "açıldı" : "bulunamadı"}`);
  if (!opened || !opened.ok) return { ok: false, error: "Favoriler sekmesi bulunamadı" };
  await sleep(2500);
  await chrome.storage.session.set({ tiktokStage: "favorites" });
  return startScroll(tab.id, "tiktok");
}

// Favorites done → Liked; anything else done → stop.
async function onScrollDone() {
  const { scanning, scanTab, tiktokStage } = await chrome.storage.session.get(["scanning", "scanTab", "tiktokStage"]);
  if (scanning === "tiktok" && tiktokStage === "favorites" && scanTab != null) {
    await chrome.storage.session.set({ tiktokStage: "liked" });
    await chrome.tabs.sendMessage(scanTab, { type: "scroll_top" }).catch(() => {});
    const opened = await chrome.tabs.sendMessage(scanTab, { type: "open_tab", tab: "liked-tab" }).catch(() => null);
    log(`tiktok tarama: beğenilenler sekmesi ${opened && opened.ok ? "açıldı" : "bulunamadı"}`);
    if (opened && opened.ok) {
      await sleep(2500);
      await startScroll(scanTab, "tiktok");
      return;
    }
  }
  if (scanning) log(`${scanning} tarama bitti`);
  await chrome.storage.session.set({ scanning: false, tiktokStage: null });
}

// Opens the bookmarks page and scrolls it to the end; hook.js forwards every
// page of results on the way.
async function scanX() {
  const url = "https://x.com/i/bookmarks";
  let [tab] = await chrome.tabs.query({ url: ["https://x.com/i/bookmarks*", "https://twitter.com/i/bookmarks*"] });
  if (tab) {
    // An open tab has already received its first page (the newest
    // bookmarks); reload so the hook sees the list from the top.
    await chrome.tabs.update(tab.id, { active: true });
    await chrome.tabs.reload(tab.id);
  } else {
    tab = await chrome.tabs.create({ url });
  }
  await waitLoaded(tab.id);
  await sleep(2500);
  return startScroll(tab.id, "x");
}
