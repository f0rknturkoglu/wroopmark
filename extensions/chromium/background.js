// Talks to wroopmark natively, buffers captures from page hooks & auto-scroller,
// and backs the popup, context menu, and site extractors.
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

// Closes the port after a quiet spell, but never under a running request.
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

function log(line) {
  return call("log", { line: `${IS_SAFARI ? "safari" : "chrome"} ${line}` });
}

// --- Collected Queue Management (Manual import only) ------------------------

function defaultCollected() {
  return {
    x_payloads: [],
    x_ids: [],
    tiktok_payloads: [],
    tiktok_ids: [],
    ig_payloads: [],
    ig_codes: [],
    page_items: [],
    page_urls: [],
  };
}

async function getCollected() {
  const { collected } = await chrome.storage.session.get("collected");
  return collected || defaultCollected();
}

async function setCollected(collected) {
  await chrome.storage.session.set({ collected });
  await updateBadge(collected);
}

async function clearCollected() {
  const empty = defaultCollected();
  await setCollected(empty);
  return empty;
}

function getTotalCollectedCount(c) {
  return (c.x_ids?.length || 0) + (c.tiktok_ids?.length || 0) + (c.ig_codes?.length || 0) + (c.page_items?.length || 0);
}

async function updateBadge(collected) {
  const total = getTotalCollectedCount(collected);
  if (total > 0) {
    chrome.action.setBadgeBackgroundColor({ color: "#774aed" });
    chrome.action.setBadgeText({ text: String(total) });
  } else {
    chrome.action.setBadgeText({ text: "" });
  }
}

function extractTweetIds(v) {
  const ids = new Set();
  function walk(node) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) return node.forEach(walk);
    if (node.rest_id && (node.legacy || node.tweet)) ids.add(String(node.rest_id));
    for (const k in node) walk(node[k]);
  }
  walk(v);
  return Array.from(ids);
}

function extractTikTokIds(payload) {
  const ids = [];
  for (const it of payload?.itemList || []) {
    if (it && it.id) ids.push(String(it.id));
  }
  return ids;
}

// --- Buffering captures from hook.js & page scanner -------------------------

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

async function handleCapture({ kind, payload }, tabId) {
  const c = await getCollected();

  if (kind === "x_timeline" || kind === "x_tweet") {
    const ids = extractTweetIds(payload);
    let added = 0;
    for (const id of ids) {
      if (!c.x_ids.includes(id)) {
        c.x_ids.push(id);
        added++;
      }
    }
    c.x_payloads.push(payload);
    await setCollected(c);
    log(`X: ${ids.length} tweet görüldü (+${added} yeni, kuyrukta: ${c.x_ids.length})`);
    return;
  }

  if (kind === "tiktok_list" || kind === "tiktok_item") {
    const ids = extractTikTokIds(payload);
    let added = 0;
    for (const id of ids) {
      if (!c.tiktok_ids.includes(id)) {
        c.tiktok_ids.push(id);
        added++;
      }
    }
    c.tiktok_payloads.push(payload);
    await setCollected(c);
    log(`TikTok: ${ids.length} video görüldü (+${added} yeni, kuyrukta: ${c.tiktok_ids.length})`);
    return;
  }

  if (kind === "instagram_list") {
    c.ig_codes ||= [];
    c.ig_payloads ||= [];
    let added = 0;
    for (const m of payload?.items || []) {
      if (m?.code && !c.ig_codes.includes(m.code)) {
        c.ig_codes.push(m.code);
        added++;
      }
    }
    if (added) c.ig_payloads.push(payload);
    await setCollected(c);
    log(`Instagram: ${payload?.items?.length || 0} gönderi görüldü (+${added} yeni, kuyrukta: ${c.ig_codes.length})`);
    return;
  }

  if (kind === "x_url") {
    const url = `https://x.com/i/status/${payload}`;
    if (!c.page_urls.includes(url)) {
      c.page_urls.push(url);
      c.page_items.push({ url, platform: "x", text: "" });
      await setCollected(c);
    }
    return;
  }

  if (kind === "tiktok_url") {
    const url = `https://m.tiktok.com/v/${payload}.html`;
    if (!c.page_urls.includes(url)) {
      c.page_urls.push(url);
      c.page_items.push({ url, platform: "tiktok", text: "" });
      await setCollected(c);
    }
    return;
  }
}

