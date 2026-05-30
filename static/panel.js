const menuItems = document.querySelectorAll(".menu-item");
const pages = document.querySelectorAll(".page");
const tabs = document.querySelectorAll(".tab");
const tabContents = document.querySelectorAll(".tab-content");
const sidebar = document.getElementById("sidebar");
const hamburgerBtn = document.getElementById("hamburger-btn");
const mobileOverlay = document.getElementById("mobile-overlay");

const scanStartBtn = document.getElementById("scan-start");
const scanStopBtn = document.getElementById("scan-stop");
const scanResumeBtn = document.getElementById("scan-resume");
const scanLogsEl = document.getElementById("scan-logs");
const scanAutoScrollEl = document.getElementById("scan-autoscroll");
const scanDomainEl = document.getElementById("scan-domain");
const scanTimeoutEl = document.getElementById("scan-timeout");
const scanCriterionEl = document.getElementById("scan-criterion");

const dnsStartBtn = document.getElementById("dns-start");
const dnsStopBtn = document.getElementById("dns-stop");
const dnsDownloadBtn = document.getElementById("dns-download");
const dnsDomainEl = document.getElementById("dns-domain");
const dnsTimeoutEl = document.getElementById("dns-timeout");
const dnsLogsEl = document.getElementById("dns-logs");
const dnsAutoScrollEl = document.getElementById("dns-autoscroll");

const resourceFileEl = document.getElementById("resource-csv-file");
const resourceUploadBtn = document.getElementById("resource-upload-csv");
const resourceUploadPauseBtn = document.getElementById("resource-upload-pause");
const resourceUploadCancelBtn = document.getElementById("resource-upload-cancel");
const resourceCidrsEl = document.getElementById("resource-cidrs");
const resourceSaveCidrsBtn = document.getElementById("resource-save-cidrs");
const resourceSummaryEl = document.getElementById("resource-summary");
const resourceFilesBodyEl = document.getElementById("resource-files-body");
const resourceSelectedFileEl = document.getElementById("resource-selected-file");
const resourceUploadProgressWrapEl = document.getElementById("resource-upload-progress-wrap");
const resourceUploadProgressBarEl = document.getElementById("resource-upload-progress-bar");
const resourceUploadProgressTextEl = document.getElementById("resource-upload-progress-text");
const resourceUploadWarningEl = document.getElementById("resource-upload-warning");
const resourceStatusTabAllBtn = document.getElementById("resource-status-tab-all");
const resourceStatusTabEnabledBtn = document.getElementById("resource-status-tab-enabled");
const resourceStatusTabDisabledBtn = document.getElementById("resource-status-tab-disabled");
const resourceTabFilesBtn = document.getElementById("resource-tab-files-btn");
const resourceTabExtractorBtn = document.getElementById("resource-tab-extractor-btn");
const resourceTabFilesEl = document.getElementById("resource-tab-files");
const resourceTabExtractorEl = document.getElementById("resource-tab-extractor");
const extractorTargetDirEl = document.getElementById("extractor-target-dir");
const extractorOutputFileEl = document.getElementById("extractor-output-file");
const extractorSettingsJsonEl = document.getElementById("extractor-settings-json");
const extractorSaveBtn = document.getElementById("extractor-save-btn");
const extractorResetBtn = document.getElementById("extractor-reset-btn");

const appModalEl = document.getElementById("app-modal");
const appModalCloseBtn = document.getElementById("app-modal-close");
const appModalCancelBtn = document.getElementById("app-modal-cancel");
const appModalConfirmBtn = document.getElementById("app-modal-confirm");
const appModalMessageEl = document.getElementById("app-modal-message");
const appVersionEl = document.getElementById("app-version");
const appRepositoryLinkEl = document.getElementById("app-repository-link");
const nativeAlert = window.alert.bind(window);

let lastModalFocusEl = null;
let extractorJsonEditorEl = null;
let resourceStatusFilter = "all";
const pendingResourceActions = new Set();
let lastResourceStatus = null;
let modalConfirmResolver = null;
let activeUploadState = null;

function showMessage(message) {
  if (!message) return;
  if (!appModalEl || !appModalMessageEl || !appModalCloseBtn) {
    nativeAlert(message);
    return;
  }
  lastModalFocusEl = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  appModalMessageEl.textContent = String(message);
  appModalCloseBtn.classList.remove("hidden");
  appModalCancelBtn?.classList.add("hidden");
  appModalConfirmBtn?.classList.add("hidden");
  appModalEl.classList.add("show");
  appModalEl.setAttribute("aria-hidden", "false");
  appModalCloseBtn.focus();
}

function resolveModalConfirm(value) {
  if (typeof modalConfirmResolver === "function") {
    const resolver = modalConfirmResolver;
    modalConfirmResolver = null;
    resolver(!!value);
  }
}

function showConfirm(message, confirmText = "تایید", cancelText = "انصراف") {
  if (!appModalEl || !appModalMessageEl || !appModalConfirmBtn || !appModalCancelBtn || !appModalCloseBtn) {
    return Promise.resolve(window.confirm(String(message || "")));
  }
  return new Promise((resolve) => {
    modalConfirmResolver = resolve;
    lastModalFocusEl = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    appModalMessageEl.textContent = String(message || "");
    appModalCloseBtn.classList.add("hidden");
    appModalCancelBtn.classList.remove("hidden");
    appModalConfirmBtn.classList.remove("hidden");
    appModalCancelBtn.textContent = cancelText;
    appModalConfirmBtn.textContent = confirmText;
    appModalEl.classList.add("show");
    appModalEl.setAttribute("aria-hidden", "false");
    appModalConfirmBtn.focus();
  });
}

