// Scroll effects for the landing page.
//
// - Tours ([data-tour]): a sticky stage and a column of steps. The step at the
//   reading line becomes active; it says which layers to show (data-show) and,
//   for the Mac, where the camera looks (data-zoom / data-ox / data-oy).
// - Hero: the Mac straightens and the iPhone rises as you scroll (--s).
// - Layers with data-speed drift at their own pace (--py).
// - Words in the privacy statement light up one by one, the platform names
//   slide sideways, numbers count up, the top bar shows how far you are.
//
// Transforms and classes only, one requestAnimationFrame per scroll. With
// reduced motion the steps still switch, but nothing drifts or animates.
(() => {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const narrow = matchMedia("(max-width: 860px)");
  const lang = root.lang || "en";
  root.classList.add("js");

  // Reveals, line drawings and counters, once each.
  const once = document.querySelectorAll(".reveal, .reveal-fade, [data-draw], .stat");
  const reveal = (el) => {
    el.classList.add("in");
    el.querySelectorAll?.("[data-count]").forEach(count);
  };
  if (reduce.matches || !("IntersectionObserver" in window)) {
    once.forEach((el) => el.classList.add("in"));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) { reveal(e.target); io.unobserve(e.target); }
      }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    once.forEach((el) => io.observe(el));
  }

  function count(el) {
    const target = parseFloat(el.dataset.count.replace(",", "."));
    if (!(target > 0) || reduce.matches) return;
    const decimals = (el.dataset.count.split(/[.,]/)[1] || "").length;
    const fmt = new Intl.NumberFormat(lang, { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
    const t0 = performance.now();
    const dur = 1300;
    const tick = (t) => {
      const k = Math.min(1, (t - t0) / dur);
      el.textContent = fmt.format(target * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  // Tours.
  const tours = [...document.querySelectorAll("[data-tour]")].map((tour) => {
    const steps = [...tour.querySelectorAll(".step")];
    const layers = [...tour.querySelectorAll("[data-layer]")];
    const toks = [...tour.querySelectorAll(".tok")];
    const dots = [...tour.querySelectorAll(".dots i")];
    const zoomer = tour.querySelector(".zoomer");
    let active = -1;
    function set(i) {
      if (i === active) return;
      active = i;
      const s = steps[i];
      tour.dataset.step = String(i);
      steps.forEach((x, j) => x.classList.toggle("on", j === i));
      dots.forEach((x, j) => x.classList.toggle("on", j === i));
      const show = (s.dataset.show || "").split(" ");
      layers.forEach((l) => l.classList.toggle("on", show.includes(l.dataset.layer)));
      toks.forEach((t) => {
        const k = Number(t.dataset.i);
        t.classList.toggle("shown", k <= i);
        t.classList.toggle("active", k === i);
      });
      if (zoomer) {
        zoomer.style.setProperty("--z", s.dataset.zoom || 1);
        zoomer.style.setProperty("--ox", s.dataset.ox || "50%");
        zoomer.style.setProperty("--oy", s.dataset.oy || "50%");
      }
    }
    set(0);
    return (vh) => {
      const line = vh * (narrow.matches ? 0.78 : 0.55);
      let i = 0;
      steps.forEach((s, j) => { if (s.getBoundingClientRect().top < line) i = j; });
      set(i);
    };
  });

  const bar = document.querySelector(".bar");
  const progress = document.querySelector(".progress");
  const hero = document.querySelector(".hero");
  const layers = [...document.querySelectorAll("[data-speed]")];
  const words = document.querySelector("[data-words]");
  const wordSpans = words ? [...words.querySelectorAll(".words span")] : [];
  const track = document.querySelector("[data-marquee]");
  let queued = false;

  function frame() {
    queued = false;
    const y = scrollY;
    const vh = innerHeight;
    const max = Math.max(1, root.scrollHeight - vh);
    bar?.classList.toggle("scrolled", y > 8);
    progress?.style.setProperty("--p", (y / max).toFixed(4));
    tours.forEach((update) => update(vh));

    if (words) {
      const r = words.getBoundingClientRect();
      const p = Math.min(1, Math.max(0, (vh * 0.15 - r.top) / Math.max(1, r.height - vh)));
      const lit = reduce.matches ? wordSpans.length : Math.round(p * wordSpans.length * 1.08);
      wordSpans.forEach((w, i) => w.classList.toggle("lit", i < lit));
    }
    if (reduce.matches) return;

    if (hero) {
      const s = Math.min(1, Math.max(0, y / (hero.offsetHeight * 0.75)));
      hero.style.setProperty("--s", s.toFixed(4));
    }
    if (track) {
      const w = track.firstElementChild.offsetWidth || 1;
      track.style.setProperty("--mx", `${(-((y * 0.45) % w)).toFixed(1)}px`);
    }
    for (const el of layers) {
      const r = el.parentElement.getBoundingClientRect();
      if (r.bottom < -vh || r.top > vh * 2) continue;
      const p = (r.top + r.height / 2 - vh / 2) / vh;
      el.style.setProperty("--py", `${(p * parseFloat(el.dataset.speed)).toFixed(1)}px`);
    }
  }

  // A frame per scroll; if the browser holds frames back (a background tab),
  // the steps still catch up a moment later.
  function queue() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(frame);
    setTimeout(() => { if (queued) frame(); }, 150);
  }
  addEventListener("scroll", queue, { passive: true });
  addEventListener("resize", queue);
  reduce.addEventListener?.("change", () => location.reload());
  frame();

  // The menu marks the section you are in.
  const links = [...document.querySelectorAll('.bar nav a[href^="#"]')];
  if ("IntersectionObserver" in window && links.length) {
    const byId = new Map(links.map((a) => [a.getAttribute("href").slice(1), a]));
    const nio = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        links.forEach((a) => a.classList.remove("on"));
        byId.get(e.target.id)?.classList.add("on");
      }
    }, { rootMargin: "-45% 0px -50% 0px" });
    byId.forEach((_, id) => { const s = document.getElementById(id); if (s) nio.observe(s); });
  }
})();