async function addPageItemsToCollected(items) {
  const c = await getCollected();
  let added = 0;
  for (const it of items) {
    if (!it || !it.url) continue;
    if (!c.page_urls.includes(it.url)) {
      c.page_urls.push(it.url);
      c.page_items.push(it);
      added++;
    }
  }
  if (added > 0) {
    await setCollected(c);
  }
}

// User explicitly triggers transfer of all buffered items
async function importCollected() {
  const c = await getCollected();
  const totalItems = getTotalCollectedCount(c);
  if (totalItems === 0) {
    return { ok: true, data: { total: 0, new: 0, updated: 0, ids: [] } };
  }

  let totalNew = 0;
  let totalUpdated = 0;
  const importedIds = [];

  // 1. Import X payloads
  for (const payload of c.x_payloads) {
    const report = await call("import_x", { payload });
    if (report.ok) {
      totalNew += report.data?.new || 0;
      totalUpdated += report.data?.updated || 0;
      if (report.data?.ids) importedIds.push(...report.data.ids);
    }
  }

  // 2. Import TikTok payloads
  for (const payload of c.tiktok_payloads) {
    const report = await call("import_tiktok", { payload });
    if (report.ok) {
      totalNew += report.data?.new || 0;
      totalUpdated += report.data?.updated || 0;
      if (report.data?.ids) importedIds.push(...report.data.ids);
    }
  }

  // 3. Import Instagram payloads
  for (const payload of c.ig_payloads || []) {
    const report = await call("import_instagram", { payload });
    if (report.ok) {
      totalNew += report.data?.new || 0;
      totalUpdated += report.data?.updated || 0;
      if (report.data?.ids) importedIds.push(...report.data.ids);
    }
  }

  // 4. Import generic page items
  if (c.page_items.length > 0) {
    const report = await call("import_items", { items: c.page_items });
    if (report.ok) {
      totalNew += report.data?.new || 0;
      totalUpdated += report.data?.updated || 0;
      if (report.data?.ids) importedIds.push(...report.data.ids);
    }
  }

  // If TikTok items were imported, request missing videos
  if (c.tiktok_ids.length > 0) {
    chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
      if (tab?.id != null) fetchMissingVideos(tab.id, importedIds);
    });
  }

  // Reset collected queue
  await clearCollected();

  // Temporary success badge
  chrome.action.setBadgeBackgroundColor({ color: "#2e7d32" });
  chrome.action.setBadgeText({ text: "✓" });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);

  return {
    ok: true,
    data: {
      total: importedIds.length,
      new: totalNew,
      updated: totalUpdated,
      ids: importedIds,
    },
  };
}

// TikTok videos can only be downloaded by TikTok's own page; ask it to send
// the ones the library lacks (see sendVideos in hook.js).
async function fetchMissingVideos(tabId, ids) {
  const needed = await call("videos_needed", { ids });
  if (!needed.ok) return log(`videos_needed: HATA ${needed.error}`);
  if (needed.data.length) {
    log(`tiktok: ${needed.data.length} video sayfadan indirilecek`);
    chrome.tabs.sendMessage(tabId, { type: "fetch_videos", ids: needed.data }).catch((e) => log(`fetch_videos iletilemedi: ${e}`));
  }
}

// --- Universal Page Scroller (runs inside target tab) ------------------------

