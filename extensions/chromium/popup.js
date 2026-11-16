const $ = (id) => document.getElementById(id);
const send = (msg) => chrome.runtime.sendMessage(msg);
const call = (cmd, args = {}) => send({ type: "call", cmd, args });
const sessionStore = chrome.storage?.session || chrome.storage.local;
// Turkish for Turkish browsers, English for everyone else.
const TR = (navigator.language || "en").toLowerCase().startsWith("tr");
const t = (tr, en) => (TR ? tr : en);
const fmt = new Intl.NumberFormat(TR ? "tr-TR" : undefined);

// The page's fixed words: data-en / data-en-placeholder / data-en-title.
if (!TR) {
  document.documentElement.lang = "en";
  for (const el of document.querySelectorAll("[data-en]")) el.textContent = el.dataset.en;
  for (const el of document.querySelectorAll("[data-en-placeholder]")) el.placeholder = el.dataset.enPlaceholder;
  for (const el of document.querySelectorAll("[data-en-title]")) el.title = el.dataset.enTitle;
}

const PLATFORM_NAMES = {
  x: "X",
  tiktok: "TikTok",
  reddit: "Reddit",
  youtube: "YouTube",
  instagram: "Instagram",
  bluesky: "Bluesky",
  threads: "Threads",
  github: "GitHub",
  hackernews: "Hacker News",
  arxiv: "arXiv",
  pinterest: "Pinterest",
  facebook: "Facebook",
  web: "Web",
};

function setMsg(el, text, type = "normal") {
  el.textContent = text;
  el.classList.remove("err", "ok");
  if (type === "err") el.classList.add("err");
  if (type === "ok") el.classList.add("ok");
}

async function refreshStatus() {
  const r = await call("stats");
  if (!r.ok) {
    $("status").textContent = t("bağlı değil", "not connected");
    setMsg($("saveMsg"), t(`wroopmark kütüphanesine ulaşılamadı (${r.error})`, `Couldn't reach the wroopmark library (${r.error})`), "err");
    return false;
  }
  const s = r.data;
  $("status").textContent = t(`${fmt.format(s.items)} kayıt · ${fmt.format(s.tags)} etiket`, `${fmt.format(s.items)} items · ${fmt.format(s.tags)} tags`);
  const tags = await call("tags");
  if (tags.ok) {
    $("taglist").innerHTML = tags.data.map((t) => `<option value="${t.name.replace(/"/g, "&quot;")}">`).join("");
  }
  await loadFolders();
  return true;
}

// --- Folders and "already saved" -------------------------------------------

const LAST_FOLDER = "lastFolder";

async function loadFolders() {
  const r = await call("folders");
  if (!r.ok) return;
  const sel = $("folder");
  sel.replaceChildren(new Option(t("Klasörsüz", "No folder"), ""));
  for (const f of r.data) sel.append(new Option(f.name.replaceAll("/", " › "), String(f.id)));
  const { [LAST_FOLDER]: last } = await chrome.storage.local.get(LAST_FOLDER);
  if (last && r.data.some((f) => String(f.id) === last)) sel.value = last;
  // Keeps the right-click menu's folder list current.
  send({ type: "folders_changed" });
}

$("folder").addEventListener("change", () => chrome.storage.local.set({ [LAST_FOLDER]: $("folder").value }));

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function showSavedHere() {
  const tab = await activeTab();
  if (!tab?.url || !/^https?:/.test(tab.url)) return;
  const r = await call("lookup_url", { url: tab.url });
  const box = $("savedHere");
  if (r.ok && r.data) {
    const where = r.data.folder ? ` · ${r.data.folder.replaceAll("/", " › ")}` : "";
    const tags = r.data.tags?.length ? ` · #${r.data.tags.join(" #")}` : "";
    box.textContent = t(`✓ Bu sayfa arşivde${where}${tags}`, `✓ This page is in the archive${where}${tags}`);
    box.classList.add("on");
    $("save").textContent = t("Yeniden Kaydet (günceller)", "Save Again (updates it)");
  } else {
    box.classList.remove("on");
  }
}

// --- Whole-list imports for sites with their own "saved" page --------------

