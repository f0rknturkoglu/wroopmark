const $ = (id) => document.getElementById(id);
const send = (msg) => chrome.runtime.sendMessage(msg);
const call = (cmd, args = {}) => send({ type: "call", cmd, args });
const fmt = new Intl.NumberFormat("tr-TR");

const PLATFORM = { x: "X", tiktok: "TikTok", pinterest: "Pinterest", facebook: "Facebook", web: "Web" };

function setMsg(el, text, isErr = false) {
  el.textContent = text;
  el.classList.toggle("err", isErr);
}

async function refreshStatus() {
  const r = await call("stats");
  if (!r.ok) {
    $("status").textContent = "bağlı değil";
    setMsg($("saveMsg"), `wroopmark'a ulaşılamadı; wroopmark uygulamasını bir kez açman yeterli. (${r.error})`, true);
    return false;
  }
  const s = r.data;
  $("status").textContent = `${fmt.format(s.items)} kayıt · ${fmt.format(s.tags)} etiket · ${fmt.format(s.links)} link`;
  const tags = await call("tags");
  if (tags.ok) $("taglist").innerHTML = tags.data.map((t) => `<option value="${t.name.replace(/"/g, "&quot;")}">`).join("");
  return true;
}

function render(items, links) {
  const ul = $("results");
  ul.replaceChildren();
  for (const it of items) {
    const li = document.createElement("li");
    const who = it.author_handle ? `@${it.author_handle}` : it.author_name || "";
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.append(PLATFORM[it.platform] || it.platform, who ? ` · ${who}` : "");
    for (const t of it.tags || []) {
      const span = document.createElement("span");
      span.className = "tag";
      span.textContent = t;
      meta.append(span);
    }
    const body = document.createElement("div");
    body.className = "body";
    body.textContent = it.title || it.text || it.url;
    li.append(meta, body);
    li.onclick = () => chrome.tabs.create({ url: it.url });
    ul.append(li);
  }
  for (const l of links) {
    const li = document.createElement("li");
    li.innerHTML = `<div class="meta">link · ${l.item_count} kayıtta</div>`;
    const body = document.createElement("div");
    body.className = "body";
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
    const r = await call("search", { q, limit: 20 });
    if (r.ok) render(r.data.items, r.data.links);
  }, 140);
});

$("save").addEventListener("click", async () => {
  $("save").disabled = true;
  setMsg($("saveMsg"), "kaydediliyor…");
  const tags = $("tags").value.split(/[,\n]/).map((t) => t.trim()).filter(Boolean);
  const note = $("note").value.trim() || null;
  const r = await send({ type: "save_tab", tags, note });
  $("save").disabled = false;
  if (r?.ok) {
    setMsg($("saveMsg"), `kaydedildi: ${r.data.id}`);
    refreshStatus();
  } else {
    setMsg($("saveMsg"), r?.error || "kaydedilemedi", true);
  }
});

async function syncScan() {
  const { scanning, session } = await chrome.storage.session.get(["scanning", "session"]);
  $("scan").textContent = scanning ? "Taramayı durdur" : "Tüm X yer imlerini içe aktar";
  $("scanTikTok").style.display = scanning ? "none" : "";
  const s = session || { new: 0, updated: 0 };
  setMsg($("scanMsg"), scanning ? `taranıyor… ${s.new} yeni, ${s.updated} güncellendi` : s.new || s.updated ? `bu oturum: ${s.new} yeni, ${s.updated} güncellendi` : "");
  return scanning;
}

$("scan").addEventListener("click", async () => {
  if (await syncScan()) await send({ type: "stop_scan" });
  else await send({ type: "scan_x" });
  syncScan();
});

$("scanTikTok").addEventListener("click", async () => {
  setMsg($("scanMsg"), "TikTok profili açılıyor…");
  const r = await send({ type: "scan_tiktok" });
  if (r && r.ok === false) setMsg($("scanMsg"), r.error || "TikTok taraması başlatılamadı", true);
  syncScan();
});


chrome.storage.session.onChanged.addListener(syncScan);
chrome.action.setBadgeText({ text: "" });
refreshStatus();
syncScan();