function pageScroller(enable) {
  const STATE_KEY = "__wm_scroller";

  if (!enable) {
    if (window[STATE_KEY]) {
      clearInterval(window[STATE_KEY].timer);
      window[STATE_KEY] = null;
    }
    return { active: false };
  }

  if (window[STATE_KEY]) {
    clearInterval(window[STATE_KEY].timer);
  }

  let lastHeight = document.scrollingElement ? document.scrollingElement.scrollHeight : document.body.scrollHeight;
  let idleCount = 0;
  const scannedUrls = new Set();

  function scanVisibleItems() {
    const host = location.hostname.replace(/^www\./, "");
    const items = [];

    if (host.includes("reddit.com")) {
      document.querySelectorAll("shreddit-post").forEach((post) => {
        const permalink = post.getAttribute("permalink") || post.getAttribute("content-href");
        if (permalink) {
          const absUrl = new URL(permalink, location.href).href;
          if (!scannedUrls.has(absUrl)) {
            scannedUrls.add(absUrl);
            items.push({
              url: absUrl,
              title: post.getAttribute("post-title") || "Reddit Gönderisi",
              author_handle: post.getAttribute("author") || null,
              author_name: post.getAttribute("author") ? `u/${post.getAttribute("author")}` : null,
              platform: "reddit",
              created_at: Math.floor(Date.now() / 1000),
            });
          }
        }
      });
    } else if (host.includes("youtube.com")) {
      document.querySelectorAll("ytd-rich-item-renderer, ytd-video-renderer, ytd-grid-video-renderer").forEach((card) => {
        const a = card.querySelector("a#video-title-link, a#video-title");
        if (a && a.href && (a.href.includes("/watch?v=") || a.href.includes("/shorts/"))) {
          const absUrl = new URL(a.href, location.href).href;
          if (!scannedUrls.has(absUrl)) {
            scannedUrls.add(absUrl);
            const channel = card.querySelector("#channel-name, ytd-channel-name")?.innerText?.trim();
            items.push({
              url: absUrl,
              title: a.innerText.trim() || a.title || "YouTube Videosu",
              author_handle: channel || null,
              author_name: channel || null,
              platform: "youtube",
              created_at: Math.floor(Date.now() / 1000),
            });
          }
        }
      });
    } else if (host === "news.ycombinator.com") {
      document.querySelectorAll("tr.athing").forEach((row) => {
        const titleA = row.querySelector(".titleline a");
        if (titleA && titleA.href) {
          const absUrl = new URL(titleA.href, location.href).href;
          if (!scannedUrls.has(absUrl)) {
            scannedUrls.add(absUrl);
            const subtext = row.nextElementSibling;
            const author = subtext?.querySelector(".hnuser")?.innerText?.trim() || null;
            items.push({
              url: absUrl,
              title: titleA.innerText.trim() || "HN Post",
              author_handle: author,
              author_name: author,
              platform: "hackernews",
              created_at: Math.floor(Date.now() / 1000),
            });
          }
        }
      });
    } else if (host === "github.com") {
      document.querySelectorAll("article.border, .repo-list-item, [data-testid='results-list'] li").forEach((el) => {
        const a = el.querySelector("a[href^='/'][data-hydro-click], a.v-align-middle");
        if (a && a.href) {
          const absUrl = new URL(a.href, location.href).href;
          if (!scannedUrls.has(absUrl)) {
            scannedUrls.add(absUrl);
            items.push({
              url: absUrl,
              title: a.innerText.trim() || "GitHub Repository",
              platform: "github",
              created_at: Math.floor(Date.now() / 1000),
            });
          }
        }
      });
    }

    if (items.length > 0) {
      chrome.runtime.sendMessage({ type: "page_scanned_items", items }).catch(() => {});
    }
  }

  scanVisibleItems();

  const timer = setInterval(() => {
    const el = document.scrollingElement || document.documentElement || document.body;
    const currentScroll = el.scrollTop + window.innerHeight;
    const scrollH = el.scrollHeight;

    if (scrollH === lastHeight && currentScroll >= scrollH - 120) {
      idleCount++;
      if (idleCount >= 10) {
        clearInterval(timer);
        window[STATE_KEY] = null;
        chrome.runtime.sendMessage({ type: "autoscroll_stopped", reason: "end_of_page" }).catch(() => {});
        return;
      }
    } else {
      idleCount = 0;
    }
    lastHeight = scrollH;

    // Smooth scroll down by 650px. User can freely scroll manually with wheel or trackpad!
    window.scrollBy({ top: 650, behavior: "smooth" });
    scanVisibleItems();
  }, 850);

  window[STATE_KEY] = { timer };
  return { active: true };
}

// --- Rich Multi-Site Page Capture (runs inside target tab) -------------------

