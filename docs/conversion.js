(function () {
  "use strict";

  var sticky = document.getElementById("sticky-cta");
  var hero = document.querySelector(".hero");
  var waitlist = document.getElementById("waitlist");
  var foot = document.querySelector(".footer") || document.querySelector(".foot");

  if (sticky && hero && "IntersectionObserver" in window) {
    var heroVisible = true;
    var footVisible = false;

    function refreshSticky() {
      if (document.body.classList.contains("waitlist-open")) {
        sticky.hidden = true;
        return;
      }
      var show = !heroVisible && !footVisible;
      sticky.hidden = !show;
      sticky.setAttribute("aria-hidden", show ? "false" : "true");
    }

    var heroObserver = new IntersectionObserver(function (entries) {
      heroVisible = entries[0].isIntersecting;
      refreshSticky();
    }, { threshold: 0.1 });
    heroObserver.observe(hero);

    if (foot) {
      var footObserver = new IntersectionObserver(function (entries) {
        footVisible = entries[0].isIntersecting;
        refreshSticky();
      }, { threshold: 0.1 });
      footObserver.observe(foot);
    }
  }

  if (typeof refreshSticky === "function") {
    var observer = new MutationObserver(refreshSticky);
    observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });
  }

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
      if (typeof window.gtag_report_conversion === "function") {
        window.gtag_report_conversion();
      } else if (typeof window.gtag === "function") {
        window.gtag("event", "conversion", {
          send_to: "AW-18393322142/Ac_OCIq45eMcEJ6lz8JE"
        });
      }
    });
  });
})();
