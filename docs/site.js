// Scroll effects for the landing page: the hero straightens up as you scroll,
// layers move at their own speed (data-speed), sections fade in as they
// arrive. Transforms only, one requestAnimationFrame per scroll; nothing runs
// when the person asked for reduced motion.
(() => {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  root.classList.add("js");

  // Fade-in as sections arrive (shown at once when motion is reduced).
  const reveals = document.querySelectorAll(".reveal, .reveal-fade");
  if (reduce.matches || !("IntersectionObserver" in window)) {
    reveals.forEach((el) => el.classList.add("in"));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  }

  const bar = document.querySelector(".bar");
  const hero = document.querySelector(".hero");
  const layers = [...document.querySelectorAll("[data-speed]")];
  let queued = false;

  function frame() {
    queued = false;
    const y = scrollY;
    const vh = innerHeight;
    if (bar) bar.classList.toggle("scrolled", y > 8);
    if (reduce.matches) return;

    // 0 at the top of the page, 1 once the hero has mostly scrolled by.
    if (hero) {
      const s = Math.min(1, Math.max(0, y / (hero.offsetHeight * 0.75)));
      hero.style.setProperty("--s", s.toFixed(4));
    }

    // Each layer drifts by speed × how far its middle is from the screen's.
    for (const el of layers) {
      const r = el.parentElement.getBoundingClientRect();
      if (r.bottom < -vh || r.top > vh * 2) continue;
      const p = (r.top + r.height / 2 - vh / 2) / vh;
      el.style.setProperty("--py", `${(p * parseFloat(el.dataset.speed)).toFixed(1)}px`);
    }
  }

  function queue() {
    if (!queued) { queued = true; requestAnimationFrame(frame); }
  }

  addEventListener("scroll", queue, { passive: true });
  addEventListener("resize", queue);
  reduce.addEventListener?.("change", () => {
    if (reduce.matches) {
      hero?.style.removeProperty("--s");
      layers.forEach((el) => el.style.removeProperty("--py"));
      reveals.forEach((el) => el.classList.add("in"));
    }
    queue();
  });
  frame();
})();