function capturePage(selection) {
  const url = location.href;
  const host = location.hostname.replace(/^www\./, "");

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

  const cleanText = (el) => {
    if (!el) return "";
    const clone = el.cloneNode(true);
    clone.querySelectorAll("script, style, nav, noscript, svg, button, form, iframe, [aria-hidden='true']").forEach((e) => e.remove());
    return (clone.innerText || clone.textContent || "").trim();
  };

  // 1. Reddit
  if (host.includes("reddit.com") || host === "redd.it") {
    const postEl = document.querySelector("shreddit-post") || document.querySelector('[data-test-id="post-content"]');
    const title = postEl?.getAttribute("post-title") || document.querySelector("h1[slot='title']")?.innerText || document.querySelector("h1")?.innerText || meta("og:title") || document.title.replace(/\s*:\s*r\/.*$/, "");
    const subreddit = postEl?.getAttribute("subreddit-prefixed-name") || (location.pathname.match(/\/(r\/[^\/]+)/) || [])[1] || "";
    const author = postEl?.getAttribute("author") || document.querySelector("[data-testid='post_author_link']")?.innerText || (location.pathname.match(/\/user\/([^\/]+)/) || [])[1] || meta("author");
    const score = postEl?.getAttribute("score") || null;
    const commentCount = postEl?.getAttribute("comment-count") || null;
    const flair = postEl?.getAttribute("flair-text") || document.querySelector("[data-testid='post-flair']")?.innerText || null;

    const bodyEl = document.querySelector("div[slot='text-body']") || document.querySelector("div[id*='-post-rtjson-content']") || document.querySelector("[data-click-id='text']");
    const bodyText = cleanText(bodyEl) || (selection || "").trim();

    const media = [];
    const mediaImg = document.querySelector("shreddit-aspect-ratio img") || document.querySelector("shreddit-player")?.getAttribute("preview") || meta("og:image");
    if (mediaImg && abs(mediaImg)) media.push({ kind: "image", url: abs(mediaImg) });

    const links = [];
    const outLink = postEl?.getAttribute("content-href") || document.querySelector("a[data-testid='outbound-link']")?.href;
    if (outLink && abs(outLink) && !outLink.includes("reddit.com")) links.push(abs(outLink));

    const tags = [];
    if (subreddit) tags.push(subreddit.toLowerCase());
    if (flair) tags.push(flair.toLowerCase().replace(/\s+/g, "-"));

    const extraParts = [];
    if (score) extraParts.push(`Puan: ${score}`);
    if (commentCount) extraParts.push(`Yorum sayısı: ${commentCount}`);
    if (extraParts.length) extraParts.push("---");
    if (bodyText) extraParts.push(bodyText);

    return {
      url,
      title: title ? title.trim() : null,
      author_handle: author ? author.replace(/^u\//, "") : null,
      author_name: author ? `u/${author.replace(/^u\//, "")}` : null,
      text: bodyText || meta("og:description", "description") || "",
      extra: extraParts.join("\n").slice(0, 30000) || null,
      tags,
      links,
      media,
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 2. YouTube (saves metadata & thumbnail; does NOT auto-download the video file)
  if (host.includes("youtube.com") || host === "youtu.be") {
    const videoId = (location.search.match(/[?&]v=([^&]+)/) || [])[1] || (location.pathname.match(/\/shorts\/([^/?]+)/) || [])[1] || (host === "youtu.be" ? location.pathname.slice(1).split("/")[0] : null);
    const titleEl = document.querySelector("h1.ytd-watch-metadata yt-formatted-string") || document.querySelector("h1.title yt-formatted-string") || document.querySelector("h1");
    const title = titleEl ? titleEl.innerText.trim() : meta("og:title") || document.title.replace(/ - YouTube$/, "");

    const channelEl = document.querySelector("#channel-name a") || document.querySelector("ytd-channel-name a") || document.querySelector("#owner #channel-name");
    const channelName = channelEl ? channelEl.innerText.trim() : meta("author");
    const channelUrl = channelEl?.href || null;

    const descEl = document.querySelector("#description-inline-expander") || document.querySelector("#description yt-formatted-string") || document.querySelector("#description");
    const descText = descEl ? cleanText(descEl) : meta("og:description", "description") || "";

    const media = [];
    if (videoId) {
      media.push({ kind: "image", url: `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg` });
    } else if (meta("og:image")) {
      media.push({ kind: "image", url: abs(meta("og:image")) });
    }

    const tags = [];
    if (channelName) tags.push(channelName.toLowerCase().replace(/[^\w\s-]/g, "").replace(/\s+/g, "-"));
    if (location.pathname.includes("/shorts/")) tags.push("shorts");

    const links = [];
    if (channelUrl && abs(channelUrl)) links.push(abs(channelUrl));
    if (descEl) {
      descEl.querySelectorAll("a").forEach((a) => {
        const h = a.href;
        if (h && abs(h) && !h.includes("youtube.com/hashtag/")) links.push(abs(h));
      });
    }

    return {
      url,
      title: title || "YouTube Videosu",
      author_handle: channelName || null,
      author_name: channelName || null,
      text: (selection || "").trim() || descText.slice(0, 1000) || "",
      extra: descText.slice(0, 30000) || null,
      tags,
      links: [...new Set(links)],
      media,
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 3. Instagram
  if (host.includes("instagram.com")) {
    const authorEl = document.querySelector("header a") || document.querySelector("h2");
    const authorHandle = authorEl ? authorEl.innerText.trim() : (location.pathname.match(/^\/([^\/]+)/) || [])[1];

    const captionEl = document.querySelector("h1") || document.querySelector("span._aacl") || document.querySelector("article span");
    const caption = captionEl ? captionEl.innerText.trim() : meta("og:description", "description") || "";

    const media = [];
    document.querySelectorAll("article img").forEach((img) => {
      const src = img.currentSrc || img.src;
      if (src && abs(src) && !media.some((m) => m.url === src)) {
        media.push({ kind: "image", url: abs(src), width: img.naturalWidth || undefined, height: img.naturalHeight || undefined });
      }
    });
    if (!media.length && meta("og:image")) {
      media.push({ kind: "image", url: abs(meta("og:image")) });
    }

    const tags = ["instagram"];
    if (location.pathname.includes("/reel/")) tags.push("reels");

    return {
      url,
      title: caption ? caption.slice(0, 80) : `Instagram @${authorHandle || ""}`,
      author_handle: authorHandle || null,
      author_name: authorHandle ? `@${authorHandle}` : null,
      text: (selection || "").trim() || caption || "",
      extra: caption || null,
      tags,
      media,
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 4. GitHub
  if (host === "github.com") {
    const parts = location.pathname.split("/").filter(Boolean);
    const isRepo = parts.length >= 2;
    const owner = parts[0] || null;
    const repo = parts[1] || null;

    const descEl = document.querySelector("p.f4.my-3") || document.querySelector("[itemprop='description']");
    const descText = descEl ? descEl.innerText.trim() : meta("og:description", "description") || "";

    const langEl = document.querySelector("span[itemprop='programmingLanguage']");
    const lang = langEl ? langEl.innerText.trim() : null;

    const starsEl = document.querySelector("#repo-stars-counter-star") || document.querySelector(".Counter[data-view-component]");
    const stars = starsEl ? starsEl.innerText.trim() : null;

    const readmeEl = document.querySelector("#readme article");
    const readmeSnippet = readmeEl ? cleanText(readmeEl).slice(0, 25000) : "";

    const tags = ["github"];
    if (lang) tags.push(lang.toLowerCase());
    document.querySelectorAll("a.topic-tag").forEach((t) => tags.push(t.innerText.trim().toLowerCase()));

    const title = isRepo ? `${owner}/${repo}` : document.title.replace(/ · GitHub$/, "");

    return {
      url,
      title,
      author_handle: owner,
      author_name: owner,
      text: (selection || "").trim() || descText || "",
      extra: [descText, stars ? `Yıldızlar: ${stars}` : null, "--- README ---", readmeSnippet].filter(Boolean).join("\n\n").slice(0, 30000),
      tags: [...new Set(tags)],
      media: meta("og:image") ? [{ kind: "image", url: abs(meta("og:image")) }] : [],
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 5. Hacker News & Lobsters
  if (host === "news.ycombinator.com" || host === "lobste.rs") {
    const titleEl = document.querySelector(".titleline a") || document.querySelector(".title a") || document.querySelector("h1");
    const title = titleEl ? titleEl.innerText.trim() : document.title;
    const targetUrl = titleEl?.href || url;

    const authorEl = document.querySelector(".hnuser") || document.querySelector(".u-author");
    const author = authorEl ? authorEl.innerText.trim() : null;

    const scoreEl = document.querySelector(".score");
    const score = scoreEl ? scoreEl.innerText.trim() : null;

    const links = [];
    if (targetUrl && abs(targetUrl) && abs(targetUrl) !== url) links.push(abs(targetUrl));

    const comments = [];
    document.querySelectorAll(".commtext, .comment_text").forEach((c, idx) => {
      if (idx < 5) comments.push(cleanText(c));
    });

    const tags = [host.includes("ycombinator") ? "hackernews" : "lobsters"];

    return {
      url,
      title,
      author_handle: author,
      author_name: author,
      text: (selection || "").trim() || (score ? `[${score}] ${title}` : title),
      extra: comments.length ? `En iyi yorumlar:\n\n${comments.join("\n\n---\n\n")}` : null,
      tags,
      links,
      media: [],
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 6. arXiv
  if (host === "arxiv.org") {
    const titleEl = document.querySelector("h1.title");
    const title = titleEl ? titleEl.innerText.replace(/^Title:\s*/i, "").trim() : document.title;

    const authorsEl = document.querySelector(".authors");
    const authorsText = authorsEl ? authorsEl.innerText.replace(/^Authors:\s*/i, "").trim() : null;

    const abstractEl = document.querySelector("blockquote.abstract");
    const abstractText = abstractEl ? abstractEl.innerText.replace(/^Abstract:\s*/i, "").trim() : "";

    const subjectsEl = document.querySelector(".subjects") || document.querySelector("td.tablecell.subjects");
    const subjectsText = subjectsEl ? subjectsEl.innerText.trim() : "";

    const arxivId = (location.pathname.match(/\/(?:abs|pdf)\/([0-9.]+)/) || [])[1];
    const pdfUrl = arxivId ? `https://arxiv.org/pdf/${arxivId}.pdf` : null;

    const tags = ["arxiv"];
    if (subjectsText) {
      const cats = subjectsText.match(/\(([a-zA-Z\-]+(?:\.[a-zA-Z\-]+)?)\)/g);
      if (cats) cats.forEach((c) => tags.push(c.replace(/[()]/g, "").toLowerCase()));
    }

    const links = [];
    if (pdfUrl) links.push(pdfUrl);

    return {
      url,
      title: title || document.title,
      author_name: authorsText,
      text: (selection || "").trim() || abstractText.slice(0, 1000) || "",
      extra: [`Yazarlar: ${authorsText || "Bilinmiyor"}`, `Konular: ${subjectsText}`, `PDF: ${pdfUrl || ""}`, "--- ÖZET ---", abstractText].join("\n\n").slice(0, 30000),
      tags: [...new Set(tags)],
      links,
      media: [],
      created_at: Math.floor(Date.now() / 1000),
    };
  }

  // 7. General Reader Mode (Articles / Blogs / Substack / Medium)
  const articleEl = document.querySelector("article") || document.querySelector("[role='article']") || document.querySelector(".post-content") || document.querySelector(".entry-content") || document.querySelector("main") || document.body;
  const articleTitle = document.querySelector("article h1, h1.post-title, h1")?.innerText?.trim() || meta("og:title", "twitter:title") || document.title;
  const author = meta("author", "article:author") || document.querySelector("a[rel='author'], .author-name, .byline")?.innerText?.trim();
  const publishedStr = meta("article:published_time") || document.querySelector("time")?.getAttribute("datetime");
  const published = publishedStr ? Date.parse(publishedStr) : null;

  const media = [];
  const ogImg = meta("og:image", "twitter:image");
  if (ogImg && abs(ogImg)) media.push({ kind: "image", url: abs(ogImg) });

  for (const img of (articleEl || document.body).querySelectorAll("img")) {
    const src = img.currentSrc || img.src;
    if (img.naturalWidth < 300 || img.naturalHeight < 200 || !src || !src.startsWith("http")) continue;
    if (media.some((m) => m.url === src) || media.length >= 6) continue;
    media.push({ kind: "image", url: src, width: img.naturalWidth, height: img.naturalHeight, alt: img.alt || undefined });
  }

  const cleanBody = cleanText(articleEl).slice(0, 30000);
  const textPreview = (selection || "").trim() || meta("og:description", "twitter:description", "description") || cleanBody.slice(0, 500);

  const tags = [];
  if (host.includes("substack.com")) tags.push("substack");
  else if (host.includes("medium.com")) tags.push("medium");

  return {
    url,
    title: articleTitle || null,
    text: textPreview,
    extra: cleanBody || null,
    author_name: author || null,
    created_at: Number.isFinite(published) ? Math.floor(published / 1000) : null,
    media,
    tags,
  };
}

// --- Saving the active tab ---------------------------------------------------

async function saveTab(tab, { tags = [], note = null, selection = null, folder_id = null } = {}) {
  let item;
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: capturePage, args: [selection] });
    item = res.result;
  } catch {
    const report = await call("add_url", { url: tab.url, tags, note, folder_id });
    if (report.ok) savedNow(tab);
    return report.ok ? { ok: true, data: { id: report.data.id } } : report;
  }

  item.note = note;
  const allTags = [...new Set([...(item.tags || []), ...tags])];
  const report = await call("import_items", { items: [item], tags: allTags, folder_id });
  if (report.ok && report.data?.ids?.length) savedNow(tab);
  return report.ok ? { ok: true, data: { id: report.data.ids[0] } } : report;
}

// --- "Already saved" badge ----------------------------------------------------
// Each page's own badge shows ✓ when the library has it. Lookups go to the
// local library only, and are remembered for a couple of minutes.

const LOOKUP_TTL = 120_000;
const lookups = new Map(); // url -> { at, data }

function setTabBadge(tabId, saved) {
  try {
    if (saved) {
      chrome.action.setBadgeBackgroundColor({ tabId, color: "#2e7d32" });
      chrome.action.setBadgeText({ tabId, text: "✓" });
      const where = saved.folder ? ` · ${saved.folder}` : "";
      chrome.action.setTitle({ tabId, title: `wroopmark: bu sayfa arşivde${where}` });
    } else {
      // null falls back to the global badge (the collected count).
      chrome.action.setBadgeText({ tabId, text: null });
      chrome.action.setTitle({ tabId, title: "wroopmark" });
    }
  } catch {}
}

async function refreshSavedBadge(tabId, url) {
  if (tabId == null || !url || !/^https?:/.test(url)) return;
  let hit = lookups.get(url);
  if (!hit || Date.now() - hit.at > LOOKUP_TTL) {
    const r = await call("lookup_url", { url });
    if (!r.ok) return;
    hit = { at: Date.now(), data: r.data };
    lookups.set(url, hit);
    if (lookups.size > 300) lookups.delete(lookups.keys().next().value);
  }
  setTabBadge(tabId, hit.data);
}

function savedNow(tab) {
  if (!tab) return;
  lookups.delete(tab.url);
  refreshSavedBadge(tab.id, tab.url);
}

chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.status === "complete" || info.url) refreshSavedBadge(tabId, tab.url);
});
chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId).then((tab) => refreshSavedBadge(tabId, tab.url), () => {});
});

// --- Reddit: the whole saved list, read with the user's own session ---------

// Runs inside a reddit.com tab.
async function redditSavedPages(maxPages) {
  const me = await fetch("/api/me.json", { credentials: "include" })
    .then((r) => r.json())
    .catch(() => null);
  const name = me && me.data && me.data.name;
  if (!name) return { error: "Reddit'e giriş yapılmamış görünüyor" };
  const pages = [];
  let after = null;
  for (let i = 0; i < maxPages; i++) {
    const q = `limit=100&raw_json=1${after ? `&after=${after}` : ""}`;
    const r = await fetch(`/user/${encodeURIComponent(name)}/saved.json?${q}`, { credentials: "include" });
    if (!r.ok) break;
    const page = await r.json();
    pages.push(page);
    after = page && page.data && page.data.after;
    if (!after) break;
    // Unhurried, like the rest of the archive.
    await new Promise((ok) => setTimeout(ok, 800));
  }
  return { name, pages };
}

async function importReddit() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !/^https:\/\/([a-z0-9-]+\.)?reddit\.com\//.test(tab.url || "")) {
    return { ok: false, error: "Önce reddit.com'da bir sekme aç" };
  }
  let res;
  try {
    [{ result: res }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: redditSavedPages, args: [10] });
  } catch (e) {
    return { ok: false, error: `Reddit okunamadı: ${e}` };
  }
  if (!res || res.error) return { ok: false, error: res?.error || "Reddit okunamadı" };
  let total = 0;
  let fresh = 0;
  for (const payload of res.pages) {
    const r = await call("import_reddit", { payload });
    if (!r.ok) return { ok: false, error: r.error };
    total += r.data.ids.length;
    fresh += r.data.new;
  }
  log(`reddit: u/${res.name} ${res.pages.length} sayfa, ${total} kayıt (${fresh} yeni)`);
  savedNow(tab);
  return { ok: true, data: { name: res.name, total, new: fresh } };
}

