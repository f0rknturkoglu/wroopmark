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
  return true;
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

  const r = await send({ type: "save_tab", tags, note });
  $("save").disabled = false;

  if (r?.ok) {
    setMsg($("saveMsg"), `✓ Kaydedildi: ${r.data.id}`, "ok");
    $("note").value = "";
    refreshStatus();
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
    li.append(meta, body);
    li.onclick = () => chrome.tabs.create({ url: it.url });
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
syncCollected();
syncScrollStatus();
