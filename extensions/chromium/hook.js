// Runs in the page's own JS world on x.com and tiktok.com. Listens to the
// API responses the site's web client already receives — nothing is fetched
// on our side — and hands the interesting ones to relay.js.
//
// X:      Bookmarks timelines are forwarded whole. Every tweet seen in any
//         GraphQL response is remembered, so when you press the bookmark
//         button (CreateBookmark) that exact tweet can be saved at once.
// TikTok: Favorites, Liked and Collections lists are forwarded whole; items seen
//         anywhere are remembered for the moment you press "favorite"
//         (item/collect). What it sees is reported to the log ("diag").
(() => {
  if (window.__wroopmarkHooked) return;
  window.__wroopmarkHooked = true;
  // Tells relay.js (isolated world) the hook is in; see its fallback.
  document.documentElement.dataset.wroopmarkHooked = "1";

  const host = location.hostname.replace(/^www\./, "");
  const isX = host === "x.com" || host === "twitter.com";
  const seen = new Map(); // post id -> raw object, oldest first
  const SEEN_MAX = 4000;

  const remember = (id, obj) => {
    if (!id || !obj) return;
    seen.delete(id);
    seen.set(id, obj);
    if (seen.size > SEEN_MAX) seen.delete(seen.keys().next().value);
  };
  const post = (kind, payload) => window.postMessage({ __wroopmark: "capture", kind, payload }, location.origin);

  // The signed-in TikTok user. TikTok embeds it in the page and removes the
  // element after hydrating, so it is read as early as possible and left
  // on <html> for relay.js (which finds the profile for the scan button).
  let me = null;
  function readMe() {
    if (isX || me) return me;
    try {
      const el = document.getElementById("__UNIVERSAL_DATA_FOR_REHYDRATION__");
      me = JSON.parse(el.textContent).__DEFAULT_SCOPE__["webapp.app-context"].user.uniqueId || null;
    } catch {}
    if (me) document.documentElement.dataset.wroopmarkUser = me;
    return me;
  }
  readMe();
  document.addEventListener("DOMContentLoaded", readMe);
  // Watch for the element only until it is read or the page has loaded.
  const meWatch = new MutationObserver(() => readMe() && meWatch.disconnect());
  if (!isX && !me) {
    meWatch.observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener("load", () => meWatch.disconnect(), { once: true });
  }

  // Someone else's public Liked tab uses the same API; those aren't yours.
  const onOwnProfile = () => {
    readMe();
    return !me || location.pathname.toLowerCase().startsWith(`/@${me.toLowerCase()}`);
  };

  // Loaded from the manifest (MAIN world) or injected by relay.js as a
  // <script> (Safari); the log tells which, per site.
  post("diag", { event: "hook", host, via: document.currentScript ? "script" : "main" });

  const unwrapTweet = (r) => (r && r.legacy ? r : r && r.tweet ? unwrapTweet(r.tweet) : null);

  function indexX(v) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach(indexX);
    const t = v.tweet_results && unwrapTweet(v.tweet_results.result);
    if (t) remember(t.rest_id, t);
    for (const k in v) indexX(v[k]);
  }

  function indexTikTok(v) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach(indexTikTok);
    if (typeof v.id === "string" && "desc" in v && v.author) remember(v.id, v);
    for (const k in v) indexTikTok(v[k]);
  }

  function bodyVar(body, name) {
    try {
      return JSON.parse(body).variables[name];
    } catch {
      return null;
    }
  }

  // The post a TikTok video page was rendered with (not from an API call).
  function pageItem(id) {
    try {
      const el = document.getElementById("__UNIVERSAL_DATA_FOR_REHYDRATION__");
      const it = JSON.parse(el.textContent).__DEFAULT_SCOPE__["webapp.video-detail"].itemInfo.itemStruct;
      return it && it.id === String(id) ? it : null;
    } catch {
      return null;
    }
  }

  // A TikTok item carries tens of KB the archive never uses (music, effect
  // stickers, every bitrate). Safari silently drops large extension
  // messages, so only what the core reads travels.
  function slimTikTok(it) {
    const v = it.video || {};
    const a = it.author || {};
    return {
      id: it.id,
      desc: it.desc,
      createTime: it.createTime,
      author: { uniqueId: a.uniqueId, nickname: a.nickname, avatarThumb: a.avatarThumb },
      video: { cover: v.cover, originCover: v.originCover, width: v.width, height: v.height, duration: v.duration },
      imagePost: it.imagePost && {
        images: (it.imagePost.images || []).map((img) => ({
          imageURL: { urlList: (img.imageURL && img.imageURL.urlList) || [] },
          imageWidth: img.imageWidth,
          imageHeight: img.imageHeight,
        })),
      },
      stats: it.stats,
    };
  }

  const slimList = (json) => ({ itemList: (json.itemList || []).map(slimTikTok) });

  function saveCached(kind, id) {
    const obj = seen.get(String(id)) || (kind === "x" ? null : pageItem(id));
    if (kind === "x") {
      obj ? post("x_tweet", { data: { tweetResult: { result: obj } } }) : post("x_url", String(id));
    } else {
      obj ? post("tiktok_item", { itemList: [slimTikTok(obj)] }) : post("tiktok_url", String(id));
    }
  }

  function onResponse(url, reqBody, text) {
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      return;
    }
    if (isX) {
      const op = (url.match(/\/graphql\/[^/]+\/([A-Za-z]+)/) || [])[1];
      if (!op) return;
      indexX(json);
      if (/^Bookmark(s|SearchTimeline|FolderTimeline)$/.test(op)) post("x_timeline", json);
      else if (op === "CreateBookmark") {
        const id = bodyVar(reqBody, "tweet_id");
        if (id) saveCached("x", id);
        else post("diag", { event: "skip", reason: "CreateBookmark: tweet_id okunamadı" });
      }
      return;
    }
    indexTikTok(json);
    if (/item_list/.test(url)) {
      const items = Array.isArray(json.itemList) ? json.itemList.length : 0;
      post("diag", { event: "api", path: new URL(url, location.href).pathname, items });
    }
    // TikTok's names are crossed: user/collect is "Favorites" (saved),
    // favorite is "Liked". Plus the user's named Collections.
    if (/\/api\/(user\/collect|favorite|collection)\/item_list/.test(url) && json.itemList && json.itemList.length) {
      if (onOwnProfile()) post("tiktok_list", slimList(json));
      else post("diag", { event: "skip", reason: "başkasının profili", path: location.pathname });
    }
    else if (/\/api\/item\/collect\//.test(url)) {
      const q = new URL(url, location.href).searchParams;
      if (q.get("type") === "1" && q.get("aweme_id")) saveCached("tiktok", q.get("aweme_id"));
    }
  }

  const interesting = (url) => (isX ? url.includes("/graphql/") : url.includes("/api/"));

  const origFetch = window.fetch;
  window.fetch = async function (input, init) {
    let reqCopy = null;
    try {
      if (input instanceof Request && !(init && init.body) && interesting(input.url)) reqCopy = input.clone();
    } catch {}
    const res = await origFetch.apply(this, arguments);
    try {
      const url = typeof input === "string" ? input : input instanceof Request ? input.url : String(input);
      if (interesting(url)) {
        // The request body (X sends the tweet id in it) is in `init`, or
        // inside a Request object; that one is read from a copy.
        const body =
          init && typeof init.body === "string"
            ? Promise.resolve(init.body)
            : input instanceof Request && reqCopy
              ? reqCopy.text().catch(() => null)
              : Promise.resolve(null);
        Promise.all([body, res.clone().text()]).then(([b, t]) => onResponse(url, b, t), () => {});
      }
    } catch {}
    return res;
  };

  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__wmUrl = String(url);
    return xhrOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const url = this.__wmUrl;
    if (url && interesting(url)) {
      this.addEventListener("load", () => {
        try {
          const t = this.responseType === "json" ? JSON.stringify(this.response) : this.responseType === "" || this.responseType === "text" ? this.responseText : null;
          if (t) onResponse(url, typeof body === "string" ? body : null, t);
        } catch {}
      });
    }
    return xhrSend.apply(this, arguments);
  };

  // TikTok only serves video files to its own pages, so the videos the
  // library still lacks are fetched here, with the user's session, and
  // handed over in chunks; each chunk waits for the core to confirm it.
  const CHUNK = 1536 * 1024;
  const acks = new Map();

  const waitAck = (key) =>
    new Promise((resolve) => {
      acks.set(key, resolve);
      setTimeout(() => acks.delete(key) && resolve(false), 60_000);
    });

  const base64 = (blob) =>
    new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(",")[1] || "");
      r.onerror = reject;
      r.readAsDataURL(blob);
    });

  async function sendVideos(ids) {
    for (const full of ids) {
      const id = full.replace(/^tiktok:/, "");
      const it = seen.get(id) || pageItem(id);
      const src = it && it.video && (it.video.playAddr || it.video.downloadAddr);
      if (!src) continue;
      try {
        const r = await origFetch(src, { credentials: "include" });
        if (!r.ok) continue;
        const blob = await r.blob();
        const type = r.headers.get("content-type") || "video/mp4";
        for (let seq = 0, off = 0; ; seq++, off += CHUNK) {
          const last = off + CHUNK >= blob.size;
          const key = `${full}#${seq}`;
          const acked = waitAck(key);
          const data = await base64(blob.slice(off, off + CHUNK));
          const chunk = { id: full, seq, data, last, content_type: type, offset: off, size: last ? blob.size : undefined };
          window.postMessage({ __wroopmark: "video_chunk", key, chunk }, location.origin);
          if (!(await acked) || last) break;
        }
      } catch {}
    }
  }

  // relay.js asks for the post on the current page ("save this page"), for
  // missing videos, and confirms chunks.
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data) return;
    const m = e.data;
    if (m.__wroopmark === "save_cached") saveCached(m.kind, m.id);
    else if (m.__wroopmark === "fetch_videos") sendVideos(m.ids);
    else if (m.__wroopmark === "chunk_ack" && acks.has(m.key)) {
      acks.get(m.key)(m.ok);
      acks.delete(m.key);
    }
  });
})();