// --- Context Menus -----------------------------------------------------------

const MENU_CONTEXTS = ["page", "selection", "link", "image"];

// "Save" plus "Save to folder ›" with the library's folders. Rebuilt when
// the browser starts and whenever the popup has read the folders.
let menuBuild = Promise.resolve();
function buildMenus() {
  menuBuild = menuBuild.then(async () => {
    await chrome.contextMenus.removeAll();
    chrome.contextMenus.create({ id: "save", title: "wroopmark'a kaydet", contexts: MENU_CONTEXTS });
    const r = await call("folders");
    if (!r.ok || !r.data.length) return;
    chrome.contextMenus.create({ id: "save-folder", title: "wroopmark'ta klasöre kaydet", contexts: MENU_CONTEXTS });
    for (const f of r.data.slice(0, 40)) {
      chrome.contextMenus.create({ id: `folder:${f.id}`, parentId: "save-folder", title: f.name.replaceAll("/", " › "), contexts: MENU_CONTEXTS });
    }
  }).catch(() => {});
  return menuBuild;
}

chrome.runtime.onInstalled.addListener(buildMenus);
chrome.runtime.onStartup.addListener(buildMenus);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const m = String(info.menuItemId).match(/^folder:(\d+)$/);
  const folder_id = m ? Number(m[1]) : null;
  if (info.mediaType === "image" && info.srcUrl) {
    const item = { url: info.srcUrl, title: tab?.title ?? null, text: "", media: [{ kind: "image", url: info.srcUrl }], links: [info.pageUrl] };
    await call("import_items", { items: [item], folder_id });
  } else if (info.linkUrl) {
    await call("add_url", { url: info.linkUrl, folder_id });
  } else if (tab) {
    await saveTab(tab, { selection: info.selectionText ?? null, folder_id });
  }
});