async function setupSiteImport() {
  const tab = await activeTab();
  let host = "";
  try {
    host = new URL(tab?.url || "").hostname.replace(/^www\./, "");
  } catch {}
  const row = $("siteImportRow");
  const btn = $("siteImportBtn");
  if (host === "reddit.com" || host.endsWith(".reddit.com")) {
    row.style.display = "";
    btn.textContent = "🔖 Reddit kaydedilenlerini aktar";
    btn.onclick = async () => {
      btn.disabled = true;
      setMsg($("collectMsg"), t("Reddit kaydedilenleri okunuyor… (100'er 100'er)", "Reading your Reddit saved items… (100 at a time)"));
      const r = await send({ type: "import_reddit" });
      btn.disabled = false;
      if (r?.ok) {
        setMsg($("collectMsg"), t(`✓ u/${r.data.name}: ${r.data.total} kayıt aktarıldı (${r.data.new} yeni)`, `✓ u/${r.data.name}: imported ${r.data.total} items (${r.data.new} new)`), "ok");
        refreshStatus();
      } else {
        setMsg($("collectMsg"), r?.error || t("Reddit aktarımı başarısız", "Reddit import failed"), "err");
      }
    };
  } else if (host === "instagram.com") {
    row.style.display = "";
    btn.textContent = t("📌 Instagram Kaydedilenler'i aç", "📌 Open Instagram Saved");
    btn.onclick = async () => {
      // The Saved page lives under the profile, whose name only the page knows.
      const [res] = await chrome.scripting
        .executeScript({
          target: { tabId: tab.id },
          func: () => {
            const hrefs = [...document.querySelectorAll("a[href]")].map((a) => a.getAttribute("href"));
            const saved = hrefs.find((h) => /^\/[^/]+\/saved\/?$/.test(h));
            if (saved) return saved;
            const img = [...document.querySelectorAll("a[href] img")].find((i) => /profil|profile/i.test(i.alt || ""));
            const prof = img && img.closest("a").getAttribute("href");
            return prof && /^\/[^/]+\/?$/.test(prof) ? prof.replace(/\/?$/, "/saved/") : null;
          },
        })
        .catch(() => [{}]);
      if (res?.result) {
        await chrome.tabs.update(tab.id, { url: new URL(res.result, tab.url).href });
        setMsg($("collectMsg"), t("Kaydedilenler'de aşağı kaydır (ya da Otomatik Kaydır); gönderiler burada birikir.", "Scroll down in Saved (or use Auto Scroll); posts gather here."));
      } else {
        setMsg($("collectMsg"), t("Profiline gidip Kaydedilenler sekmesini aç ve kaydır; gönderiler burada birikir.", "Go to your profile, open the Saved tab and scroll; posts gather here."));
      }
    };
  } else if (host === "youtube.com" || host === "m.youtube.com") {
    row.style.display = "";
    btn.textContent = t("⏰ Daha Sonra İzle'yi aç", "⏰ Open Watch Later");
    btn.onclick = async () => {
      await chrome.tabs.update(tab.id, { url: "https://www.youtube.com/playlist?list=WL" });
      setMsg($("collectMsg"), t("Listeyi sonuna kadar kaydır (ya da Otomatik Kaydır), sonra Aktar. Beğendiğin videolar: list=LL.", "Scroll to the end of the list (or use Auto Scroll), then Import. Liked videos: list=LL."));
    };
  } else if (host === "x.com" || host === "twitter.com") {
    row.style.display = "";
    btn.textContent = t("🔖 X yer imlerini aç ve eşitle", "🔖 Open and sync X bookmarks");
    btn.onclick = async () => {
      await chrome.tabs.update(tab.id, { url: "https://x.com/i/bookmarks" });
      setMsg($("collectMsg"), t("Yer imlerin açılıyor; kaydırdıkça otomatik eşitlenir.", "Opening your bookmarks; they sync as you scroll."));
    };
  } else if (host === "bsky.app") {
    row.style.display = "";
    btn.textContent = t("🔖 Bluesky kaydedilenleri aç", "🔖 Open Bluesky saved");
    btn.onclick = async () => {
      await chrome.tabs.update(tab.id, { url: "https://bsky.app/saved" });
      setMsg($("collectMsg"), t("Kaydedilenler açılıyor; yer imine basınca da hemen eşitlenir.", "Opening saved posts; a new bookmark syncs right away too."));
    };
  } else if (host === "threads.net" || host === "threads.com") {
    row.style.display = "";
    btn.textContent = t("🧵 Threads kaydedilenleri aç", "🧵 Open Threads saved");
    btn.onclick = async () => {
      await chrome.tabs.update(tab.id, { url: "https://www.threads.com/saved" });
      setMsg($("collectMsg"), t("Kaydedilenler'de aşağı kaydır (ya da Otomatik Kaydır); gönderiler eşitlenir.", "Scroll down in Saved (or use Auto Scroll); posts sync."));
    };
  } else if (host === "pinterest.com" || host.endsWith(".pinterest.com")) {
    row.style.display = "";
    btn.textContent = t("📌 Pinterest panoları eşitle", "📌 Sync Pinterest boards");
    btn.onclick = async () => {
      await chrome.tabs.update(tab.id, { url: "https://www.pinterest.com/" });
      setMsg($("collectMsg"), t("Panona girip aşağı kaydır (ya da Otomatik Kaydır); pinler eşitlenir.", "Open a board and scroll down (or use Auto Scroll); pins sync."));
    };
  }
}

