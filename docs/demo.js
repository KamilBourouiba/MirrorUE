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
    cursor.hidden = true;
  }

  var cachedPhoneScale = 1;
  function updatePhoneScale() {
    var shell = document.querySelector(".phone-shell");
    if (!shell) return 1;
    var w = shell.offsetWidth || 220;
    cachedPhoneScale = w > 0 ? w / 220 : 1;
    return cachedPhoneScale;
  }
  function phoneScale() {
    return cachedPhoneScale || 1;
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
    /* watch-only demo — ripples only, no pointer cursor */
  }

  function showRipple(x, y) {
    ripple.hidden = false;
    ripple.classList.remove("pop");
    ripple.style.left = x * 100 + "%";
    ripple.style.top = y * 100 + "%";
    void ripple.offsetWidth;
    ripple.classList.add("pop");
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
      var homePt = { x: 0.5, y: 0.93 };
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
    if (autoRunning) return;
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
    if (token === autoToken) startAutoDemo();
  }

  cursor.hidden = true;
  phone.style.transform = "";

  if (!reduceMotion) {
    var idle = 0;
    setInterval(function () {
      if (autoRunning) return;
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
  var lastShellWidth = 0;

  function shellWidth() {
    var shell = document.querySelector(".phone-shell");
    return shell ? Math.round(shell.getBoundingClientRect().width) : 0;
  }

  function bootDemo() {
    if (autoRunning) return;
    updatePhoneScale();
    lastShellWidth = shellWidth();
    startAutoDemo();
  }

  function onViewportChange() {
    isTouchUI = applyTouchClass();
    updatePhoneScale();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      var w = shellWidth();
      if (Math.abs(w - lastShellWidth) < 10) return;
      lastShellWidth = w;
      autoToken += 1;
      autoRunning = false;
      startAutoDemo();
    }, 600);
  }

  window.addEventListener("resize", onViewportChange);
  window.addEventListener("orientationchange", onViewportChange);
  window.addEventListener("pageshow", function (e) {
    if (e.persisted) bootDemo();
  });

  renderWorkflowSteps(-1);

  if ("IntersectionObserver" in window && stage) {
    var demoBooted = false;
    var demoObserver = new IntersectionObserver(
      function (entries) {
        if (demoBooted || !entries[0].isIntersecting) return;
        demoBooted = true;
        demoObserver.disconnect();
        setTimeout(bootDemo, reduceMotion ? 0 : 400);
      },
      { threshold: 0.15, rootMargin: "0px 0px -5% 0px" }
    );
    demoObserver.observe(stage);
    setTimeout(function () {
      if (!demoBooted && shellWidth() > 0) {
        demoBooted = true;
        demoObserver.disconnect();
        bootDemo();
      }
    }, 2500);
  } else {
    setTimeout(bootDemo, reduceMotion ? 0 : 900);
  }
})();