function closeModal() {
  if (!appModalEl || !appModalCloseBtn) return;
  resolveModalConfirm(false);
  appModalEl.classList.remove("show");
  appModalEl.setAttribute("aria-hidden", "true");
  appModalCloseBtn.classList.remove("hidden");
  appModalCancelBtn?.classList.add("hidden");
  appModalConfirmBtn?.classList.add("hidden");
  if (lastModalFocusEl && typeof lastModalFocusEl.focus === "function") {
    lastModalFocusEl.focus();
  }
  lastModalFocusEl = null;
}

window.alert = (message) => {
  showMessage(message);
};

appModalCloseBtn?.addEventListener("click", closeModal);
appModalCancelBtn?.addEventListener("click", closeModal);
appModalConfirmBtn?.addEventListener("click", () => {
  resolveModalConfirm(true);
  closeModal();
});
appModalEl?.addEventListener("click", (event) => {
  if (event.target === appModalEl) closeModal();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && appModalEl?.classList.contains("show")) closeModal();
});

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function classifyLogLine(line) {
  const u = String(line || "").toUpperCase();
  if (u.includes("ERROR") || line.includes("خطا")) return "log-error";
  if (u.includes("CONFIRMED") || u.includes("RESULT=OK")) return "log-success";
  if (u.includes("REJECTED") || u.includes("FAILED") || line.includes("متوقف")) return "log-warn";
  return "log-info";
}

function renderLogs(container, lines, autoScrollEnabled) {
  const html = (lines || [])
    .map((line) => `<div class="log-line ${classifyLogLine(line)}">${escapeHtml(line)}</div>`)
    .join("");
  container.innerHTML = html;
  if (autoScrollEnabled) container.scrollTop = container.scrollHeight;
}

function isValidDomain(value) {
  const domain = (value || "").trim().replace(/\.$/, "");
  if (!domain) return false;
  const labels = domain.split(".");
  if (labels.some((label) => !label || label.length > 63)) return false;
  return labels.every((label) => /^[a-zA-Z0-9-]+$/.test(label) && !label.startsWith("-") && !label.endsWith("-"));
}

