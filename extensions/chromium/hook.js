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
// Instagram: the Saved page's lists (REST feed/saved or its GraphQL
//         successor) are forwarded whole; a post seen anywhere is saved the
//         moment you press its bookmark (web/save).
// X threads: a conversation page (TweetDetail) goes to the core, which
//         adds the author's own follow-ups to the post if it is saved.
// YouTube: Watch Later and Liked videos (playlist page: ytInitialData and
//         its browse continuations), slimmed to what an item needs.
// Bluesky: saved posts (app.bsky.bookmark.getBookmarks) and your likes.
(() => {
  if (window.__wroopmarkHooked) return;
  window.__wroopmarkHooked = true;
  // Tells relay.js (isolated world) the hook is in; see its fallback.
  document.documentElement.dataset.wroopmarkHooked = "1";

  const host = location.hostname.replace(/^www\./, "");
  const isX = host === "x.com" || host === "twitter.com";
  const isIG = host === "instagram.com" || host.endsWith(".instagram.com");
  const isYT = host === "youtube.com" || host === "m.youtube.com";
  const isBsky = host === "bsky.app";
  const isThreads = host === "threads.net" || host === "threads.com";
  const isPinterest = host === "pinterest.com" || host.endsWith(".pinterest.com");
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
    if (isX || isIG || isYT || isBsky || isThreads || me) return me;
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
  if (!isX && !isIG && !isYT && !isBsky && !isThreads && !isPinterest && !me) {
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

  // Instagram media objects, wherever a response carries them.
  const isIGMedia = (v) => typeof v.code === "string" && "taken_at" in v && (v.image_versions2 || v.carousel_media || v.video_versions);

  function indexIG(v, found) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach((x) => indexIG(x, found));
    if (isIGMedia(v)) {
      const slim = slimIG(v);
      if (v.pk != null) remember(String(v.pk), slim);
      if (v.id != null) remember(String(v.id).split("_")[0], slim);
      if (found) found.push(slim);
      return;
    }
    for (const k in v) indexIG(v[k], found);
  }

  function indexBsky(v) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach(indexBsky);
    if (typeof v.uri === "string" && v.uri.startsWith("at://") && v.record && v.author) {
      remember(v.uri, v);
    }
    for (const k in v) if (k !== "reply" && k !== "parent" && k !== "root") indexBsky(v[k]);
  }

  const isThreadsPost = (v) =>
    v &&
    typeof v.code === "string" &&
    (v.user || v.caption !== undefined || "taken_at" in v) &&
    (v.text_post_app_info || v.caption !== undefined || v.image_versions2 || v.video_versions);

  function indexThreads(v, found) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach((x) => indexThreads(x, found));
    if (isThreadsPost(v)) {
      const u = v.user || {};
      const handle = u.username || null;
      const url = handle ? `https://threads.com/@${handle}/post/${v.code}` : `https://threads.com/t/${v.code}`;
      const media = [];
      const parts = Array.isArray(v.carousel_media) && v.carousel_media.length ? v.carousel_media : [v];
      for (const p of parts) {
        const c = (p.image_versions2 && p.image_versions2.candidates) || [];
        const best = c.reduce((a, b) => ((b.width || 0) > ((a && a.width) || 0) ? b : a), null);
        const vid = (p.video_versions || [])[0];
        if (vid?.url) {
          media.push({ kind: "video", url: vid.url, thumb_url: best?.url || null, width: vid.width || best?.width || null, height: vid.height || best?.height || null });
        } else if (best?.url) {
          media.push({ kind: "image", url: best.url, width: best.width || null, height: best.height || null, alt: p.accessibility_caption || null });
        }
      }
      const item = {
        url,
        platform: "threads",
        author_handle: handle,
        author_name: u.full_name || null,
        author_avatar: u.profile_pic_url || null,
        text: (v.caption && v.caption.text) || "",
        created_at: typeof v.taken_at === "number" ? v.taken_at : null,
        media,
      };
      if (v.pk != null) remember(String(v.pk), item);
      if (v.code) remember(String(v.code), item);
      if (found && handle) found.push(item);
      return;
    }
    for (const k in v) indexThreads(v[k], found);
  }

  function indexPinterest(v, found, outSeen) {
    if (!v || typeof v !== "object") return;
    if (Array.isArray(v)) return v.forEach((x) => indexPinterest(x, found, outSeen));
    if (typeof v.id === "string" && /^\d{6,}$/.test(v.id) && (v.images?.orig?.url || v.videos?.video_list)) {
      if (!outSeen.has(v.id)) {
        outSeen.add(v.id);
        const media = [];
        const imgUrl = v.images?.orig?.url || v.images?.["736x"]?.url;
        const vidList = v.videos?.video_list;
        const vid = vidList ? vidList.V_720P || Object.values(vidList).find((x) => x?.url && !String(x.url).endsWith(".m3u8")) : null;
        if (vid?.url) {
          media.push({ kind: "video", url: vid.url, thumb_url: imgUrl || null, width: vid.width || null, height: vid.height || null });
        } else if (imgUrl) {
          media.push({ kind: "image", url: imgUrl, width: v.images?.orig?.width || null, height: v.images?.orig?.height || null });
        }
        if (media.length) {
          const pinner = v.pinner || v.native_creator || {};
          const title = v.grid_title || v.title || null;
          const desc = (v.description || "").trim();
          found.push({
            url: `https://www.pinterest.com/pin/${v.id}/`,
            platform: "pinterest",
            title,
            text: desc || title || "",
            author_handle: pinner.username || null,
            author_name: pinner.full_name || pinner.username || null,
            links: v.link ? [v.link] : [],
            media,
          });
        }
      }
      return;
    }
    for (const k in v) indexPinterest(v[k], found, outSeen);
  }

  // Only what the core reads: one picture size, one video file.
  function slimIGPart(m) {
    const c = (m.image_versions2 && m.image_versions2.candidates) || [];
    const best = c.reduce((a, b) => ((b.width || 0) > ((a && a.width) || 0) ? b : a), null);
    const v = (m.video_versions || [])[0];
    return {
      image_versions2: best ? { candidates: [{ url: best.url, width: best.width, height: best.height }] } : undefined,
      video_versions: v ? [{ url: v.url, width: v.width, height: v.height }] : undefined,
      accessibility_caption: m.accessibility_caption || undefined,
    };
  }

  function slimIG(m) {
    const u = m.user || m.owner || {};
    return {
      ...slimIGPart(m),
      code: m.code,
      pk: m.pk,
      taken_at: m.taken_at,
      product_type: m.product_type,
      caption: m.caption && m.caption.text ? { text: m.caption.text } : null,
      user: { username: u.username, full_name: u.full_name, profile_pic_url: u.profile_pic_url },
      carousel_media: Array.isArray(m.carousel_media) ? m.carousel_media.map(slimIGPart) : undefined,
    };
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

  // YouTube: only your own lists, by their fixed ids.
  const YT_LISTS = { WL: "youtube/sonra-izle", LL: "youtube/begenilenler" };
  const ytList = () => (location.pathname === "/playlist" ? new URLSearchParams(location.search).get("list") : null);
  function slimYT(v, out = []) {
    if (!v || typeof v !== "object") return out;
    if (Array.isArray(v)) {
      v.forEach((c) => slimYT(c, out));
      return out;
    }
    const r = v.playlistVideoRenderer;
    if (r && r.videoId) {
      const text = (t) => (t && (t.simpleText || (t.runs || []).map((x) => x.text).join(""))) || "";
      const by = r.shortBylineText || {};
      const thumbs = (r.thumbnail && r.thumbnail.thumbnails) || [];
      out.push({
        videoId: r.videoId,
        title: text(r.title),
        channel: text(by),
        handle: ((((by.runs || [])[0] || {}).navigationEndpoint || {}).browseEndpoint || {}).canonicalBaseUrl || "",
        thumb: thumbs.length ? String(thumbs[thumbs.length - 1].url || "").split("?")[0] : "",
      });
      return out;
    }
    for (const k in v) slimYT(v[k], out);
    return out;
  }
  function sendYT(data) {
    const list = ytList();
    const tag = list && YT_LISTS[list];
    if (!tag) return;
    const items = slimYT(data);
    if (items.length) post("youtube_list", { tag, items });
  }
  if (isYT) {
    // The first page of a list is in the HTML; the rest comes from browse.
    const initial = () => window.ytInitialData && sendYT(window.ytInitialData);
    document.addEventListener("DOMContentLoaded", () => setTimeout(initial, 500));
    document.addEventListener("yt-navigate-finish", (e) => {
      const d = e && e.detail && e.detail.response && e.detail.response.response;
      d ? sendYT(d) : setTimeout(initial, 500);
    });
  }

  function onResponse(url, reqBody, text) {
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      return;
    }
    if (isYT) {
      if (url.includes("/youtubei/v1/browse")) sendYT(json);
      return;
    }
    if (isBsky) {
      indexBsky(json);
      if (url.includes("app.bsky.bookmark.createBookmark")) {
        let uri = null;
        try {
          const b = JSON.parse(reqBody);
          uri = b.uri || b.subject?.uri;
        } catch {}
        const obj = uri && seen.get(uri);
        if (obj) post("bluesky_list", { tag: "bluesky/kaydedilenler", payload: { bookmarks: [{ item: obj }] } });
        else post("diag", { event: "skip", reason: "Bluesky: yer imine eklenen gönderi önbellekte yok", uri });
        return;
      }
      if (url.includes("app.bsky.bookmark.getBookmarks") || url.includes("app.bsky.feed.getActorLikes")) {
        const tag = url.includes("app.bsky.bookmark.getBookmarks") ? "bluesky/kaydedilenler" : "bluesky/begenilenler";
        const n = (json.bookmarks || json.feed || []).length;
        if (n) post("bluesky_list", { tag, payload: json });
      }
      return;
    }
    if (isThreads) {
      const found = [];
      indexThreads(json, found);
      // Only on the saved / liked pages: every post's JSON carries a
      // `has_liked` field, so the response text says nothing about the page.
      const path = location.pathname.replace(/\/+$/, "");
      const savedPage = path === "/saved" || path === "/liked";
      if (savedPage && found.length) {
        const tag = path === "/liked" ? "threads/begenilenler" : "threads/kaydedilenler";
        post("threads_list", { tag, items: found });
      }
      return;
    }
    if (isPinterest) {
      const found = [];
      indexPinterest(json, found, new Set());
      if (found.length) {
        const parts = location.pathname.split("/").filter(Boolean);
        const board = parts.length >= 2 && parts[0] !== "pin" ? parts[1].replace(/-/g, " ") : null;
        const tag = board ? `pinterest/${board}` : "pinterest/panolar";
        post("pinterest_list", { tag, items: found });
      }
      return;
    }
    if (isIG) {
      const found = [];
      indexIG(json, found);
      const saved = /\/api\/v1\/feed\/saved\//.test(url) || (url.includes("/graphql") && text.includes("xdt_api__v1__feed__saved"));
      if (saved && found.length) post("instagram_list", { items: found });
      const m = url.match(/\/web\/save\/(\d+)\/save\//);
      if (m) {
        const obj = seen.get(m[1]);
        if (obj) post("instagram_list", { items: [obj] });
        else post("diag", { event: "skip", reason: "instagram: kaydedilen gönderi sayfada görülmedi", id: m[1] });
      }
      return;
    }
    if (isX) {
      const op = (url.match(/\/graphql\/[^/]+\/([A-Za-z]+)/) || [])[1];
      if (!op) return;
      indexX(json);
      if (/^Bookmark(s|SearchTimeline|FolderTimeline)$/.test(op)) post("x_timeline", json);
      else if (op === "TweetDetail") post("x_thread", json);
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

  const interesting = (url) =>
    isX
      ? url.includes("/graphql/")
      : isIG
        ? url.includes("/api/v1/") || url.includes("/graphql")
        : isYT
          ? url.includes("/youtubei/v1/browse")
          : isBsky
            ? url.includes("/xrpc/app.bsky.")
            : isThreads
              ? url.includes("/graphql") || url.includes("/api/v1/")
              : isPinterest
                ? url.includes("/resource/")
                : url.includes("/api/");

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
  // Safari silently drops large extension messages, so chunks stay small.
  const CHUNK = 96 * 1024;
  const acks = new Map();
  const videoDiag = (id, info) => post("diag", { event: "video", id, ...info });

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

  // Every address the item offers for its video, best first.
  function videoSources(it) {
    const v = (it && it.video) || {};
    const out = [v.playAddr, v.downloadAddr];
    for (const b of v.bitrateInfo || []) out.push(...((b.PlayAddr && b.PlayAddr.UrlList) || []));
    return [...new Set(out.filter((u) => typeof u === "string" && u.startsWith("http")))];
  }

  async function sendVideo(full) {
    const id = full.replace(/^tiktok:/, "");
    const sources = videoSources(seen.get(id) || pageItem(id));
    if (!sources.length) return videoDiag(id, { error: "video adresi yok (sayfada görünmedi)" });
    let r = null;
    for (const src of sources) {
      try {
        r = await origFetch(src, { credentials: "include" });
        if (r.ok) break;
      } catch (e) {
        r = { ok: false, status: String(e) };
      }
    }
    if (!r || !r.ok) return videoDiag(id, { error: `indirilemedi: ${r && r.status}` });
    const blob = await r.blob();
    const type = r.headers.get("content-type") || "video/mp4";
    for (let seq = 0, off = 0; ; seq++, off += CHUNK) {
      const last = off + CHUNK >= blob.size;
      const key = `${full}#${seq}`;
      const acked = waitAck(key);
      const data = await base64(blob.slice(off, off + CHUNK));
      const chunk = { id: full, seq, data, last, content_type: type, offset: off, size: last ? blob.size : undefined };
      window.postMessage({ __wroopmark: "video_chunk", key, chunk }, location.origin);
      if (!(await acked)) return videoDiag(id, { error: `parça ${seq} kaydedilemedi`, kb: Math.round(blob.size / 1024) });
      if (last) return videoDiag(id, { ok: true, kb: Math.round(blob.size / 1024) });
    }
  }

  // One video at a time: list pages arrive fast, and two uploads of the
  // same video must not interleave.
  let videoQueue = Promise.resolve();
  const queued = new Set();
  function sendVideos(ids) {
    for (const full of ids) {
      if (queued.has(full)) continue;
      queued.add(full);
      videoQueue = videoQueue
        .then(() => sendVideo(full))
        .catch((e) => videoDiag(full, { error: String(e) }))
        .finally(() => queued.delete(full));
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
