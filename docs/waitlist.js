(function () {
  "use strict";

  const STORAGE_KEY = "mirrorue_waitlist_v1";
  const cfg = window.MirrorUEWaitlist || {};

  const forms = document.querySelectorAll("[data-waitlist-form]");
  const triggers = document.querySelectorAll("[data-waitlist-open]");
  const dialog = document.getElementById("waitlist-dialog");

  function $(sel, root) {
    return (root || document).querySelector(sel);
  }

  function readJoined() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
    } catch {
      return null;
    }
  }

  function writeJoined(entry) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entry));
  }

  function validEmail(value) {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || "").trim());
  }

  function provider() {
    return (cfg.provider || "github-issue").toLowerCase();
  }

  function buildPayload(form) {
    const fd = new FormData(form);
    return {
      email: String(fd.get("email") || "").trim().toLowerCase(),
      plan: String(fd.get("plan") || "pro").trim(),
      company: String(fd.get("company") || "").trim(),
      note: String(fd.get("note") || "").trim(),
      source: form.dataset.source || "site",
      honeypot: String(fd.get("website") || "").trim(),
    };
  }

  function setFormState(form, state, message) {
    const status = $(`[data-waitlist-status="${form.id}"]`, form);
    const submit = form.querySelector('[type="submit"]');
    if (status) {
      status.dataset.state = state;
      status.textContent = message || "";
      status.hidden = !message;
    }
    if (submit) {
      submit.disabled = state === "loading";
      submit.setAttribute("aria-busy", state === "loading" ? "true" : "false");
    }
    form.dataset.state = state;
  }

  function markJoinedUI() {
    document.querySelectorAll("[data-waitlist-open]").forEach((btn) => {
      btn.textContent = "On the waitlist ✓";
      btn.setAttribute("aria-disabled", "true");
    });
  }

  function showSuccess(form, email, plan, message) {
    writeJoined({ email, plan, at: new Date().toISOString() });
    setFormState(
      form,
      "success",
      message || "You're on the list — we'll email you when Pro opens."
    );
    form.querySelectorAll("input:not([type=hidden]), textarea, select, button[type=submit]").forEach((el) => {
      el.disabled = true;
    });
    markJoinedUI();
  }

  async function postWeb3Forms(payload) {
    const key = (cfg.web3formsAccessKey || "").trim();
    if (!key) throw new Error("Web3Forms access key not configured");

    const res = await fetch("https://api.web3forms.com/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({
        access_key: key,
        subject: `MirrorUE waitlist · ${payload.plan}`,
        from_name: "MirrorUE Waitlist",
        email: payload.email,
        plan: payload.plan,
        company: payload.company || "(none)",
        message: payload.note || "(none)",
        source: payload.source,
      }),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.success) {
      throw new Error(data.message || "Could not submit — try again in a moment.");
    }
  }

  async function postFormSubmit(payload) {
    const to = (cfg.notifyEmail || cfg.fallbackMailto || "").trim();
    if (!to) throw new Error("Set notifyEmail in waitlist-config.js");

    const res = await fetch(`https://formsubmit.co/ajax/${encodeURIComponent(to)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({
        email: payload.email,
        plan: payload.plan,
        company: payload.company || "(none)",
        message: payload.note || "(none)",
        source: payload.source,
        _subject: `MirrorUE waitlist · ${payload.plan}`,
        _template: "table",
        _captcha: "false",
        _honey: "",
      }),
    });

    const data = await res.json().catch(() => ({}));
    const msg = data.message || "";
    if (!res.ok || data.success === "false") {
      throw new Error(msg || "Could not submit — try again in a moment.");
    }
  }

  async function postCustom(url, payload) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ ...payload, createdAt: new Date().toISOString(), page: location.href }),
    });
    if (!res.ok) throw new Error("Submission failed");
  }

  function githubIssueUrl(payload) {
    const gh = cfg.githubIssue || {};
    const owner = gh.owner || "KamilBourouiba";
    const repo = gh.repo || "MirrorUE";

    const body = [
      "### Waitlist signup",
      "",
      "### Email",
      payload.email,
      "",
      "### Plan",
      payload.plan,
      "",
      "### Company",
      payload.company || "",
      "",
      "### Note",
      payload.note || "",
      "",
      "### Source",
      payload.source,
    ].join("\n");

    const title = encodeURIComponent(`[Waitlist] ${payload.email}`);
    const labels = encodeURIComponent("waitlist");
    return `https://github.com/${owner}/${repo}/issues/new?title=${title}&body=${encodeURIComponent(body)}&labels=${labels}`;
  }

  function mailtoFallback(payload) {
    const to = cfg.fallbackMailto || cfg.contactEmail || "kbourouiba@icloud.com";
    const subject = encodeURIComponent(`MirrorUE ${payload.plan} waitlist`);
    const body = encodeURIComponent(
      [
        `Email: ${payload.email}`,
        `Plan: ${payload.plan}`,
        payload.company ? `Company: ${payload.company}` : "",
        payload.note ? `Note: ${payload.note}` : "",
        `Source: ${payload.source}`,
      ]
        .filter(Boolean)
        .join("\n")
    );
    location.href = `mailto:${to}?subject=${subject}&body=${body}`;
  }

  async function submit(form) {
    const payload = buildPayload(form);

    if (payload.honeypot) return;
    if (!validEmail(payload.email)) {
      setFormState(form, "error", "Enter a valid email address.");
      return;
    }

    const joined = readJoined();
    if (joined && joined.email === payload.email) {
      showSuccess(form, payload.email, payload.plan);
      return;
    }

    setFormState(form, "loading", "Joining…");

    const mode = provider();
    try {
      if (mode === "github-issue") {
        window.open(githubIssueUrl(payload), "_blank", "noopener,noreferrer");
        showSuccess(
          form,
          payload.email,
          payload.plan,
          "One more step — in the GitHub tab, click Submit new issue (free account). We'll email you at launch."
        );
        return;
      }

      if (mode === "web3forms") {
        if (!cfg.web3formsAccessKey) {
          window.open(githubIssueUrl(payload), "_blank", "noopener,noreferrer");
          showSuccess(
            form,
            payload.email,
            payload.plan,
            "Confirm in the GitHub tab — click Submit new issue to finish."
          );
          return;
        }
        await postWeb3Forms(payload);
      } else if (mode === "custom" && cfg.customEndpoint) {
        await postCustom(cfg.customEndpoint.trim(), payload);
      } else if (mode === "formsubmit") {
        await postFormSubmit(payload);
      } else {
        mailtoFallback(payload);
        showSuccess(form, payload.email, payload.plan);
        return;
      }

      showSuccess(form, payload.email, payload.plan);
    } catch (err) {
      window.open(githubIssueUrl(payload), "_blank", "noopener,noreferrer");
      showSuccess(
        form,
        payload.email,
        payload.plan,
        "We opened GitHub as a backup — click Submit new issue to confirm your spot."
      );
    }
  }

  function prefillForm(form, plan) {
    const planInput = form.querySelector('[name="plan"]');
    if (planInput && plan) planInput.value = plan;
    const joined = readJoined();
    if (joined?.email) {
      const emailInput = form.querySelector('[name="email"]');
      if (emailInput) emailInput.value = joined.email;
      if (joined.at) showSuccess(form, joined.email, joined.plan || "pro");
    }
  }

  function openDialog(plan) {
    if (!dialog) return;
    dialog.hidden = false;
    dialog.setAttribute("aria-hidden", "false");
    document.body.classList.add("waitlist-open");
    const form = $("#waitlist-dialog-form");
    if (form) {
      prefillForm(form, plan || "pro");
      const email = form.querySelector('[name="email"]');
      if (email && !email.disabled) email.focus();
    }
  }

  function closeDialog() {
    if (!dialog) return;
    dialog.hidden = true;
    dialog.setAttribute("aria-hidden", "true");
    document.body.classList.remove("waitlist-open");
  }

  forms.forEach((form) => {
    prefillForm(form, form.dataset.defaultPlan || "pro");
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      submit(form);
    });
  });

  triggers.forEach((btn) => {
    btn.addEventListener("click", (e) => {
      if (btn.getAttribute("aria-disabled") === "true") {
        e.preventDefault();
        return;
      }
      const href = btn.getAttribute("href") || "";
      if (href === "#waitlist" || href.endsWith("#waitlist")) return;
      if (dialog) {
        e.preventDefault();
        openDialog(btn.dataset.plan || "pro");
      }
    });
  });

  dialog?.querySelectorAll("[data-waitlist-close]").forEach((el) => {
    el.addEventListener("click", closeDialog);
  });

  dialog?.addEventListener("click", (e) => {
    if (e.target.matches("[data-waitlist-close], .waitlist-backdrop")) closeDialog();
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && dialog && !dialog.hidden) closeDialog();
  });

  if (readJoined()?.email) markJoinedUI();
})();
