const $ = (id) => document.getElementById(id);
const send = (msg) => chrome.runtime.sendMessage(msg);
const call = (cmd, args = {}) => send({ type: "call", cmd, args });
const fmt = new Intl.NumberFormat("tr-TR");

const PLATFORM_NAMES = {
  x: "X",
  tiktok: "TikTok",
  reddit: "Reddit",
  youtube: "YouTube",
  instagram: "Instagram",
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
    $("status").textContent = "bağlı değil";
    setMsg($("saveMsg"), `wroopmark kütüphanesine ulaşılamadı (${r.error})`, "err");
    return false;
  }
  const s = r.data;
  $("status").textContent = `${fmt.format(s.items)} kayıt · ${fmt.format(s.tags)} etiket`;
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
  sel.replaceChildren(new Option("Klasörsüz", ""));
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
    box.textContent = `✓ Bu sayfa arşivde${where}${tags}`;
    box.classList.add("on");
    $("save").textContent = "Yeniden Kaydet (günceller)";
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
      setMsg($("collectMsg"), "Reddit kaydedilenleri okunuyor… (100'er 100'er)");
      const r = await send({ type: "import_reddit" });
      btn.disabled = false;
      if (r?.ok) {
        setMsg($("collectMsg"), `✓ u/${r.data.name}: ${r.data.total} kayıt aktarıldı (${r.data.new} yeni)`, "ok");
        refreshStatus();
      } else {
        setMsg($("collectMsg"), r?.error || "Reddit aktarımı başarısız", "err");
      }
    };
  } else if (host === "instagram.com") {
    row.style.display = "";
    btn.textContent = "📌 Instagram Kaydedilenler'i aç";
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
        setMsg($("collectMsg"), "Kaydedilenler'de aşağı kaydır (ya da Otomatik Kaydır); gönderiler burada birikir.");
      } else {
        setMsg($("collectMsg"), "Profiline gidip Kaydedilenler sekmesini aç ve kaydır; gönderiler burada birikir.");
      }
    };
  }
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
    if (pages > 0) parts.push(`${pages} sayfa/link`);
    $("collectedSummary").textContent = `Kuyrukta: ${parts.join(" · ")}. Tek tıkla aktarabilirsiniz.`;
  } else {
    $("collectedBadge").classList.add("empty");
    $("importCollectedBtn").disabled = true;
    $("clearCollectedBtn").style.display = "none";
    $("collectedSummary").textContent = "Sayfada gezindikçe veya kaydırdıkça gönderiler ve linkler burada birikir.";
  }
}

$("importCollectedBtn").addEventListener("click", async () => {
  $("importCollectedBtn").disabled = true;
  setMsg($("collectMsg"), "Wroopmark'a aktarılıyor…");

  const r = await send({ type: "import_collected" });
  $("importCollectedBtn").disabled = false;

  if (r?.ok) {
    const d = r.data;
    setMsg($("collectMsg"), `✓ ${d.total} içerik aktarıldı (${d.new} yeni, ${d.updated} güncellendi)`, "ok");
    await refreshStatus();
    await syncCollected();
  } else {
    setMsg($("collectMsg"), r?.error || "Aktarım sırasında hata oluştu", "err");
  }
});

$("clearCollectedBtn").addEventListener("click", async () => {
  await send({ type: "clear_collected" });
  setMsg($("collectMsg"), "Toplanan liste temizlendi");
  await syncCollected();
});

// --- Auto Scroller -----------------------------------------------------------

async function syncScrollStatus() {
  const r = await send({ type: "get_scroll_status" });
  const active = !!r?.active;
  const btn = $("autoScrollBtn");

  btn.classList.toggle("active", active);
  $("scrollIcon").textContent = active ? "⏸" : "▶";
  $("scrollLabel").textContent = active ? "Kaydırmayı Durdur" : "Otomatik Kaydır";
  setMsg($("scrollMsg"), active ? "Otomatik kaydırılıyor · Sayfayı elle de kaydırabilirsiniz" : "");
}

$("autoScrollBtn").addEventListener("click", async () => {
  const r = await send({ type: "toggle_autoscroll" });
  await syncScrollStatus();
  await syncCollected();
});

// --- Save Active Tab ---------------------------------------------------------

$("save").addEventListener("click", async () => {
  $("save").disabled = true;
  setMsg($("saveMsg"), "Sayfa analiz edilip kaydediliyor…");

  const tags = $("tags").value.split(/[,\n]/).map((t) => t.trim()).filter(Boolean);
  const note = $("note").value.trim() || null;

  const folder = $("folder").value;
  const r = await send({ type: "save_tab", tags, note, folder_id: folder ? Number(folder) : null });
  $("save").disabled = false;

  if (r?.ok) {
    setMsg($("saveMsg"), `✓ Kaydedildi: ${r.data.id}`, "ok");
    $("note").value = "";
    refreshStatus();
    showSavedHere();
  } else {
    setMsg($("saveMsg"), r?.error || "Kaydedilemedi", "err");
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
    main.title = "wroopmark'ta aç";
    main.onclick = () => openInApp(it.id);
    const src = document.createElement("button");
    src.className = "src";
    src.textContent = "↗";
    src.title = "Kaynağında aç";
    src.onclick = () => chrome.tabs.create({ url: it.url });
    li.append(main, src);
    ul.append(li);
  }

  for (const l of links) {
    const li = document.createElement("li");
    li.innerHTML = `<div class="res-meta">link · ${l.item_count} kayıtta</div>`;
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
chrome.storage.session.onChanged.addListener(() => {
  syncCollected();
  syncScrollStatus();
});

// Initial boot
refreshStatus();
showSavedHere();
setupSiteImport();
syncCollected();
syncScrollStatus();
