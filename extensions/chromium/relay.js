// Isolated-world bridge: page (hook.js) ⇄ extension (background.js).
// Also drives the auto-scroll that walks the whole X bookmarks list.

// Chromium runs hook.js in the page's world straight from the manifest.
// Where that is not available (Safari), load it as a page script instead;
// it is listed in web_accessible_resources for these sites.
if (document.documentElement && !document.documentElement.dataset.wroopmarkHooked) {
  const s = document.createElement("script");
  s.src = chrome.runtime.getURL("hook.js");
  (document.head || document.documentElement).appendChild(s);
  s.onload = () => s.remove();
}

window.addEventListener("message", (e) => {
  if (e.source !== window || !e.data) return;
  const m = e.data;
  if (m.__wroopmark === "capture") {
    chrome.runtime.sendMessage({ type: "capture", kind: m.kind, payload: m.payload }).catch((err) => {
      // Usually a message too large for the browser; report it small.
      const size = JSON.stringify(m.payload || "").length;
      chrome.runtime.sendMessage({ type: "capture", kind: "diag", payload: { event: "relay_error", kind: m.kind, kb: Math.round(size / 1024), error: String(err) } }).catch(() => {});
    });
  } else if (m.__wroopmark === "video_chunk") {
    const ack = (ok) => window.postMessage({ __wroopmark: "chunk_ack", key: m.key, ok }, location.origin);
    chrome.runtime.sendMessage({ type: "video_chunk", chunk: m.chunk }).then((r) => ack(!!(r && r.ok)), () => ack(false));
  }
});

// On a TikTok post page, the post's video is fetched if the library has
// the post but not its video yet (TikTok navigates without reloading).
let lastPostPage = null;
function checkPostPage() {
  const m = location.hostname.endsWith("tiktok.com") && location.pathname.match(/^\/@[^/]+\/video\/(\d+)/);
  const id = m ? m[1] : null;
  if (!id || id === lastPostPage) return;
  lastPostPage = id;
  chrome.runtime.sendMessage({ type: "post_page", id: `tiktok:${id}` }).catch(() => {});
}
if (location.hostname.endsWith("tiktok.com")) {
  window.addEventListener("load", () => setTimeout(checkPostPage, 1500), { once: true });
  setInterval(checkPostPage, 2000);
}

let scroller = null;

function autoscroll(on) {
  clearInterval(scroller);
  scroller = null;
  if (!on) return;
  let lastHeight = 0;
  let idle = 0;
  scroller = setInterval(() => {
    const h = document.scrollingElement.scrollHeight;
    idle = h === lastHeight ? idle + 1 : 0;
    lastHeight = h;
    // ~10 s without new content: the end of the list.
    if (idle >= 8) {
      autoscroll(false);
      chrome.runtime.sendMessage({ type: "autoscroll_done" }).catch(() => {});
      return;
    }
    window.scrollBy(0, window.innerHeight * 0.9);
  }, 1250);
}

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg.type === "autoscroll") {
    autoscroll(msg.on);
    reply({ ok: true });
  } else if (msg.type === "profile_url") {
    // The signed-in user, from the state TikTok embeds in every page; the
    // navigation bar's profile link as a fallback.
    let user = document.documentElement.dataset.wroopmarkUser || null;
    if (!user) {
      try {
        const state = JSON.parse(document.getElementById("__UNIVERSAL_DATA_FOR_REHYDRATION__").textContent);
        user = state.__DEFAULT_SCOPE__["webapp.app-context"].user.uniqueId || null;
      } catch {}
    }
    let url = user ? `https://www.tiktok.com/@${user}` : null;
    if (!url) {
      const a = document.querySelector('[data-e2e="nav-profile"]');
      const link = a && (a.closest("a") || a.querySelector("a"));
      url = link ? link.href : null;
    }
    // Already on a profile page: take it as the user's own.
    if (!url) {
      const m = location.pathname.match(/^\/@[^/]+/);
      if (m) url = location.origin + m[0];
    }
    reply({ url });
  } else if (msg.type === "scroll_top") {
    window.scrollTo(0, 0);
    reply({ ok: true });
  } else if (msg.type === "open_tab") {
    const el = document.querySelector(`[data-e2e="${msg.tab}"]`);
    if (el) el.click();
    reply({ ok: !!el });
  } else if (msg.type === "fetch_videos") {
    window.postMessage({ __wroopmark: "fetch_videos", ids: msg.ids }, location.origin);
    reply({ ok: true });
  } else if (msg.type === "save_cached") {
    window.postMessage({ __wroopmark: "save_cached", kind: msg.kind, id: msg.id }, location.origin);
    reply({ ok: true });
  }
});
