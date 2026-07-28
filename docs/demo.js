(function () {
  "use strict";

  document.querySelectorAll(".nav-links a").forEach(function (link) {
    link.addEventListener("click", function () {
      var toggle = document.getElementById("nav-toggle");
      if (toggle) toggle.checked = false;
    });
  });

  var stage = document.getElementById("mirror-stage");
  var phone = document.getElementById("phone");
  var screen = document.getElementById("screen");
  var pages = document.getElementById("pages");
  var dots = document.getElementById("dots");
  var cursor = document.getElementById("cursor");
  var ripple = document.getElementById("ripple");
  var log = document.getElementById("event-log");
  var timeEl = document.getElementById("phone-time");
  if (!stage || !phone || !screen || !pages) return;

  var page = 0;
  var pageCount = 3;
  var dragging = false;
  var startX = 0;
  var startY = 0;
  var moved = false;
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function setTime() {
    if (!timeEl) return;
    var d = new Date();
    timeEl.textContent =
      d.getHours() + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  setTime();
  setInterval(setTime, 30000);

  function logEvent(text) {
    if (!log) return;
    var li = document.createElement("li");
    var stamp = new Date();
    li.innerHTML =
      "<code>" +
      stamp.getSeconds() +
      "." +
      String(stamp.getMilliseconds()).padStart(3, "0") +
      "</code> " +
      text;
    log.prepend(li);
    while (log.children.length > 8) log.removeChild(log.lastChild);
  }

  function goPage(next) {
    page = Math.max(0, Math.min(pageCount - 1, next));
    pages.style.transform = "translateX(" + -page * 100 + "%)";
    if (dots) {
      Array.prototype.forEach.call(dots.children, function (dot, i) {
        dot.classList.toggle("on", i === page);
      });
    }
    logEvent("swipe → page " + (page + 1));
  }

  function localPoint(e) {
    var rect = screen.getBoundingClientRect();
    var x = (("clientX" in e ? e.clientX : e.touches[0].clientX) - rect.left) / rect.width;
    var y = (("clientY" in e ? e.clientY : e.touches[0].clientY) - rect.top) / rect.height;
    return {
      x: Math.min(1, Math.max(0, x)),
      y: Math.min(1, Math.max(0, y)),
      rect: rect,
    };
  }

  function moveCursor(pt) {
    cursor.hidden = false;
    cursor.style.left = pt.x * 100 + "%";
    cursor.style.top = pt.y * 100 + "%";
    if (!reduceMotion) {
      var rx = (pt.y - 0.5) * -10;
      var ry = (pt.x - 0.5) * 14;
      phone.style.transform =
        "rotateX(" + rx + "deg) rotateY(" + ry + "deg) translateY(-2px)";
    }
  }

  function showRipple(pt) {
    ripple.hidden = false;
    ripple.classList.remove("pop");
    ripple.style.left = pt.x * 100 + "%";
    ripple.style.top = pt.y * 100 + "%";
    void ripple.offsetWidth;
    ripple.classList.add("pop");
  }

  function hitApp(pt) {
    var apps = screen.querySelectorAll(".page-home .app");
    var rect = screen.getBoundingClientRect();
    var cx = rect.left + pt.x * rect.width;
    var cy = rect.top + pt.y * rect.height;
    for (var i = 0; i < apps.length; i++) {
      var r = apps[i].getBoundingClientRect();
      if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
        return apps[i];
      }
    }
    return null;
  }

  stage.addEventListener("pointerenter", function () {
    stage.classList.add("active");
  });

  stage.addEventListener("pointerleave", function () {
    stage.classList.remove("active");
    cursor.hidden = true;
    if (!reduceMotion) phone.style.transform = "";
    dragging = false;
  });

  stage.addEventListener("pointermove", function (e) {
    if (!e.isPrimary && e.pointerType !== "touch") return;
    var pt = localPoint(e);
    moveCursor(pt);
    if (dragging) {
      var dx = (e.clientX - startX) / screen.getBoundingClientRect().width;
      var dy = (e.clientY - startY) / screen.getBoundingClientRect().height;
      if (Math.abs(dx) > 0.03 || Math.abs(dy) > 0.03) moved = true;
      pages.style.transition = "none";
      pages.style.transform =
        "translateX(calc(" + -page * 100 + "% + " + dx * 100 + "%))";
    }
  });

  stage.addEventListener("pointerdown", function (e) {
    if (e.button !== undefined && e.button !== 0) return;
    stage.setPointerCapture(e.pointerId);
    dragging = true;
    moved = false;
    startX = e.clientX;
    startY = e.clientY;
    var pt = localPoint(e);
    moveCursor(pt);
    cursor.classList.add("down");
  });

  stage.addEventListener("pointerup", function (e) {
    cursor.classList.remove("down");
    var pt = localPoint(e);
    var dx = (e.clientX - startX) / Math.max(1, screen.getBoundingClientRect().width);

    if (dragging && moved && Math.abs(dx) > 0.12) {
      pages.style.transition = "";
      goPage(page + (dx < 0 ? 1 : -1));
    } else if (dragging && !moved) {
      pages.style.transition = "";
      pages.style.transform = "translateX(" + -page * 100 + "%)";
      showRipple(pt);
      var app = page === 0 ? hitApp(pt) : null;
      if (app) {
        app.classList.add("pulse");
        setTimeout(function () {
          app.classList.remove("pulse");
        }, 280);
        logEvent("tap " + app.getAttribute("data-app"));
        goPage(2);
      } else {
        logEvent(
          "tap " + pt.x.toFixed(2) + "," + pt.y.toFixed(2)
        );
      }
    } else {
      pages.style.transition = "";
      pages.style.transform = "translateX(" + -page * 100 + "%)";
    }
    dragging = false;
  });

  stage.addEventListener("pointercancel", function () {
    dragging = false;
    cursor.classList.remove("down");
    pages.style.transition = "";
    pages.style.transform = "translateX(" + -page * 100 + "%)";
  });

  // Prevent page scroll while swiping on the demo
  stage.addEventListener(
    "touchmove",
    function (e) {
      if (dragging) e.preventDefault();
    },
    { passive: false }
  );

  logEvent("session ready");
  logEvent("device linked");

  if (!reduceMotion) {
    var idle = 0;
    setInterval(function () {
      if (stage.classList.contains("active")) return;
      idle += 1;
      phone.style.transform =
        "rotateY(" + Math.sin(idle / 18) * 4 + "deg) translateY(" +
        Math.sin(idle / 12) * 3 +
        "px)";
    }, 40);
  }
})();