function parseIpv4Cidr(rawValue) {
  const value = (rawValue || "").trim();
  const match = value.match(/^(\d{1,3})(?:\.(\d{1,3})){3}\/([0-9]|[12][0-9]|3[0-2])$/);
  if (!match) return null;
  const [ipPart, prefixPart] = value.split("/");
  const octets = ipPart.split(".").map(Number);
  if (octets.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return null;
  const prefix = Number(prefixPart);
  if (prefix < 0 || prefix > 32) return null;
  return `${octets.join(".")}/${prefix}`;
}

function validateManualCidrs(rawText) {
  const values = (rawText || "").replace(/,/g, "\n").split(/\r?\n/).map((v) => v.trim()).filter(Boolean);
  const invalid = [];
  for (const value of values) {
    if (!parseIpv4Cidr(value)) invalid.push(value);
  }
  return { values, invalid };
}

function activatePage(id) {
  pages.forEach((p) => p.classList.toggle("active", p.id === id));
  menuItems.forEach((m) => m.classList.toggle("active", m.dataset.page === id));
  closeMobileMenu();
}

function activateTab(id) {
  tabContents.forEach((t) => t.classList.toggle("active", t.id === id));
  tabs.forEach((b) => b.classList.toggle("active", b.dataset.tab === id));
}

function activateResourceTab(tabId) {
  const isFiles = tabId === "files";
  resourceTabFilesEl?.classList.toggle("active", isFiles);
  resourceTabExtractorEl?.classList.toggle("active", !isFiles);
  resourceTabFilesBtn?.classList.toggle("active", isFiles);
  resourceTabExtractorBtn?.classList.toggle("active", !isFiles);
}

function activateResourceStatusTab(tabId) {
  resourceStatusFilter = tabId;
  resourceStatusTabAllBtn?.classList.toggle("active", tabId === "all");
  resourceStatusTabEnabledBtn?.classList.toggle("active", tabId === "enabled");
  resourceStatusTabDisabledBtn?.classList.toggle("active", tabId === "disabled");
  if (lastResourceStatus) renderResourceStatus(lastResourceStatus);
}

function setUploadProgress(percent) {
  const value = Math.max(0, Math.min(100, Number(percent) || 0));
  if (resourceUploadProgressBarEl) resourceUploadProgressBarEl.style.width = `${value}%`;
  if (resourceUploadProgressTextEl) resourceUploadProgressTextEl.textContent = `${value.toFixed(1)}%`;
}

function setUploadProgressVisible(visible) {
  if (!resourceUploadProgressWrapEl) return;
  resourceUploadProgressWrapEl.classList.toggle("hidden", !visible);
}

function setUploadWarningVisible(visible) {
  if (!resourceUploadWarningEl) return;
  resourceUploadWarningEl.classList.toggle("hidden", !visible);
}

function setUploadActionButtonsVisible(visible) {
  resourceUploadPauseBtn?.classList.toggle("hidden", !visible);
  resourceUploadCancelBtn?.classList.toggle("hidden", !visible);
}

function setUploadPausedState(paused) {
  if (!resourceUploadPauseBtn) return;
  resourceUploadPauseBtn.textContent = paused ? "ادامه آپلود" : "توقف آپلود";
}

function isUploadRunning() {
  return !!(activeUploadState && !activeUploadState.done && !activeUploadState.canceled);
}

function sendUploadCancelBeacon() {
  if (!isUploadRunning()) return;
  const uploadId = String(activeUploadState?.uploadId || "");
  if (!uploadId) return;
  if (!navigator.sendBeacon) return;
  const formData = new FormData();
  formData.append("upload_id", uploadId);
  navigator.sendBeacon("/api/resources/upload-csv/cancel", formData);
}

menuItems.forEach((btn) => btn.addEventListener("click", () => activatePage(btn.dataset.page)));
tabs.forEach((btn) => btn.addEventListener("click", () => activateTab(btn.dataset.tab)));
resourceTabFilesBtn?.addEventListener("click", () => activateResourceTab("files"));
resourceTabExtractorBtn?.addEventListener("click", async () => {
  activateResourceTab("extractor");
  await refreshExtractorConfig();
});
resourceStatusTabAllBtn?.addEventListener("click", () => activateResourceStatusTab("all"));
resourceStatusTabEnabledBtn?.addEventListener("click", () => activateResourceStatusTab("enabled"));
resourceStatusTabDisabledBtn?.addEventListener("click", () => activateResourceStatusTab("disabled"));

function openMobileMenu() {
  if (!sidebar || !mobileOverlay) return;
  sidebar.classList.add("open");
  mobileOverlay.classList.add("show");
}

function closeMobileMenu() {
  if (!sidebar || !mobileOverlay) return;
  sidebar.classList.remove("open");
  mobileOverlay.classList.remove("show");
}

hamburgerBtn?.addEventListener("click", openMobileMenu);
mobileOverlay?.addEventListener("click", closeMobileMenu);
window.addEventListener("resize", () => {
  if (window.innerWidth > 520) closeMobileMenu();
});

async function parseResponse(res) {
  const text = await res.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch (_) {
    return {};
  }
}

async function postJson(url, payload = null, fetchOptions = {}) {
  const options = { method: "POST", headers: {} };
  if (payload !== null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(payload);
  }
  if (fetchOptions?.signal) options.signal = fetchOptions.signal;
  try {
    const res = await fetch(url, options);
    const data = await parseResponse(res);
    if (!res.ok) return { ok: false, message: data.message || `خطای شبکه (${res.status})` };
    return data;
  } catch (err) {
    if (err && err.name === "AbortError") {
      return { ok: false, aborted: true, message: "درخواست متوقف شد." };
    }
    return { ok: false, message: "ارتباط با سرور برقرار نشد." };
  }
}

async function postForm(url, formData, fetchOptions = {}) {
  const options = { method: "POST", body: formData };
  if (fetchOptions?.signal) options.signal = fetchOptions.signal;
  try {
    const res = await fetch(url, options);
    const data = await parseResponse(res);
    if (!res.ok) return { ok: false, message: data.message || `خطای شبکه (${res.status})` };
    return data;
  } catch (err) {
    if (err && err.name === "AbortError") {
      return { ok: false, aborted: true, message: "درخواست متوقف شد." };
    }
    return { ok: false, message: "ارتباط با سرور برقرار نشد." };
  }
}
scanStartBtn?.addEventListener("click", async () => {
  const query_domain = scanDomainEl?.value?.trim() || "";
  const timeout = scanTimeoutEl?.value?.trim() || "";
  const query_type = scanCriterionEl?.value || "A";
  if (!isValidDomain(query_domain)) return showMessage("دامنه مقصد معتبر نیست.");
  if (!timeout || Number(timeout) <= 0) return showMessage("Timeout باید بزرگ‌تر از صفر باشد.");
  if (!["A", "AAAA"].includes(query_type)) return showMessage("معیار اسکن نامعتبر است.");

  const result = await postJson("/api/scan/start", {
    query_domain,
    timeout: Number(timeout),
    query_type,
  });
  if (!result.ok) showMessage(result.message || "شروع اسکن ناموفق بود.");
});

scanStopBtn?.addEventListener("click", async () => {
  scanStopBtn.disabled = true;
  scanStopBtn.textContent = "درحال توقف...";
  const result = await postJson("/api/scan/stop");
  if (!result.ok) showMessage(result.message || "توقف اسکن ناموفق بود.");
});

scanResumeBtn?.addEventListener("click", async () => {
  const result = await postJson("/api/scan/resume");
  if (!result.ok) showMessage(result.message || "ادامه اسکن ناموفق بود.");
});

document.getElementById("scan-clear-logs")?.addEventListener("click", async () => {
  await postJson("/api/scan/logs/clear");
});

dnsStartBtn?.addEventListener("click", async () => {
  const domain = dnsDomainEl?.value?.trim() || null;
  const timeout = dnsTimeoutEl?.value ? Number(dnsTimeoutEl.value) : null;
  if (domain && !isValidDomain(domain)) return showMessage("دامنه تست DNS معتبر نیست.");
  if (timeout !== null && timeout <= 0) return showMessage("Timeout تست DNS باید بزرگ‌تر از صفر باشد.");
  const result = await postJson("/api/dns-test/start", { domain, timeout });
  if (!result.ok) showMessage(result.message || "شروع تست DNS ناموفق بود.");
});

dnsStopBtn?.addEventListener("click", async () => {
  dnsStopBtn.disabled = true;
  dnsStopBtn.textContent = "درحال توقف...";
  const result = await postJson("/api/dns-test/stop");
  if (!result.ok) showMessage(result.message || "توقف تست DNS ناموفق بود.");
});

dnsDownloadBtn?.addEventListener("click", () => {
  window.location.href = "/api/dns-test/download";
});

document.getElementById("dns-clear-logs")?.addEventListener("click", async () => {
  await postJson("/api/dns-test/logs/clear");
});

async function uploadSelectedCsv() {
  const file = resourceFileEl?.files?.[0];
  if (!file) return false;
  if (!file.name.toLowerCase().endsWith(".csv")) {
    showMessage("فقط فایل CSV قابل آپلود است.");
    return false;
  }
  if (activeUploadState && !activeUploadState.done) {
    showMessage("یک آپلود دیگر در حال انجام است.");
    return false;
  }

  const oldText = resourceUploadBtn?.textContent || "آپلود فایل";
  if (resourceUploadBtn) {
    resourceUploadBtn.disabled = true;
    resourceUploadBtn.textContent = "در حال آپلود...";
  }
  if (resourceFileEl) resourceFileEl.disabled = true;
  setUploadActionButtonsVisible(true);
  setUploadPausedState(false);
  if (resourceUploadPauseBtn) resourceUploadPauseBtn.disabled = false;
  if (resourceUploadCancelBtn) {
    resourceUploadCancelBtn.disabled = false;
    resourceUploadCancelBtn.textContent = "لغو آپلود";
  }
  setUploadProgressVisible(true);
  setUploadWarningVisible(true);
  setUploadProgress(0);

  const uploadState = {
    uploadId: "",
    paused: false,
    canceled: false,
    done: false,
    cancelMessage: "آپلود لغو شد.",
    controllers: new Set(),
  };
  activeUploadState = uploadState;

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const canceledError = "__UPLOAD_CANCELED__";

  const createTrackedController = () => {
    const controller = new AbortController();
    uploadState.controllers.add(controller);
    return controller;
  };
  const releaseTrackedController = (controller) => {
    uploadState.controllers.delete(controller);
  };
  const abortAllRequests = () => {
    for (const controller of Array.from(uploadState.controllers)) {
      try {
        controller.abort();
      } catch (_) {}
    }
    uploadState.controllers.clear();
  };

  try {
    const chunkSize = 1024 * 1024;
    const maxParallel = 4;
    const totalChunks = Math.ceil(file.size / chunkSize);

    const initController = createTrackedController();
    const initResult = await postJson(
      "/api/resources/upload-csv/init",
      {
        name: file.name,
        size: file.size,
        chunk_size: chunkSize,
      },
      { signal: initController.signal },
    );
    releaseTrackedController(initController);
    if (!initResult.ok) {
      showMessage(initResult.message || "شروع آپلود ناموفق بود.");
      return false;
    }

    uploadState.uploadId = initResult.upload_id;
    let nextChunkIndex = 0;

    async function uploadChunkWithRetry(chunkIndex, chunkBlob, maxRetries = 3) {
      for (let attempt = 1; attempt <= maxRetries; attempt += 1) {
        if (uploadState.canceled) return { ok: false, aborted: true, message: "آپلود لغو شد." };
        while (uploadState.paused && !uploadState.canceled) {
          await sleep(140);
        }
        if (uploadState.canceled) return { ok: false, aborted: true, message: "آپلود لغو شد." };

        const formData = new FormData();
        formData.append("upload_id", uploadState.uploadId);
        formData.append("chunk_index", String(chunkIndex));
        formData.append("chunk", chunkBlob, `chunk-${chunkIndex}.part`);

        const controller = createTrackedController();
        const result = await postForm("/api/resources/upload-csv/chunk", formData, { signal: controller.signal });
        releaseTrackedController(controller);

        if (result.ok) return result;
        if (result.aborted && uploadState.canceled) return result;
        if (attempt === maxRetries) return result;
        await sleep(300 * attempt);
      }
      return { ok: false, message: "آپلود chunk ناموفق بود." };
    }

    const runWorker = async () => {
      while (true) {
        if (uploadState.canceled) throw new Error(canceledError);
        while (uploadState.paused && !uploadState.canceled) {
          await sleep(140);
        }
        if (uploadState.canceled) throw new Error(canceledError);

        const chunkIndex = nextChunkIndex;
        nextChunkIndex += 1;
        if (chunkIndex >= totalChunks) return;

        const start = chunkIndex * chunkSize;
        const end = Math.min(start + chunkSize, file.size);
        const chunkBlob = file.slice(start, end);
        const chunkResult = await uploadChunkWithRetry(chunkIndex, chunkBlob);
        if (chunkResult.aborted && uploadState.canceled) {
          throw new Error(canceledError);
        }
        if (!chunkResult.ok) throw new Error(chunkResult.message || "آپلود chunk ناموفق بود.");

        if (typeof chunkResult.progress_percent === "number") {
          setUploadProgress(chunkResult.progress_percent);
        }
      }
    };

    const workerCount = Math.max(1, Math.min(maxParallel, totalChunks || 1));
    const workers = [];
    for (let i = 0; i < workerCount; i += 1) workers.push(runWorker());
    await Promise.all(workers);

    if (uploadState.canceled) throw new Error(canceledError);

    if (resourceUploadBtn) resourceUploadBtn.textContent = "در حال نهایی‌سازی...";
    const completeController = createTrackedController();
    const completeResult = await postJson(
      "/api/resources/upload-csv/complete",
      { upload_id: uploadState.uploadId },
      { signal: completeController.signal },
    );
    releaseTrackedController(completeController);

    if (completeResult.aborted && uploadState.canceled) {
      throw new Error(canceledError);
    }
    if (!completeResult.ok) {
      showMessage(completeResult.message || "تکمیل آپلود ناموفق بود.");
      activateResourceStatusTab("all");
      return false;
    }

    setUploadProgress(100);
    showMessage(completeResult.message || "آپلود فایل انجام شد.");
    activateResourceStatusTab("all");
    if (completeResult.status) {
      renderResourceStatus(completeResult.status);
    } else {
      refreshResources();
    }
    if (resourceFileEl) resourceFileEl.value = "";
    if (resourceSelectedFileEl) resourceSelectedFileEl.textContent = "هنوز فایلی انتخاب نشده است.";
    return true;
  } catch (err) {
    if (err instanceof Error && err.message === canceledError) {
      showMessage(uploadState.cancelMessage || "آپلود لغو شد.");
      return false;
    }
    showMessage(err instanceof Error ? err.message : "آپلود فایل ناموفق بود.");
    return false;
  } finally {
    uploadState.done = true;
    abortAllRequests();
    if (activeUploadState === uploadState) activeUploadState = null;
    if (resourceUploadBtn) {
      resourceUploadBtn.disabled = false;
      resourceUploadBtn.textContent = oldText;
    }
    if (resourceFileEl) resourceFileEl.disabled = false;
    if (resourceUploadPauseBtn) resourceUploadPauseBtn.disabled = true;
    if (resourceUploadCancelBtn) resourceUploadCancelBtn.disabled = true;
    setUploadActionButtonsVisible(false);
    setUploadWarningVisible(false);
    window.setTimeout(() => {
      setUploadProgressVisible(false);
      setUploadProgress(0);
    }, 800);
  }
}

resourceUploadBtn?.addEventListener("click", async () => {
  const hasFile = !!resourceFileEl?.files?.[0];
  if (!hasFile) {
    resourceFileEl?.click();
    return;
  }
  await uploadSelectedCsv();
});

resourceUploadPauseBtn?.addEventListener("click", () => {
  if (!activeUploadState || activeUploadState.done || activeUploadState.canceled) return;
  activeUploadState.paused = !activeUploadState.paused;
  setUploadPausedState(activeUploadState.paused);
});

resourceUploadCancelBtn?.addEventListener("click", async () => {
  if (!activeUploadState || activeUploadState.done || activeUploadState.canceled) return;
  const confirmed = await showConfirm("آپلود جاری لغو شود؟", "بله، لغو کن", "خیر");
  if (!confirmed) return;

  activeUploadState.canceled = true;
  activeUploadState.paused = false;
  setUploadPausedState(false);
  if (resourceUploadPauseBtn) resourceUploadPauseBtn.disabled = true;
  if (resourceUploadCancelBtn) {
    resourceUploadCancelBtn.disabled = true;
    resourceUploadCancelBtn.textContent = "در حال لغو...";
  }

  for (const controller of Array.from(activeUploadState.controllers || [])) {
    try {
      controller.abort();
    } catch (_) {}
  }

  if (activeUploadState.uploadId) {
    const cancelResult = await postJson("/api/resources/upload-csv/cancel", { upload_id: activeUploadState.uploadId });
    if (cancelResult?.message) activeUploadState.cancelMessage = cancelResult.message;
  }
});

window.addEventListener("beforeunload", (event) => {
  if (!isUploadRunning()) return;
  sendUploadCancelBeacon();
  event.preventDefault();
  event.returnValue = "";
});

window.addEventListener("pagehide", () => {
  if (!isUploadRunning()) return;
  sendUploadCancelBeacon();
});

resourceFileEl?.addEventListener("change", async () => {
  const file = resourceFileEl?.files?.[0];
  if (!resourceSelectedFileEl) return;
  if (!file) {
    resourceSelectedFileEl.textContent = "هنوز فایلی انتخاب نشده است.";
    return;
  }
  resourceSelectedFileEl.textContent = `${file.name} (${file.size.toLocaleString()} bytes)`;
});
resourceSaveCidrsBtn?.addEventListener("click", async () => {
  const cidrs_text = resourceCidrsEl?.value || "";
  const checked = validateManualCidrs(cidrs_text);
  if (checked.invalid.length > 0) {
    return showMessage(`CIDR نامعتبر: ${checked.invalid.slice(0, 8).join(", ")}${checked.invalid.length > 8 ? " ..." : ""}`);
  }
  const result = await postJson("/api/resources/manual-cidrs", { cidrs_text });
  showMessage(result.message || (result.ok ? "ذخیره شد." : "ذخیره ناموفق بود."));
  if (result.status) renderResourceStatus(result.status);
});

resourceFilesBodyEl?.addEventListener("click", async (event) => {
  const target = event.target;
  if (!(target instanceof HTMLElement)) return;
  if (!target.matches("button[data-file]")) return;
  const name = target.dataset.file;
  const action = target.dataset.action;
  if (!name) return;
  if (action === "delete") {
    const confirmed = await showConfirm(`از حذف فایل "${name}" مطمئن هستید؟`, "بله، حذف کن", "انصراف");
    if (!confirmed) return;
  }

  const actionKey = `${action}:${name}`;
  const oldText = target.textContent || "";
  pendingResourceActions.add(actionKey);
  target.disabled = true;
  if (action === "toggle") target.textContent = "درحال انجام...";

  try {
    let result = null;
    if (action === "delete") {
      result = await postJson("/api/resources/delete-csv", { name });
      showMessage(result.message || (result.ok ? "فایل حذف شد." : "حذف فایل ناموفق بود."));
    } else if (action === "toggle") {
      const currentEnabled = target.dataset.enabled === "true";
      result = await postJson("/api/resources/set-csv-enabled", { name, enabled: !currentEnabled });
      showMessage(result.message || (result.ok ? "وضعیت فایل تغییر کرد." : "تغییر وضعیت فایل ناموفق بود."));
    } else {
      return;
    }
    if (result.status) renderResourceStatus(result.status);
  } finally {
    pendingResourceActions.delete(actionKey);
    target.disabled = false;
    target.textContent = oldText;
  }
});

function showButton(btn, visible) {
  if (!btn) return;
  btn.style.display = visible ? "inline-block" : "none";
}

function updateScanButtons(actionMode, stopRequested) {
  if (!scanStartBtn || !scanStopBtn || !scanResumeBtn) return;
  if (actionMode === "running") {
    showButton(scanStartBtn, false);
    showButton(scanResumeBtn, false);
    showButton(scanStopBtn, true);
    scanStopBtn.disabled = !!stopRequested;
    scanStopBtn.textContent = stopRequested ? "درحال توقف..." : "توقف اسکن";
    return;
  }
  scanStopBtn.disabled = false;
  scanStopBtn.textContent = "توقف اسکن";
  if (actionMode === "resumable") {
    showButton(scanStartBtn, true);
    showButton(scanResumeBtn, true);
    showButton(scanStopBtn, false);
    scanStartBtn.textContent = "شروع اسکن از اول";
    scanResumeBtn.textContent = "ادامه اسکن";
    return;
  }
  if (actionMode === "restart_only") {
    showButton(scanStartBtn, true);
    showButton(scanResumeBtn, false);
    showButton(scanStopBtn, false);
    scanStartBtn.textContent = "شروع اسکن از اول";
    return;
  }
  showButton(scanStartBtn, true);
  showButton(scanResumeBtn, false);
  showButton(scanStopBtn, false);
  scanStartBtn.textContent = "شروع اسکن";
}

function renderScanStatus(data) {
  document.getElementById("scan-state").textContent = data.state;
  document.getElementById("scan-total").textContent = data.total;
  document.getElementById("scan-scanned").textContent = data.scanned;
  document.getElementById("scan-confirmed").textContent = data.confirmed;
  document.getElementById("scan-rejected").textContent = data.rejected;
  document.getElementById("scan-progress-bar").style.width = `${data.progress_percent}%`;
  document.getElementById("scan-progress-text").textContent = `${data.progress_percent}%`;
  renderLogs(scanLogsEl, data.logs, !!scanAutoScrollEl?.checked);
  updateScanButtons(data.action_mode, data.stop_requested);

  if (scanDomainEl && !scanDomainEl.matches(":focus")) scanDomainEl.value = data.query_domain ?? "";
  if (scanTimeoutEl && !scanTimeoutEl.matches(":focus")) scanTimeoutEl.value = data.timeout ?? "";
  if (scanCriterionEl && !scanCriterionEl.matches(":focus") && data.query_type) scanCriterionEl.value = data.query_type;
}

function resolveDnsMetricClass(row) {
  if (row.ok === false) return "dns-metric-bad";
  if (row.ok !== true) return "dns-metric-warn";
  const latency = Number(row.latency_ms);
  if (!Number.isFinite(latency)) return "dns-metric-warn";
  if (latency <= 80) return "dns-metric-good";
  if (latency <= 220) return "dns-metric-warn";
  return "dns-metric-bad";
}

function renderDnsStatus(data) {
  const tbody = document.getElementById("dns-results-body");
  tbody.innerHTML = "";
  for (const row of data.results || []) {
    const tr = document.createElement("tr");
    const metricClass = resolveDnsMetricClass(row);
    let statusText = "تست نشده";
    if (row.ok === true) statusText = "موفق";
    if (row.ok === false) statusText = "ناموفق";
    tr.innerHTML = `
      <td>${escapeHtml(row.ip ?? "")}</td>
      <td class="${metricClass}">${statusText}</td>
      <td class="${metricClass}">${row.latency_ms ?? "-"}</td>
    `;
    tbody.appendChild(tr);
  }

  renderLogs(dnsLogsEl, data.logs, !!dnsAutoScrollEl?.checked);
  if (dnsDomainEl && !dnsDomainEl.matches(":focus")) dnsDomainEl.value = data.query_domain ?? "";
  if (dnsTimeoutEl && !dnsTimeoutEl.matches(":focus")) dnsTimeoutEl.value = data.timeout ?? "";

  const isRunning = data.state === "running";
  showButton(dnsStartBtn, !isRunning);
  showButton(dnsDownloadBtn, !isRunning);
  showButton(dnsStopBtn, isRunning);
  if (dnsStopBtn) {
    dnsStopBtn.disabled = !!data.stop_requested;
    dnsStopBtn.textContent = data.stop_requested ? "درحال توقف..." : "■ توقف تست";
  }
  if (dnsStartBtn) dnsStartBtn.textContent = "▶ شروع تست";
}

function renderResourceStatus(data) {
  if (!data) return;
  lastResourceStatus = data;
  const files = Array.isArray(data.files) ? data.files : [];
  const manual = Array.isArray(data.manual_cidrs) ? data.manual_cidrs : [];

  if (resourceSummaryEl) {
    resourceSummaryEl.textContent =
      `کل CIDR فعال: ${data.total_cidrs ?? 0} | ` +
      `فایل فعال: ${data.enabled_csv_count ?? 0} | ` +
      `فایل غیرفعال: ${data.disabled_csv_count ?? 0}`;
  }
  if (resourceCidrsEl && !resourceCidrsEl.matches(":focus")) {
    resourceCidrsEl.value = manual.join("\n");
  }
  if (!resourceFilesBodyEl) return;

  const filteredFiles = files.filter((file) => {
    if (resourceStatusFilter === "enabled") return file.enabled !== false;
    if (resourceStatusFilter === "disabled") return file.enabled === false;
    return true;
  });

  resourceFilesBodyEl.innerHTML = "";
  if (!filteredFiles.length) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td colspan="5">فایلی برای این فیلتر وجود ندارد.</td>`;
    resourceFilesBodyEl.appendChild(tr);
    return;
  }

  for (const file of filteredFiles) {
    const tr = document.createElement("tr");
    const enabled = file.enabled !== false;
    tr.innerHTML = `
      <td>${escapeHtml(file.name ?? "")}</td>
      <td>${enabled ? "فعال" : "غیرفعال"}</td>
      <td>${file.cidr_count ?? 0}</td>
      <td>${file.size ?? 0}</td>
      <td></td>
    `;

    const actionTd = tr.lastElementChild;
    const canToggle = file.can_toggle !== false;
    const canDelete = file.can_delete === true;
    if (!canToggle && !canDelete) {
      actionTd.textContent = "-";
    } else {
      if (canToggle) {
        const toggleBtn = document.createElement("button");
        toggleBtn.className = "ghost";
        toggleBtn.dataset.file = file.name ?? "";
        toggleBtn.dataset.action = "toggle";
        toggleBtn.dataset.enabled = enabled ? "true" : "false";
        const isPending = pendingResourceActions.has(`toggle:${file.name ?? ""}`);
        toggleBtn.disabled = isPending;
        toggleBtn.textContent = isPending ? "درحال انجام..." : (enabled ? "غیرفعال کردن" : "فعال کردن");
        actionTd.appendChild(toggleBtn);
      }
      if (canDelete) {
        const deleteBtn = document.createElement("button");
        deleteBtn.className = "warn";
        deleteBtn.dataset.file = file.name ?? "";
        deleteBtn.dataset.action = "delete";
        const deletePending = pendingResourceActions.has(`delete:${file.name ?? ""}`);
        deleteBtn.disabled = deletePending;
        deleteBtn.textContent = deletePending ? "درحال حذف..." : "حذف";
        actionTd.appendChild(deleteBtn);
      }
    }
    resourceFilesBodyEl.appendChild(tr);
  }
}
function tryParseStructuredJson(value) {
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === "object") return parsed;
  } catch (_) {}
  return null;
}

function escapeHtmlForJson(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function highlightJsonText(raw) {
  let json = escapeHtmlForJson(raw);
  json = json.replace(/"([^"\n]+)"\s*:/g, '<span class="json-key">"$1"</span>:');
  json = json.replace(
    /:\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)/g,
    ': <span class="json-value">$1</span>',
  );
  return json;
}

function getCaretOffset(el) {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return 0;
  const range = sel.getRangeAt(0);
  const pre = range.cloneRange();
  pre.selectNodeContents(el);
  pre.setEnd(range.endContainer, range.endOffset);
  return pre.toString().length;
}

function setCaretOffset(el, offset) {
  const sel = window.getSelection();
  if (!sel) return;
  const range = document.createRange();
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
    acceptNode(node) {
      if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
      if (node.nodeName === "BR") return NodeFilter.FILTER_ACCEPT;
      return NodeFilter.FILTER_SKIP;
    },
  });
  let count = 0;
  let node = walker.nextNode();
  while (node) {
    const len = node.nodeType === Node.TEXT_NODE ? node.textContent.length : 1;
    const next = count + len;
    if (offset <= next) {
      if (node.nodeType === Node.TEXT_NODE) {
        range.setStart(node, Math.max(0, offset - count));
      } else {
        const parent = node.parentNode;
        const index = Array.prototype.indexOf.call(parent.childNodes, node);
        range.setStart(parent, index + 1);
      }
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
      return;
    }
    count = next;
    node = walker.nextNode();
  }
  range.selectNodeContents(el);
  range.collapse(false);
  sel.removeAllRanges();
  sel.addRange(range);
}

function insertTextAtCursor(text) {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return;
  const range = sel.getRangeAt(0);
  range.deleteContents();
  const node = document.createTextNode(text);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  sel.removeAllRanges();
  sel.addRange(range);
}

function getLineMeta(raw, caret) {
  const lineStart = raw.lastIndexOf("\n", Math.max(0, caret - 1)) + 1;
  const lineEndIndex = raw.indexOf("\n", caret);
  const lineEnd = lineEndIndex === -1 ? raw.length : lineEndIndex;
  const line = raw.slice(lineStart, lineEnd);
  return { lineStart, lineTrimmedEnd: line.replace(/\s+$/, "") };
}

function shouldAutoAppendComma(lineTrimmedEnd) {
  if (!lineTrimmedEnd) return false;
  if (lineTrimmedEnd.endsWith(",")) return false;
  return /^\s*"[^"\n]+"\s*:/.test(lineTrimmedEnd);
}

function appendCommaToCurrentLine(raw, caret) {
  if (!extractorJsonEditorEl) return caret;
  const meta = getLineMeta(raw, caret);
  if (!shouldAutoAppendComma(meta.lineTrimmedEnd)) return caret;
  const commaOffset = meta.lineStart + meta.lineTrimmedEnd.length;
  setCaretOffset(extractorJsonEditorEl, commaOffset);
  insertTextAtCursor(",");
  return caret >= commaOffset ? caret + 1 : caret;
}

function buildIndentedNewline(raw, caret) {
  const before = raw.slice(0, caret);
  const after = raw.slice(caret);
  const lineStart = before.lastIndexOf("\n") + 1;
  const line = before.slice(lineStart);
  const baseIndent = (line.match(/^\s*/) || [""])[0];
  const trimmedBefore = before.trimEnd();
  const opensBlock = /[\{\[]$/.test(trimmedBefore);
  const nextMeaningful = after.trimStart()[0] || "";
  const closesBlock = nextMeaningful === "}" || nextMeaningful === "]";
  const indentUnit = "  ";
  if (opensBlock && closesBlock) return `\n${baseIndent}${indentUnit}\n${baseIndent}`;
  const afterTrimmedStart = after.replace(/^\s+/, "");
  const splitAfterColonSpace = /:\s*$/.test(line);
  const startsWithJsonValue = /^(?:"|\{|\[|-?\d|true|false|null)/.test(afterTrimmedStart);
  if (splitAfterColonSpace && startsWithJsonValue) return `\n${baseIndent}  `;
  return `\n${baseIndent}${opensBlock ? indentUnit : ""}`;
}

function repaintJsonEditor(editorEl) {
  const raw = editorEl.innerText.replace(/\r/g, "");
  const caret = getCaretOffset(editorEl);
  editorEl.innerHTML = highlightJsonText(raw);
  setCaretOffset(editorEl, caret);
}

function setExtractorEditorText(rawText) {
  if (!extractorSettingsJsonEl) return;
  if (!extractorJsonEditorEl) {
    extractorSettingsJsonEl.value = rawText;
    return;
  }
  const parsed = tryParseStructuredJson(rawText);
  if (parsed !== null) {
    extractorJsonEditorEl.innerHTML = highlightJsonText(JSON.stringify(parsed, null, 2));
  } else {
    extractorJsonEditorEl.textContent = rawText;
  }
  extractorSettingsJsonEl.value = rawText;
}

function getExtractorEditorText() {
  if (extractorJsonEditorEl) return extractorJsonEditorEl.innerText.replace(/\r/g, "");
  return extractorSettingsJsonEl?.value || "";
}

function initExtractorJsonEditor() {
  if (!extractorSettingsJsonEl || extractorJsonEditorEl) return;
  extractorSettingsJsonEl.style.display = "none";
  const editor = document.createElement("div");
  editor.id = "extractor-settings-editor";
  editor.className = "json-editor";
  editor.contentEditable = "true";
  editor.spellcheck = false;
  extractorSettingsJsonEl.insertAdjacentElement("afterend", editor);
  extractorJsonEditorEl = editor;
  editor.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    const rawBefore = editor.innerText.replace(/\r/g, "");
    const caretBefore = getCaretOffset(editor);
    const caretAfterComma = appendCommaToCurrentLine(rawBefore, caretBefore);
    const raw = editor.innerText.replace(/\r/g, "");
    insertTextAtCursor(buildIndentedNewline(raw, caretAfterComma));
    extractorSettingsJsonEl.value = editor.innerText.replace(/\r/g, "");
  });
  editor.addEventListener("input", (event) => {
    if (event.inputType === "historyUndo" || event.inputType === "historyRedo") {
      extractorSettingsJsonEl.value = editor.innerText.replace(/\r/g, "");
      return;
    }
    const raw = editor.innerText.replace(/\r/g, "");
    if (tryParseStructuredJson(raw) !== null) repaintJsonEditor(editor);
    extractorSettingsJsonEl.value = editor.innerText.replace(/\r/g, "");
  });
}

function renderExtractorConfig(data) {
  if (!data) return;
  if (extractorTargetDirEl) extractorTargetDirEl.value = data.target_directory ?? "";
  if (extractorOutputFileEl) extractorOutputFileEl.value = data.output_file ?? "";
  const editorFocused = !!(extractorJsonEditorEl && extractorJsonEditorEl.matches(":focus"));
  if (extractorSettingsJsonEl && !editorFocused) {
    const settings = data.settings ?? { csv_read_options: {}, default_rule: {}, file_rules: [] };
    setExtractorEditorText(JSON.stringify(settings, null, 2));
  }
}

async function refreshExtractorConfig() {
  try {
    const res = await fetch("/api/resources/extractor-config");
    if (!res.ok) return false;
    const payload = await res.json();
    if (!payload.ok) return false;
    renderExtractorConfig(payload);
    return true;
  } catch (_) {
    return false;
  }
}

extractorSaveBtn?.addEventListener("click", async () => {
  if (!extractorSettingsJsonEl) return;
  let parsedSettings = null;
  try {
    parsedSettings = JSON.parse(getExtractorEditorText() || "{}");
  } catch (_) {
    showMessage("JSON تنظیمات استخراج نامعتبر است.");
    return;
  }
  const result = await postJson("/api/resources/extractor-config", { settings: parsedSettings });
  if (!result.ok) return showMessage(result.message || "ذخیره تنظیمات استخراج ناموفق بود.");
  showMessage(result.message || "تنظیمات استخراج ذخیره شد.");
  if (result.config) renderExtractorConfig(result.config);
});

extractorResetBtn?.addEventListener("click", async () => {
  const ok = await refreshExtractorConfig();
  showMessage(ok ? "تنظیمات استخراج دوباره بارگذاری شد." : "بارگذاری تنظیمات استخراج ناموفق بود.");
});

async function refreshResources() {
  try {
    const res = await fetch("/api/resources/status");
    if (!res.ok) return;
    renderResourceStatus(await res.json());
  } catch (_) {}
}

async function refreshAppInfo() {
  try {
    const res = await fetch("/api/app/info");
    if (!res.ok) return;
    const payload = await res.json();
    if (!payload?.ok) return;
    if (appVersionEl) appVersionEl.textContent = `Version: ${payload.version || "2.0.0-beta"}`;
    if (appRepositoryLinkEl && payload.repository) {
      appRepositoryLinkEl.href = payload.repository;
      appRepositoryLinkEl.textContent = payload.repository;
    }
    if (payload.version) document.title = `DNS Scout ${payload.version}`;
  } catch (_) {}
}

async function refresh() {
  try {
    const [scanRes, dnsRes] = await Promise.all([fetch("/api/scan/status"), fetch("/api/dns-test/status")]);
    if (scanRes.ok) renderScanStatus(await scanRes.json());
    if (dnsRes.ok) renderDnsStatus(await dnsRes.json());
  } catch (_) {}
}

setInterval(refresh, 1200);
setInterval(refreshResources, 4000);
updateScanButtons("never_started", false);
initExtractorJsonEditor();
activateResourceTab("files");
activateResourceStatusTab("all");
setUploadProgressVisible(false);
setUploadWarningVisible(false);
setUploadActionButtonsVisible(false);
refresh();
refreshResources();
refreshExtractorConfig();
refreshAppInfo();





