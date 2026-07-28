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
  var homeLayer = document.getElementById("home-layer");
  var appSheet = document.getElementById("app-sheet");
  var appBody = document.getElementById("app-body");
  var appTitle = document.getElementById("app-title");
  var appBack = document.getElementById("app-back");
  var cursor = document.getElementById("cursor");
  var ripple = document.getElementById("ripple");
  var apiFeed = document.getElementById("api-feed");
  var timeEl = document.getElementById("phone-time");
  var replayBtn = document.getElementById("api-replay");
  if (!stage || !phone || !screen) return;

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var userActive = false;
  var userTimer = null;
  var autoRunning = false;
  var autoToken = 0;
  var openAppName = null;

  var APPS = {
    Messages: {
      color: "#34c759",
      html:
        '<div class="mock-msgs">' +
        '<div class="bubble in">Hey — can you run the smoke test?</div>' +
        '<div class="bubble out" id="msg-out"> </div>' +
        '<div class="composer"><span id="msg-typed"></span><i></i></div>' +
        "</div>",
    },
    Safari: {
      color: "#5b6cff",
      html:
        '<div class="mock-safari">' +
        '<div class="urlbar"><span id="url-typed">mirrorue.dev</span></div>' +
        '<div class="webcard"><strong>MirrorUE</strong><p>Control a real iPhone from your Mac.</p><button type="button" class="web-cta" id="web-cta">Download</button></div>' +
        "</div>",
    },
    Mail: {
      color: "#64d2ff",
      html:
        '<div class="mock-mail">' +
        "<label>To</label><div class=\"field\" id=\"mail-to\"></div>" +
        "<label>Subject</label><div class=\"field\" id=\"mail-sub\"></div>" +
        '<div class="mail-body" id="mail-body"></div>' +
        "</div>",
    },
    Settings: {
      color: "#8e8e93",
      html:
        '<div class="mock-settings">' +
        '<div class="row"><span>Developer Mode</span><b class="on">On</b></div>' +
        '<div class="row"><span>Keyboard</span><b>Auto FR/US</b></div>' +
        '<div class="row"><span>Capture FPS</span><b id="fps-val">120</b></div>' +
        '<div class="row toggle" id="hid-row"><span>HID Tunnel</span><b class="on">Linked</b></div>' +
        "</div>",
    },
    Photos: {
      color: "#ff8f7a",
      html:
        '<div class="mock-photos">' +
        "<i></i><i></i><i></i><i></i><i></i><i></i>" +
        "</div>",
    },
    Music: {
      color: "#ff375f",
      html:
        '<div class="mock-music">' +
        '<div class="art"></div><strong>Focus Flow</strong><span>Now Playing</span>' +
        '<div class="seek"><em id="seek-bar"></em></div>' +
        "</div>",
    },
    Maps: {
      color: "#30d158",
      html:
        '<div class="mock-maps"><div class="pin" id="map-pin"></div><p>Route preview</p></div>',
    },
    Xcode: {
      color: "#147efb",
      html:
        '<div class="mock-xcode">' +
        "<code>testLogin()</code>" +
        '<div class="build" id="build-line">Idle</div>' +
        "</div>",
    },
  };

  function setTime() {
    if (!timeEl) return;
    var d = new Date();
    timeEl.textContent =
      d.getHours() + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  setTime();
  setInterval(setTime, 30000);

  function apiLine(method, path, body, ok) {
    if (!apiFeed) return;
    var row = document.createElement("div");
    row.className = "api-line";
    row.innerHTML =
      '<span class="m">' +
      method +
      "</span><span class=\"p\">" +
      path +
      "</span>" +
      (body ? '<span class="b">' + body + "</span>" : "") +
      '<span class="s">' +
      (ok === false ? "err" : "200") +
      "</span>";
    apiFeed.appendChild(row);
    while (apiFeed.children.length > 7) apiFeed.removeChild(apiFeed.firstChild);
    apiFeed.scrollTop = apiFeed.scrollHeight;
  }

  function moveCursor(x, y, animate) {
    cursor.hidden = false;
    if (animate && !reduceMotion) {
      cursor.style.transition = "left 0.45s cubic-bezier(0.22,1,0.36,1), top 0.45s cubic-bezier(0.22,1,0.36,1)";
    } else {
      cursor.style.transition = "none";
    }
    cursor.style.left = x * 100 + "%";
    cursor.style.top = y * 100 + "%";
    if (!reduceMotion && !userActive) {
      var rx = (y - 0.5) * -8;
      var ry = (x - 0.5) * 12;
      phone.style.transform =
        "rotateX(" + rx + "deg) rotateY(" + ry + "deg)";
    }
  }

  function showRipple(x, y) {
    ripple.hidden = false;
    ripple.classList.remove("pop");
    ripple.style.left = x * 100 + "%";
    ripple.style.top = y * 100 + "%";
    void ripple.offsetWidth;
    ripple.classList.add("pop");
    cursor.classList.add("down");
    setTimeout(function () {
      cursor.classList.remove("down");
    }, 120);
  }

  function openApp(name, fromApi) {
    var conf = APPS[name];
    if (!conf) return;
    openAppName = name;
    appTitle.textContent = name;
    appBody.innerHTML = conf.html;
    appSheet.hidden = false;
    appSheet.classList.add("open");
    homeLayer.classList.add("dimmed");
    if (!fromApi) apiLine("POST", "/v1/tap", '{app:"' + name + '"}');
  }

  function closeApp(fromApi) {
    openAppName = null;
    appSheet.classList.remove("open");
    homeLayer.classList.remove("dimmed");
    setTimeout(function () {
      if (!openAppName) appSheet.hidden = true;
    }, 280);
    if (!fromApi) apiLine("POST", "/v1/button", '{name:"home"}');
  }

  function appCenter(name) {
    var btn = homeLayer.querySelector('.app[data-app="' + name + '"]');
    if (!btn) return { x: 0.5, y: 0.4 };
    var sr = screen.getBoundingClientRect();
    var r = btn.getBoundingClientRect();
    return {
      x: (r.left + r.width / 2 - sr.left) / sr.width,
      y: (r.top + r.height / 2 - sr.top) / sr.height,
      el: btn,
    };
  }

  function localPoint(e) {
    var rect = screen.getBoundingClientRect();
    var cx = e.clientX;
    var cy = e.clientY;
    return {
      x: Math.min(1, Math.max(0, (cx - rect.left) / rect.width)),
      y: Math.min(1, Math.max(0, (cy - rect.top) / rect.height)),
    };
  }

  function hitApp(pt) {
    var apps = homeLayer.querySelectorAll(".app");
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

  function markUser() {
    userActive = true;
    autoToken += 1;
    autoRunning = false;
    clearTimeout(userTimer);
    userTimer = setTimeout(function () {
      userActive = false;
      startAutoDemo();
    }, 6500);
  }

  function wait(ms, token) {
    return new Promise(function (resolve) {
      setTimeout(function () {
        resolve(token === autoToken);
      }, ms);
    });
  }

  function typeInto(el, text, token) {
    return new Promise(function (resolve) {
      if (!el) return resolve(false);
      el.textContent = "";
      var i = 0;
      function step() {
        if (token !== autoToken) return resolve(false);
        if (i >= text.length) return resolve(true);
        el.textContent += text.charAt(i);
        i += 1;
        setTimeout(step, reduceMotion ? 0 : 38);
      }
      step();
    });
  }

  async function autoTap(x, y, token) {
    if (token !== autoToken) return false;
    moveCursor(x, y, true);
    if (!(await wait(reduceMotion ? 80 : 480, token))) return false;
    showRipple(x, y);
    return wait(reduceMotion ? 60 : 220, token);
  }

  async function startAutoDemo() {
    if (autoRunning || userActive || reduceMotion) return;
    autoRunning = true;
    var token = ++autoToken;
    if (apiFeed) apiFeed.innerHTML = "";

    apiLine("GET", "/v1/status", "");
    if (!(await wait(500, token))) return (autoRunning = false);

    // Open Messages via API
    var target = appCenter("Messages");
    apiLine("POST", "/v1/tap", '{"x":0.22,"y":0.28}');
    if (!(await autoTap(target.x, target.y, token))) return (autoRunning = false);
    if (target.el) target.el.classList.add("pulse");
    openApp("Messages", true);
    if (!(await wait(400, token))) return (autoRunning = false);

    apiLine("POST", "/v1/type", '{"text":"running login.json"}');
    moveCursor(0.55, 0.82, true);
    var typed = document.getElementById("msg-typed");
    var out = document.getElementById("msg-out");
    if (!(await typeInto(typed, "running login.json", token)))
      return (autoRunning = false);
    if (out) out.textContent = "running login.json";
    if (!(await wait(500, token))) return (autoRunning = false);

    apiLine("POST", "/v1/button", '{"name":"home"}');
    moveCursor(0.5, 0.96, true);
    if (!(await wait(350, token))) return (autoRunning = false);
    showRipple(0.5, 0.96);
    closeApp(true);
    if (!(await wait(450, token))) return (autoRunning = false);

    // Safari + type URL
    target = appCenter("Safari");
    apiLine("POST", "/v1/tap", '{"x":0.48,"y":0.28}');
    if (!(await autoTap(target.x, target.y, token))) return (autoRunning = false);
    openApp("Safari", true);
    if (!(await wait(350, token))) return (autoRunning = false);
    apiLine("POST", "/v1/type", '{"text":"https://mirrorue.dev"}');
    var url = document.getElementById("url-typed");
    if (!(await typeInto(url, "https://mirrorue.dev", token)))
      return (autoRunning = false);
    if (!(await wait(300, token))) return (autoRunning = false);
    apiLine("POST", "/v1/tap", '{"x":0.5,"y":0.62}');
    if (!(await autoTap(0.5, 0.62, token))) return (autoRunning = false);
    var cta = document.getElementById("web-cta");
    if (cta) cta.classList.add("pulse");
    if (!(await wait(500, token))) return (autoRunning = false);

    apiLine("POST", "/v1/button", '{"name":"home"}');
    closeApp(true);
    if (!(await wait(400, token))) return (autoRunning = false);

    // Mail workflow
    target = appCenter("Mail");
    apiLine("POST", "/v1/workflows/run", '{"name":"login.json"}');
    if (!(await autoTap(target.x, target.y, token))) return (autoRunning = false);
    openApp("Mail", true);
    if (!(await wait(280, token))) return (autoRunning = false);
    apiLine("POST", "/v1/type", '{"text":"qa@mirrorue.dev"}');
    if (!(await typeInto(document.getElementById("mail-to"), "qa@mirrorue.dev", token)))
      return (autoRunning = false);
    apiLine("POST", "/v1/type", '{"text":"Smoke OK"}');
    if (!(await typeInto(document.getElementById("mail-sub"), "Smoke OK", token)))
      return (autoRunning = false);
    if (
      !(await typeInto(
        document.getElementById("mail-body"),
        "Device mirrored · HID ok · 120fps",
        token
      ))
    )
      return (autoRunning = false);
    if (!(await wait(700, token))) return (autoRunning = false);

    apiLine("POST", "/v1/button", '{"name":"home"}');
    closeApp(true);
    if (!(await wait(400, token))) return (autoRunning = false);

    // Settings tweak
    target = appCenter("Settings");
    apiLine("POST", "/v1/tap", '{"x":0.78,"y":0.28}');
    if (!(await autoTap(target.x, target.y, token))) return (autoRunning = false);
    openApp("Settings", true);
    if (!(await wait(400, token))) return (autoRunning = false);
    apiLine("POST", "/v1/swipe", '{"from":[0.5,0.7],"to":[0.5,0.35]}');
    moveCursor(0.5, 0.72, true);
    if (!(await wait(280, token))) return (autoRunning = false);
    moveCursor(0.5, 0.4, true);
    var fps = document.getElementById("fps-val");
    if (fps) {
      fps.textContent = "60";
      setTimeout(function () {
        if (fps) fps.textContent = "120";
      }, 400);
    }
    if (!(await wait(700, token))) return (autoRunning = false);
    closeApp(true);
    apiLine("GET", "/v1/status", '{"fps":120,"hid":"up"}');

    moveCursor(0.5, 0.5, true);
    autoRunning = false;
    if (!userActive) {
      await wait(2200, token);
      if (!userActive && token === autoToken) startAutoDemo();
    }
  }

  // Manual interaction
  var dragging = false;
  var startX = 0;
  var startY = 0;
  var moved = false;

  stage.addEventListener("pointerenter", function () {
    stage.classList.add("active");
  });

  stage.addEventListener("pointerleave", function () {
    stage.classList.remove("active");
    if (!autoRunning) cursor.hidden = true;
    dragging = false;
  });

  stage.addEventListener("pointermove", function (e) {
    if (autoRunning && !userActive) return;
    var pt = localPoint(e);
    moveCursor(pt.x, pt.y, false);
  });

  stage.addEventListener("pointerdown", function (e) {
    if (e.button !== undefined && e.button !== 0) return;
    markUser();
    dragging = true;
    moved = false;
    startX = e.clientX;
    startY = e.clientY;
    var pt = localPoint(e);
    moveCursor(pt.x, pt.y, false);
    cursor.classList.add("down");
    try {
      stage.setPointerCapture(e.pointerId);
    } catch (err) {}
  });

  stage.addEventListener("pointerup", function (e) {
    cursor.classList.remove("down");
    var pt = localPoint(e);
    var dx = e.clientX - startX;
    var dy = e.clientY - startY;
    if (Math.abs(dx) > 10 || Math.abs(dy) > 10) moved = true;

    if (dragging && !moved) {
      showRipple(pt.x, pt.y);
      // home bar / back
      if (openAppName && pt.y > 0.92) {
        closeApp(false);
      } else if (openAppName) {
        apiLine("POST", "/v1/tap", '{"x":' + pt.x.toFixed(2) + ',"y":' + pt.y.toFixed(2) + "}");
        if (openAppName === "Music") {
          var seek = document.getElementById("seek-bar");
          if (seek) seek.style.width = Math.round(pt.x * 100) + "%";
        }
        if (openAppName === "Maps") {
          var pin = document.getElementById("map-pin");
          if (pin) {
            pin.style.left = pt.x * 100 + "%";
            pin.style.top = pt.y * 100 + "%";
          }
        }
        if (openAppName === "Xcode") {
          var build = document.getElementById("build-line");
          if (build) {
            build.textContent = "Building…";
            setTimeout(function () {
              if (build) build.textContent = "✔ testLogin passed";
            }, 600);
          }
        }
      } else {
        var app = hitApp(pt);
        if (app) {
          app.classList.add("pulse");
          setTimeout(function () {
            app.classList.remove("pulse");
          }, 280);
          openApp(app.getAttribute("data-app"), false);
        } else {
          apiLine(
            "POST",
            "/v1/tap",
            '{"x":' + pt.x.toFixed(2) + ',"y":' + pt.y.toFixed(2) + "}"
          );
        }
      }
    }
    dragging = false;
  });

  if (appBack) {
    appBack.addEventListener("click", function (e) {
      e.stopPropagation();
      markUser();
      closeApp(false);
    });
  }

  var homeBar = document.getElementById("home-bar");
  if (homeBar) {
    homeBar.addEventListener("click", function (e) {
      e.stopPropagation();
      markUser();
      if (openAppName) closeApp(false);
    });
  }

  if (replayBtn) {
    replayBtn.addEventListener("click", function (e) {
      e.stopPropagation();
      userActive = false;
      startAutoDemo();
    });
  }

  stage.addEventListener(
    "touchmove",
    function (e) {
      if (dragging) e.preventDefault();
    },
    { passive: false }
  );

  // Idle float when not auto-driving heavily
  if (!reduceMotion) {
    var idle = 0;
    setInterval(function () {
      if (stage.classList.contains("active") || autoRunning) return;
      idle += 1;
      phone.style.transform =
        "rotateY(" +
        Math.sin(idle / 18) * 4 +
        "deg) translateY(" +
        Math.sin(idle / 12) * 3 +
        "px)";
    }, 40);
  }

  // Kick off auto demo
  setTimeout(startAutoDemo, reduceMotion ? 0 : 900);
})();