async function initAutoSync() {
  const { autoSync } = await chrome.storage.local.get("autoSync");
  $("autoSyncToggle").checked = autoSync !== false;
  $("autoSyncToggle").addEventListener("change", async (e) => {
    await chrome.storage.local.set({ autoSync: e.target.checked });
    syncCollected();
  });
}

// --- Collected Queue Management ---------------------------------------------

async function syncCollected() {
  const r = await send({ type: "get_collected" });
  if (!r?.ok) return;

  const { total, x, tiktok, pages } = r.data;
  $("collectedBadge").textContent = total;
  $("collectedBtnCount").textContent = total;

  if (total > 0) {
    $("collectedBadge").classList.remove("empty");
    $("importCollectedBtn").disabled = false;
    $("clearCollectedBtn").style.display = "";

    const parts = [];
    if (x > 0) parts.push(`${x} X`);
    if (tiktok > 0) parts.push(`${tiktok} TikTok`);
    if (r.data.instagram > 0) parts.push(`${r.data.instagram} Instagram`);
    if (r.data.youtube > 0) parts.push(`${r.data.youtube} YouTube`);
    if (r.data.bluesky > 0) parts.push(`${r.data.bluesky} Bluesky`);
    if (r.data.threads > 0) parts.push(`${r.data.threads} Threads`);
    if (r.data.pinterest > 0) parts.push(`${r.data.pinterest} Pinterest`);
    if (pages > 0) parts.push(t(`${pages} sayfa/link`, `${pages} pages/links`));
    $("collectedSummary").textContent = t(`Kuyrukta: ${parts.join(" · ")}. Tek tıkla aktarabilirsiniz.`, `Queued: ${parts.join(" · ")}. Import with one click.`);
  } else {
    $("collectedBadge").classList.add("empty");
    $("importCollectedBtn").disabled = true;
    $("clearCollectedBtn").style.display = "none";
    const { lastAutoSync } = await sessionStore.get("lastAutoSync");
    if ($("autoSyncToggle").checked && lastAutoSync) {
      $("collectedSummary").textContent = t(`✓ ${lastAutoSync.platform} otomatik eşitlendi (${lastAutoSync.total} gönderi, +${lastAutoSync.newCount} yeni).`, `✓ ${lastAutoSync.platform} synced automatically (${lastAutoSync.total} posts, +${lastAutoSync.newCount} new).`);
    } else {
      $("collectedSummary").textContent = $("autoSyncToggle").checked
        ? t("Yer imlerin ve kaydettiklerin açtıkça kendiliğinden kütüphaneye gider.", "Your bookmarks and saves go to the library on their own as you open them.")
        : t("Sayfada gezindikçe veya kaydırdıkça gönderiler ve linkler burada birikir.", "Posts and links gather here as you browse and scroll.");
    }
  }
}

$("importCollectedBtn").addEventListener("click", async () => {
  $("importCollectedBtn").disabled = true;
  setMsg($("collectMsg"), t("Wroopmark'a aktarılıyor…", "Importing into wroopmark…"));

  const r = await send({ type: "import_collected" });
  $("importCollectedBtn").disabled = false;

  if (r?.ok) {
    const d = r.data;
    setMsg($("collectMsg"), t(`✓ ${d.total} içerik aktarıldı (${d.new} yeni, ${d.updated} güncellendi)`, `✓ Imported ${d.total} (${d.new} new, ${d.updated} updated)`), "ok");
    await refreshStatus();
    await syncCollected();
  } else {
    setMsg($("collectMsg"), r?.error || t("Aktarım sırasında hata oluştu", "Something went wrong while importing"), "err");
  }
});

$("clearCollectedBtn").addEventListener("click", async () => {
  await send({ type: "clear_collected" });
  setMsg($("collectMsg"), t("Toplanan liste temizlendi", "Cleared the collected list"));
  await syncCollected();
});

