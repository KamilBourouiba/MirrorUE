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
  var apiModeEl = document.getElementById("api-mode");
  var workflowStepsEl = document.getElementById("workflow-steps");
  var timeEl = document.getElementById("phone-time");
  var replayBtn = document.getElementById("api-replay");
  if (!stage || !phone || !screen) return;

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var mobileMq = window.matchMedia("(max-width: 734px)");
  var coarseMq = window.matchMedia("(pointer: coarse)");
  var isTouchUI =
    mobileMq.matches ||
    coarseMq.matches ||
    (navigator.maxTouchPoints > 0 && mobileMq.matches);

  function applyTouchClass() {
    var touch =
      mobileMq.matches ||
      coarseMq.matches ||
      (navigator.maxTouchPoints > 0 && window.innerWidth <= 734);
    document.documentElement.classList.toggle("touch-ui", touch);
    return touch;
  }
  isTouchUI = applyTouchClass();
  mobileMq.addEventListener("change", function () {
    isTouchUI = applyTouchClass();
  });
  coarseMq.addEventListener("change", function () {
    isTouchUI = applyTouchClass();
  });

  function setPhoneTilt(x, y) {
    if (isTouchUI || reduceMotion) {
      phone.style.transform = "";
      return;
    }
    var rx = (y - 0.5) * -8;
    var ry = (x - 0.5) * 12;
    phone.style.transform = "rotateX(" + rx + "deg) rotateY(" + ry + "deg)";
  }
  var userActive = false;
  var userTimer = null;
  var autoRunning = false;
  var autoToken = 0;
  var openAppName = null;

  var LOGIN_SMOKE = {
    name: "login-smoke",
    steps: [
      { kind: "tap", x: 0.22, y: 0.28, app: "Messages", label: "Messages" },
      { kind: "type", text: "login ok", target: "msg", x: 0.55, y: 0.82, label: "type" },
      { kind: "wait", ms: 320, label: "wait" },
      { kind: "button", name: "home", label: "home" },
      { kind: "tap", x: 0.48, y: 0.28, app: "Safari", label: "Safari" },
      { kind: "type", text: "mirrorue.dev", target: "url", x: 0.5, y: 0.12, label: "type" },
      { kind: "tap", x: 0.5, y: 0.62, action: "cta", label: "Download" },
      { kind: "button", name: "home", label: "home" },
    ],
  };

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
        '<div class="urlbar"><span id="url-typed"></span></div>' +
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

  function setApiMode(mode) {
    if (!apiModeEl) return;
    apiModeEl.textContent = mode;
    apiModeEl.className = "api-mode";
    if (mode === "recording") apiModeEl.classList.add("recording");
    if (mode === "playing") apiModeEl.classList.add("playing");
  }

  function stepLabel(step) {
    return step.label || step.kind;
  }

  function renderWorkflowSteps(activeIndex) {
    if (!workflowStepsEl) return;
    workflowStepsEl.innerHTML = LOGIN_SMOKE.steps
      .map(function (s, i) {
        var cls = "wf-step";
        if (activeIndex >= 0 && i === activeIndex) cls += " active";
        else if (activeIndex >= 0 && i < activeIndex) cls += " done";
        return '<span class="' + cls + '">' + stepLabel(s) + "</span>";
      })
      .join("");
  }

  function apiLine(method, path, body, ok) {
    if (!apiFeed) return;
    var row = document.createElement("div");
    row.className = "api-line";
    row.innerHTML =
      '<span class="m">' +
      method +
      '</span><span class="p">' +
      path +
      "</span>" +
      (body ? '<span class="b">' + body + "</span>" : "") +
      '<span class="s">' +
      (ok === false ? "err" : "200") +
      "</span>";
    apiFeed.appendChild(row);
    while (apiFeed.children.length > 8) apiFeed.removeChild(apiFeed.firstChild);
    apiFeed.scrollTop = apiFeed.scrollHeight;
  }

  function resetPhone() {
    openAppName = null;
    appSheet.classList.remove("open");
    homeLayer.classList.remove("dimmed");
    appSheet.hidden = true;
    homeLayer.querySelectorAll(".app.pulse").forEach(function (el) {
      el.classList.remove("pulse");
    });
    if (isTouchUI) {
      cursor.hidden = true;
    } else {
      cursor.hidden = false;
      moveCursor(0.5, 0.45, false);
    }
  }

  function phoneScale() {
    var shell = document.querySelector(".phone-shell");
    if (!shell) return 1;
    var w = shell.getBoundingClientRect().width;
    return w > 0 ? w / 220 : 1;
  }

  function elCenter(el) {
    if (!el || !screen) return null;
    var sr = screen.getBoundingClientRect();
    if (!sr.width || !sr.height) return null;
    var r = el.getBoundingClientRect();
    return {
      x: Math.min(1, Math.max(0, (r.left + r.width / 2 - sr.left) / sr.width)),
      y: Math.min(1, Math.max(0, (r.top + r.height / 2 - sr.top) / sr.height)),
    };
  }

  function moveCursor(x, y, animate) {
    if (isTouchUI) return;
    cursor.hidden = false;
    if (animate && !reduceMotion) {
      cursor.style.transition =
        "left 0.45s cubic-bezier(0.22,1,0.36,1), top 0.45s cubic-bezier(0.22,1,0.36,1)";
    } else {
      cursor.style.transition = "none";
    }
    cursor.style.left = x * 100 + "%";
    cursor.style.top = y * 100 + "%";
    if (!userActive) setPhoneTilt(x, y);
  }

  function showRipple(x, y) {
    ripple.hidden = false;
    ripple.classList.remove("pop");
    ripple.style.left = x * 100 + "%";
    ripple.style.top = y * 100 + "%";
    void ripple.offsetWidth;
    ripple.classList.add("pop");
    if (!isTouchUI) {
      cursor.classList.add("down");
      setTimeout(function () {
        cursor.classList.remove("down");
      }, 120);
    }
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
    return {
      x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
      y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
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
    setApiMode("idle");
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
        setTimeout(step, reduceMotion ? 0 : 34);
      }
      step();
    });
  }

  async function autoTap(x, y, token) {
    if (token !== autoToken) return false;
    moveCursor(x, y, true);
    if (!(await wait(reduceMotion ? 60 : 420, token))) return false;
    showRipple(x, y);
    return wait(reduceMotion ? 40 : 180, token);
  }

  function stepApiLine(step) {
    if (step.kind === "tap") {
      apiLine(
        "POST",
        "/v1/tap",
        '{"x":' + step.x.toFixed(2) + ',"y":' + step.y.toFixed(2) + "}"
      );
    } else if (step.kind === "type") {
      apiLine("POST", "/v1/type", '{"text":"' + step.text + '"}');
    } else if (step.kind === "button") {
      apiLine("POST", "/v1/button", '{"name":"' + step.name + '"}');
    } else if (step.kind === "wait") {
      apiLine("POST", "/v1/wait", '{"ms":' + (step.ms || 300) + "}");
    }
  }

  async function executeStep(step, token) {
    if (token !== autoToken) return false;

    if (step.kind === "tap") {
      stepApiLine(step);
      if (step.app) {
        if (openAppName) closeApp(true);
        if (!(await wait(openAppName ? 0 : 120, token))) return false;
        var target = appCenter(step.app);
        if (!(await autoTap(target.x, target.y, token))) return false;
        if (target.el) {
          target.el.classList.add("pulse");
          setTimeout(function () {
            if (target.el) target.el.classList.remove("pulse");
          }, 320);
        }
        openApp(step.app, true);
      } else {
        var tapPt = { x: step.x, y: step.y };
        if (step.action === "cta") {
          var ctaEl = document.getElementById("web-cta");
          tapPt = elCenter(ctaEl) || tapPt;
        }
        if (!(await autoTap(tapPt.x, tapPt.y, token))) return false;
        if (step.action === "cta") {
          var cta = document.getElementById("web-cta");
          if (cta) cta.classList.add("pulse");
        }
      }
      return wait(reduceMotion ? 60 : 260, token);
    }

    if (step.kind === "type") {
      stepApiLine(step);
      await wait(reduceMotion ? 0 : 80, token);
      if (token !== autoToken) return false;
      var typeEl =
        step.target === "msg"
          ? document.querySelector(".composer") || document.getElementById("msg-typed")
          : document.querySelector(".mock-safari .urlbar") || document.getElementById("url-typed");
      var typePt = elCenter(typeEl) || { x: step.x || 0.55, y: step.y || 0.82 };
      moveCursor(typePt.x, typePt.y, true);
      var el =
        step.target === "msg"
          ? document.getElementById("msg-typed")
          : document.getElementById("url-typed");
      if (!(await typeInto(el, step.text, token))) return false;
      if (step.target === "msg") {
        var out = document.getElementById("msg-out");
        if (out) out.textContent = step.text;
      }
      return wait(reduceMotion ? 80 : 320, token);
    }

    if (step.kind === "button") {
      stepApiLine(step);
      var homePt = elCenter(document.getElementById("home-bar")) || { x: 0.5, y: 0.96 };
      moveCursor(homePt.x, homePt.y, true);
      if (!(await wait(reduceMotion ? 80 : 260, token))) return false;
      showRipple(homePt.x, homePt.y);
      closeApp(true);
      return wait(reduceMotion ? 80 : 320, token);
    }

    if (step.kind === "wait") {
      stepApiLine(step);
      return wait(step.ms || 300, token);
    }

    return true;
  }

  function finishAuto(token) {
    autoRunning = false;
    return token === autoToken;
  }

  async function runPath(token, mode) {
    setApiMode(mode === "recording" ? "recording" : "playing");
    if (mode === "recording") {
      apiLine("POST", "/v1/workflows/record/start", "");
    } else {
      apiLine("POST", "/v1/workflows/play", '{"name":"login-smoke"}');
    }

    resetPhone();
    if (!(await wait(280, token))) return false;

    for (var i = 0; i < LOGIN_SMOKE.steps.length; i++) {
      renderWorkflowSteps(i);
      if (!(await executeStep(LOGIN_SMOKE.steps[i], token))) return false;
    }
    renderWorkflowSteps(LOGIN_SMOKE.steps.length);

    if (mode === "recording") {
      apiLine("POST", "/v1/workflows/record/stop", '{"name":"login-smoke"}');
      if (!(await wait(400, token))) return false;
    }
    return true;
  }

  async function startAutoDemo() {
    if (autoRunning || userActive || reduceMotion) return;
    autoRunning = true;
    var token = ++autoToken;
    if (apiFeed) apiFeed.innerHTML = "";
    resetPhone();
    renderWorkflowSteps(-1);
    setApiMode("idle");

    apiLine("GET", "/v1/workflows", '{"paths":["login-smoke"]}');
    if (!(await wait(400, token))) return finishAuto(token);

    if (!(await runPath(token, "playing"))) return finishAuto(token);

    apiLine("GET", "/v1/status", '{"fps":120,"hid":"up","path":"done"}');
    setApiMode("idle");
    moveCursor(0.5, 0.5, true);

    if (!finishAuto(token)) return;
    await wait(reduceMotion ? 400 : 2200, token);
    if (!userActive && token === autoToken) startAutoDemo();
  }

  // Manual interaction — desktop only; mobile is watch-only auto demo.
  var dragging = false;
  var startX = 0;
  var startY = 0;
  var moved = false;
  var interactTarget = phone;

  if (isTouchUI) {
    cursor.hidden = true;
    phone.style.transform = "";
  } else {
    interactTarget.addEventListener("pointerenter", function () {
      stage.classList.add("active");
    });

    interactTarget.addEventListener("pointerleave", function () {
      stage.classList.remove("active");
      if (!autoRunning) cursor.hidden = true;
      dragging = false;
    });

    interactTarget.addEventListener("pointermove", function (e) {
      if (autoRunning && !userActive) return;
      var pt = localPoint(e);
      moveCursor(pt.x, pt.y, false);
    });

    interactTarget.addEventListener("pointerdown", function (e) {
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
        interactTarget.setPointerCapture(e.pointerId);
      } catch (err) {}
    });

    interactTarget.addEventListener("pointerup", function (e) {
      cursor.classList.remove("down");
      var pt = localPoint(e);
      var dx = e.clientX - startX;
      var dy = e.clientY - startY;
      if (Math.abs(dx) > 10 || Math.abs(dy) > 10) moved = true;

      if (dragging && !moved) {
        handlePhoneTap(pt);
      }
      dragging = false;
    });

    interactTarget.addEventListener("pointercancel", function () {
      dragging = false;
      cursor.classList.remove("down");
    });
  }

  function handlePhoneTap(pt) {
      showRipple(pt.x, pt.y);
      if (openAppName && pt.y > 0.92) {
        closeApp(false);
      } else if (openAppName) {
        apiLine(
          "POST",
          "/v1/tap",
          '{"x":' + pt.x.toFixed(2) + ',"y":' + pt.y.toFixed(2) + "}"
        );
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

  if (appBack) {
    appBack.addEventListener("click", function (e) {
      if (isTouchUI) return;
      e.stopPropagation();
      markUser();
      closeApp(false);
    });
  }

  var homeBar = document.getElementById("home-bar");
  if (homeBar) {
    homeBar.addEventListener("click", function (e) {
      if (isTouchUI) return;
      e.stopPropagation();
      markUser();
      if (openAppName) closeApp(false);
    });
  }

  if (replayBtn) {
    replayBtn.addEventListener("click", function (e) {
      if (isTouchUI) return;
      e.stopPropagation();
      userActive = false;
      clearTimeout(userTimer);
      autoToken += 1;
      startAutoDemo();
    });
  }

  if (!reduceMotion && !isTouchUI) {
    var idle = 0;
    setInterval(function () {
      if (stage.classList.contains("active") || autoRunning) return;
      idle += 1;
      var bob = 3 * phoneScale();
      phone.style.transform =
        "rotateY(" +
        Math.sin(idle / 18) * 4 +
        "deg) translateY(" +
        Math.sin(idle / 12) * bob +
        "px)";
    }, 40);
  }

  var resizeTimer = null;
  function onViewportChange() {
    isTouchUI = applyTouchClass();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      if (userActive || reduceMotion) return;
      autoToken += 1;
      autoRunning = false;
      startAutoDemo();
    }, 350);
  }
  window.addEventListener("resize", onViewportChange);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", onViewportChange);
  }

  renderWorkflowSteps(-1);
  setTimeout(startAutoDemo, reduceMotion ? 0 : 900);
})();