// ⌥⇧S: save the page in front, into the folder last picked in the popup.
chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "save-page") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return;
  const { lastFolder } = await chrome.storage.local.get("lastFolder");
  const r = await saveTab(tab, { folder_id: lastFolder ? Number(lastFolder) : null });
  if (!r.ok) {
    log(`kısayol: kaydedilemedi: ${r.error}`);
    chrome.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#c62828" });
    chrome.action.setBadgeText({ tabId: tab.id, text: "!" });
  }
});

// --- Messages from popup, relay.js & page scripts ----------------------------

const EXT_ORIGIN = chrome.runtime.getURL("");
const fromExtensionPage = (sender) => !sender.tab && (!sender.url || sender.url.startsWith(EXT_ORIGIN));
const POPUP_ONLY = new Set([
  "call",
  "save_tab",
  "import_reddit",
  "folders_changed",
  "toggle_autoscroll",
  "get_scroll_status",
  "get_collected",
  "import_collected",
  "clear_collected",
]);

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

    case "post_page":
      if (sender.tab?.id != null) fetchMissingVideos(sender.tab.id, [msg.id]);
      return false;

    case "page_scanned_items":
      if (Array.isArray(msg.items)) {
        addPageItemsToCollected(msg.items);
      }
      return false;

    case "autoscroll_stopped":
      chrome.storage.session.set({ scrollingTabId: null });
      return false;

    case "call":
      call(msg.cmd, msg.args).then(reply);
      return true;

    case "save_tab":
      chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
        if (!tab) return reply({ ok: false, error: "Aktif sekme bulunamadı" });
        saveTab(tab, msg).then(reply);
      });
      return true;

    case "toggle_autoscroll":
      chrome.tabs.query({ active: true, currentWindow: true }).then(async ([tab]) => {
        if (!tab || !tab.id) return reply({ ok: false, error: "Aktif sekme bulunamadı" });
        const { scrollingTabId } = await chrome.storage.session.get("scrollingTabId");
        const isRunning = scrollingTabId === tab.id;

        if (isRunning) {
          await chrome.scripting.executeScript({
            target: { tabId: tab.id },
            func: pageScroller,
            args: [false],
          }).catch(() => {});
          await chrome.storage.session.set({ scrollingTabId: null });
          reply({ ok: true, active: false });
        } else {
          if (scrollingTabId) {
            await chrome.scripting.executeScript({
              target: { tabId: scrollingTabId },
              func: pageScroller,
              args: [false],
            }).catch(() => {});
          }
          await chrome.scripting.executeScript({
            target: { tabId: tab.id },
            func: pageScroller,
            args: [true],
          }).catch(() => {});
          await chrome.storage.session.set({ scrollingTabId: tab.id });
          reply({ ok: true, active: true });
        }
      });
      return true;

    case "get_scroll_status":
      chrome.tabs.query({ active: true, currentWindow: true }).then(async ([tab]) => {
        const { scrollingTabId } = await chrome.storage.session.get("scrollingTabId");
        reply({ ok: true, active: !!(tab && tab.id === scrollingTabId) });
      });
      return true;

    case "get_collected":
      getCollected().then((c) => {
        reply({
          ok: true,
          data: {
            total: getTotalCollectedCount(c),
            x: c.x_ids?.length || 0,
            tiktok: c.tiktok_ids?.length || 0,
            instagram: c.ig_codes?.length || 0,
            pages: c.page_items?.length || 0,
          },
        });
      });
      return true;

    case "import_collected":
      importCollected().then(reply);
      return true;

    case "import_reddit":
      importReddit().then(reply);
      return true;

    case "folders_changed":
      buildMenus();
      return false;

    case "clear_collected":
      clearCollected().then(() => reply({ ok: true }));
      return true;
  }
  return false;
});