// --- Auto Scroller -----------------------------------------------------------

async function syncScrollStatus() {
  const r = await send({ type: "get_scroll_status" });
  const active = !!r?.active;
  const btn = $("autoScrollBtn");

  btn.classList.toggle("active", active);
  $("scrollIcon").textContent = active ? "⏸" : "▶";
  $("scrollLabel").textContent = active ? t("Kaydırmayı Durdur", "Stop Scrolling") : t("Otomatik Kaydır", "Auto Scroll");
  setMsg($("scrollMsg"), active ? t("Otomatik kaydırılıyor · Sayfayı elle de kaydırabilirsiniz", "Scrolling · you can still scroll the page yourself") : "");
}

$("autoScrollBtn").addEventListener("click", async () => {
  const r = await send({ type: "toggle_autoscroll" });
  await syncScrollStatus();
  await syncCollected();
});

// --- Save Active Tab ---------------------------------------------------------

$("save").addEventListener("click", async () => {
  $("save").disabled = true;
  setMsg($("saveMsg"), t("Sayfa analiz edilip kaydediliyor…", "Reading and saving the page…"));

  const tags = $("tags").value.split(/[,\n]/).map((t) => t.trim()).filter(Boolean);
  const note = $("note").value.trim() || null;

  const folder = $("folder").value;
  const r = await send({ type: "save_tab", tags, note, folder_id: folder ? Number(folder) : null });
  $("save").disabled = false;

  if (r?.ok) {
    setMsg($("saveMsg"), t(`✓ Kaydedildi: ${r.data.id}`, `✓ Saved: ${r.data.id}`), "ok");
    $("note").value = "";
    refreshStatus();
    showSavedHere();
  } else {
    setMsg($("saveMsg"), r?.error || t("Kaydedilemedi", "Couldn't save"), "err");
  }
});

// --- Search ------------------------------------------------------------------

function renderResults(items, links) {
  const ul = $("results");
  ul.replaceChildren();

  for (const it of items) {
    const li = document.createElement("li");
    const who = it.author_handle ? `@${it.author_handle}` : it.author_name || "";
    const meta = document.createElement("div");
    meta.className = "res-meta";
    meta.append(PLATFORM_NAMES[it.platform] || it.platform, who ? ` · ${who}` : "");

    for (const t of it.tags || []) {
      const span = document.createElement("span");
      span.className = "tag";
      span.textContent = t;
      meta.append(span);
    }

    const body = document.createElement("div");
    body.className = "res-body";
    body.textContent = it.title || it.text || it.url;
    const main = document.createElement("div");
    main.className = "res-main";
    main.append(meta, body);
    // Opens the archived copy in the app (works even if the post is gone).
    main.title = t("wroopmark'ta aç", "Open in wroopmark");
    main.onclick = () => openInApp(it.id);
    const src = document.createElement("button");
    src.className = "src";
    src.textContent = "↗";
    src.title = t("Kaynağında aç", "Open at source");
    src.onclick = () => chrome.tabs.create({ url: it.url });
    li.append(main, src);
    ul.append(li);
  }

  for (const l of links) {
    const li = document.createElement("li");
    li.innerHTML = `<div class="res-meta">link · ${t(`${l.item_count} kayıtta`, `in ${l.item_count} items`)}</div>`;
    const body = document.createElement("div");
    body.className = "res-body";
    body.textContent = l.title || l.url;
    li.append(body);
    li.onclick = () => chrome.tabs.create({ url: l.url });
    ul.append(li);
  }
}

async function openInApp(id) {
  const url = `wroopmark://item/${encodeURIComponent(id)}`;
  const tab = await activeTab();
  // The browser hands a custom scheme to the app and keeps the page as is.
  if (tab?.id != null) chrome.tabs.update(tab.id, { url }).catch(() => chrome.tabs.create({ url }));
  else chrome.tabs.create({ url });
  window.close();
}

let searchTimer;
$("q").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const q = $("q").value.trim();
    if (!q) return $("results").replaceChildren();
    const r = await call("search", { q, limit: 15 });
    if (r.ok) renderResults(r.data.items, r.data.links);
  }, 140);
});

// Sync on storage change (e.g. background scroller found items)
sessionStore.onChanged?.addListener(() => {
  syncCollected();
  syncScrollStatus();
});

// Initial boot
initAutoSync().then(syncCollected);
refreshStatus();
showSavedHere();
setupSiteImport();
syncScrollStatus();
