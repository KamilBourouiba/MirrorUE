(function () {
  "use strict";

  var sticky = document.getElementById("sticky-cta");
  var hero = document.querySelector(".hero");
  var waitlist = document.getElementById("waitlist");
  var foot = document.querySelector(".foot");
  var mobileMq = window.matchMedia("(max-width: 734px)");

  function updateSticky() {
    if (!sticky || !hero) return;
    if (document.body.classList.contains("waitlist-open")) {
      sticky.hidden = true;
      return;
    }

    var footTop = foot ? foot.getBoundingClientRect().top : Infinity;

    if (mobileMq.matches) {
      var showMobile = footTop > window.innerHeight * 0.35;
      sticky.hidden = !showMobile;
      sticky.setAttribute("aria-hidden", showMobile ? "false" : "true");
      return;
    }

    var heroBottom = hero.getBoundingClientRect().bottom;
    var show = heroBottom < 0 && footTop > window.innerHeight * 0.5;
    sticky.hidden = !show;
    sticky.setAttribute("aria-hidden", show ? "false" : "true");
  }

  window.addEventListener("scroll", updateSticky, { passive: true });
  window.addEventListener("resize", updateSticky);
  mobileMq.addEventListener("change", updateSticky);
  updateSticky();

  var observer = new MutationObserver(updateSticky);
  observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });

  if (location.hash === "#waitlist" && waitlist) {
    requestAnimationFrame(function () {
      waitlist.scrollIntoView({ behavior: "smooth", block: "start" });
      var input = waitlist.querySelector('input[name="email"]');
      if (input) setTimeout(function () { input.focus(); }, 400);
    });
  }

  document.querySelectorAll('a[href="#waitlist"]').forEach(function (link) {
    link.addEventListener("click", function () {
      var toggle = document.getElementById("nav-toggle");
      if (toggle) toggle.checked = false;
    });
  });

  // Track Google Ads Conversion on DMG Download
  document.querySelectorAll('a[href*="MirrorUE.dmg"]').forEach(function (btn) {
    btn.addEventListener("click", function () {
      if (typeof window.gtag === "function") {
        window.gtag("event", "conversion", {
          send_to: "AW-18393322142",
          event_category: "download",
          event_label: "MirrorUE.dmg"
        });
      }
    });
  });
})();
