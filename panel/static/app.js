/*
 * MacCmsWall 前端逻辑。
 * 负责：
 * 1. 调用插件后端 API。
 * 2. 渲染 Dashboard、网站管理、日志页面。
 * 3. 处理防护开关、重扫、重锁等操作。
 */

(() => {
    const PLUGIN_NAME_CANDIDATES = ["maccmswall", "MacCmsWall"];
    let activePluginName = PLUGIN_NAME_CANDIDATES[0];
    const state = {
        sites: [],
        dashboard: {},
        logs: [],
    };

    const el = {
        healthBadge: document.getElementById("healthBadge"),
        toast: document.getElementById("toast"),
        tabs: document.getElementById("tabs"),
        panelDashboard: document.getElementById("panel-dashboard"),
        panelSites: document.getElementById("panel-sites"),
        panelLogs: document.getElementById("panel-logs"),
        statProtectedSites: document.getElementById("statProtectedSites"),
        statTotalSites: document.getElementById("statTotalSites"),
        statLockedFiles: document.getElementById("statLockedFiles"),
        statTotalFiles: document.getElementById("statTotalFiles"),
        modeStats: document.getElementById("modeStats"),
        lastActionText: document.getElementById("lastActionText"),
        lastActionTime: document.getElementById("lastActionTime"),
        addSiteForm: document.getElementById("addSiteForm"),
        sitePath: document.getElementById("sitePath"),
        btnPickSitePath: document.getElementById("btnPickSitePath"),
        siteTableBody: document.getElementById("siteTableBody"),
        btnRefreshAll: document.getElementById("btnRefreshAll"),
        btnRefreshSites: document.getElementById("btnRefreshSites"),
        btnRefreshLogs: document.getElementById("btnRefreshLogs"),
        btnClearLogs: document.getElementById("btnClearLogs"),
        logLimit: document.getElementById("logLimit"),
        logTableBody: document.getElementById("logTableBody"),
    };

    function buildApiPrefix(pluginName) {
        return `/plugin?action=a&name=${encodeURIComponent(pluginName)}&s=`;
    }

    // 统一 API 请求：发送 x-www-form-urlencoded，兼容面板插件路由。
    async function callApiWithPlugin(pluginName, method, payload = {}) {
        const body = new URLSearchParams();
        Object.keys(payload).forEach((key) => {
            body.append(key, payload[key]);
        });

        const res = await fetch(`${buildApiPrefix(pluginName)}${encodeURIComponent(method)}`, {
            method: "POST",
            headers: {
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            },
            credentials: "same-origin",
            body: body.toString(),
        });

        const text = await res.text();
        let json;
        try {
            json = JSON.parse(text);
        } catch (err) {
            throw new Error(`接口返回非 JSON：${text.slice(0, 200)}`);
        }

        if (!json.status) {
            throw new Error(json.msg || "操作失败");
        }

        return json.data || {};
    }

    async function callApi(method, payload = {}) {
        return callApiWithPlugin(activePluginName, method, payload);
    }

    async function detectPluginName() {
        let lastError = null;

        for (const pluginName of PLUGIN_NAME_CANDIDATES) {
            try {
                await callApiWithPlugin(pluginName, "health");
                activePluginName = pluginName;
                return;
            } catch (err) {
                lastError = err;
            }
        }

        throw lastError || new Error("无法识别插件 API，请确认插件目录和名称是否一致");
    }

    function showToast(message, isError = false) {
        el.toast.textContent = message;
        el.toast.style.background = isError ? "rgba(159,47,47,0.95)" : "rgba(22,33,44,0.92)";
        el.toast.classList.add("show");
        window.clearTimeout(showToast._timer);
        showToast._timer = window.setTimeout(() => {
            el.toast.classList.remove("show");
        }, 2600);
    }

    function formatTs(ts) {
        if (!ts || Number(ts) <= 0) {
            return "-";
        }
        const d = new Date(Number(ts) * 1000);
        const pad = (n) => String(n).padStart(2, "0");
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    }

    function escapeHtml(str) {
        return String(str)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    function setLoading(btn, loading) {
        if (!btn) return;
        if (loading) {
            btn.dataset.oldText = btn.textContent;
            btn.textContent = "处理中...";
            btn.disabled = true;
            return;
        }
        if (btn.dataset.oldText) {
            btn.textContent = btn.dataset.oldText;
        }
        btn.disabled = false;
    }

    function normalizePathText(raw) {
        if (raw === undefined || raw === null) {
            return "";
        }

        let text = String(raw).trim();
        if (!text) {
            return "";
        }

        text = text.replace(/^file:\/\//i, "");
        text = text.replace(/\\/g, "/");
        return text;
    }

    function extractPathValue(value, depth = 0) {
        if (depth > 4 || value === undefined || value === null) {
            return "";
        }

        if (typeof value === "string" || typeof value === "number") {
            const text = normalizePathText(value);
            return text.includes("/") ? text : "";
        }

        if (Array.isArray(value)) {
            for (const item of value) {
                const nested = extractPathValue(item, depth + 1);
                if (nested) {
                    return nested;
                }
            }
            return "";
        }

        if (typeof value === "object") {
            const keys = [
                "path", "dir", "f_path", "file_path", "filepath",
                "fullpath", "full_path", "selected", "selection",
                "value", "msg", "data"
            ];

            for (const key of keys) {
                if (Object.prototype.hasOwnProperty.call(value, key)) {
                    const nested = extractPathValue(value[key], depth + 1);
                    if (nested) {
                        return nested;
                    }
                }
            }
        }

        return "";
    }

    function getPathPickerCandidates() {
        const result = [];
        const seen = new Set();
        const btObj = window.bt && typeof window.bt === "object" ? window.bt : null;

        const addCandidate = (name, fn, context) => {
            if (typeof fn !== "function") {
                return;
            }

            const key = `${context === window ? "window" : "bt"}:${name}`;
            if (seen.has(key)) {
                return;
            }
            seen.add(key);
            result.push({ name, fn, context });
        };

        if (btObj) {
            const preferNames = ["select_path", "selectPath", "choosePath", "openPath", "open_path", "openDir"];
            preferNames.forEach((name) => addCandidate(name, btObj[name], btObj));

            Object.keys(btObj)
                .filter((name) => /path|dir|file/i.test(name))
                .slice(0, 12)
                .forEach((name) => addCandidate(name, btObj[name], btObj));
        }

        ["select_path", "selectPath", "choosePath", "openPath", "open_path", "openDir"].forEach((name) => {
            addCandidate(name, window[name], window);
        });

        return result;
    }

    function waitPickerResult(invoke, timeoutMs = 30000) {
        return new Promise((resolve, reject) => {
            let settled = false;
            const done = (ret) => {
                if (settled) {
                    return;
                }
                settled = true;
                resolve(ret);
            };

            try {
                const ret = invoke(done);
                if (ret && typeof ret.then === "function") {
                    ret.then(done).catch(reject);
                } else if (ret !== undefined && ret !== null && ret !== "") {
                    done(ret);
                }
            } catch (err) {
                reject(err);
                return;
            }

            window.setTimeout(() => {
                if (!settled) {
                    reject(new Error("path picker timeout"));
                }
            }, timeoutMs);
        });
    }

    async function tryInvokePathPicker(candidate, defaultPath) {
        const options = {
            title: "选择网站目录",
            path: defaultPath,
            dir: true,
            type: "dir",
        };

        const attempts = [
            (done) => candidate.fn.call(candidate.context, options, done),
            (done) => candidate.fn.call(candidate.context, done, options),
            (done) => candidate.fn.call(candidate.context, options.path, done),
        ];

        for (const invoke of attempts) {
            try {
                const ret = await waitPickerResult(invoke, 30000);
                const path = extractPathValue(ret);
                if (path) {
                    return path;
                }
            } catch (_err) {
                // 继续尝试下一个签名。
            }
        }

        return "";
    }

    async function pickSitePath(defaultPath = "") {
        const initialPath = normalizePathText(defaultPath) || "/www/wwwroot";
        const candidates = getPathPickerCandidates();

        for (const candidate of candidates) {
            const path = await tryInvokePathPicker(candidate, initialPath);
            if (path) {
                return path;
            }
        }

        const manual = window.prompt("未检测到可用路径选择器，请手动输入网站绝对路径：", initialPath);
        if (manual === null) {
            return "";
        }
        return normalizePathText(manual);
    }

    function renderDashboard() {
        const d = state.dashboard || {};
        el.statProtectedSites.textContent = Number(d.protected_sites || 0);
        el.statTotalSites.textContent = Number(d.total_sites || 0);
        el.statLockedFiles.textContent = Number(d.locked_files || 0);
        el.statTotalFiles.textContent = Number(d.total_files || 0);

        const modeStats = d.mode_stats || {};
        const html = Object.keys(modeStats).length
            ? Object.keys(modeStats)
                .map((mode) => `<span class="mode-pill">${mode === "strict" ? "严格全锁" : "MACCMS兼容"}：${modeStats[mode]}</span>`)
                .join("")
            : "<span class='mode-pill'>暂无数据</span>";

        el.modeStats.innerHTML = html;

        const lastAction = d.last_action || {};
        el.lastActionText.textContent = lastAction.message || "暂无操作记录";
        el.lastActionTime.textContent = `时间：${formatTs(lastAction.created_at)}`;
    }

    function renderSites() {
        if (!state.sites.length) {
            el.siteTableBody.innerHTML = "<tr><td colspan='8'>暂无站点，请先添加。</td></tr>";
            return;
        }

        el.siteTableBody.innerHTML = state.sites
            .map((site) => {
                const statusCls = Number(site.status) === 1 ? "status-on" : "status-off";
                const statusText = Number(site.status) === 1 ? "已开启" : "未开启";
                const modeOptions = [
                    { value: "strict", text: "严格全锁" },
                    { value: "maccms", text: "MACCMS兼容" },
                ]
                    .map((item) => `<option value="${item.value}" ${site.mode === item.value ? "selected" : ""}>${item.text}</option>`)
                    .join("");

                return `
                    <tr>
                        <td>${site.id}</td>
                        <td>${escapeHtml(site.site_name)}</td>
                        <td>${escapeHtml(site.site_path)}</td>
                        <td class="${statusCls}">${statusText}</td>
                        <td>
                            <div class="row-actions">
                                <select data-role="mode-select" data-id="${site.id}">${modeOptions}</select>
                                <button class="btn btn-secondary btn-mini" data-action="mode" data-id="${site.id}">保存</button>
                            </div>
                        </td>
                        <td>${Number(site.file_count || 0)}</td>
                        <td>${Number(site.locked_count || 0)}</td>
                        <td>
                            <div class="action-list">
                                <button class="btn btn-primary btn-mini" data-action="enable" data-id="${site.id}">开启防护</button>
                                <button class="btn btn-secondary btn-mini" data-action="disable" data-id="${site.id}">关闭防护</button>
                                <button class="btn btn-secondary btn-mini" data-action="rescan" data-id="${site.id}">重新扫描</button>
                                <button class="btn btn-secondary btn-mini" data-action="relock" data-id="${site.id}">重新加锁</button>
                                <button class="btn btn-danger btn-mini" data-action="delete" data-id="${site.id}">删除</button>
                            </div>
                        </td>
                    </tr>
                `;
            })
            .join("");
    }

    function renderLogs() {
        if (!state.logs.length) {
            el.logTableBody.innerHTML = "<tr><td colspan='6'>暂无日志。</td></tr>";
            return;
        }

        el.logTableBody.innerHTML = state.logs
            .map(
                (item) => `
                <tr>
                    <td>${item.id}</td>
                    <td>${escapeHtml(item.level)}</td>
                    <td>${escapeHtml(item.action)}</td>
                    <td>${Number(item.site_id || 0)}</td>
                    <td>${escapeHtml(item.message)}</td>
                    <td>${formatTs(item.created_at)}</td>
                </tr>
            `
            )
            .join("");
    }

    async function loadHealth() {
        try {
            await callApi("health");
            el.healthBadge.textContent = "后端在线";
            el.healthBadge.classList.remove("badge-warn");
            el.healthBadge.classList.add("badge-ok");
        } catch (err) {
            el.healthBadge.textContent = "后端异常";
            el.healthBadge.classList.remove("badge-ok");
            el.healthBadge.classList.add("badge-warn");
        }
    }

    async function loadDashboard() {
        state.dashboard = await callApi("get_dashboard");
        renderDashboard();
    }

    async function loadSites() {
        const data = await callApi("list_sites");
        state.sites = data.sites || [];
        renderSites();
    }

    async function loadLogs() {
        const limit = Number(el.logLimit.value || 300);
        const data = await callApi("get_logs", { limit });
        state.logs = data.logs || [];
        renderLogs();
    }

    async function loadMainData() {
        await Promise.all([loadDashboard(), loadSites()]);
    }

    function switchTab(name) {
        const tabBtns = el.tabs.querySelectorAll(".tab");
        tabBtns.forEach((btn) => {
            btn.classList.toggle("active", btn.dataset.tab === name);
        });

        el.panelDashboard.classList.toggle("active", name === "dashboard");
        el.panelSites.classList.toggle("active", name === "sites");
        el.panelLogs.classList.toggle("active", name === "logs");

        if (name === "logs") {
            loadLogs().catch((err) => showToast(err.message, true));
        }
    }

    async function handleSiteAction(action, siteId, btn) {
        setLoading(btn, true);
        try {
            if (action === "mode") {
                const select = document.querySelector(`select[data-role='mode-select'][data-id='${siteId}']`);
                const mode = select ? select.value : "strict";
                await callApi("update_mode", { site_id: siteId, mode });
                showToast("模式更新成功");
            } else if (action === "enable") {
                await callApi("enable_protection", { site_id: siteId });
                showToast("防护已开启");
            } else if (action === "disable") {
                await callApi("disable_protection", { site_id: siteId });
                showToast("防护已关闭");
            } else if (action === "rescan") {
                await callApi("rescan_site", { site_id: siteId });
                showToast("重新扫描成功");
            } else if (action === "relock") {
                await callApi("relock_site", { site_id: siteId });
                showToast("重新加锁成功");
            } else if (action === "delete") {
                const ok = window.confirm("确认删除该站点吗？若站点处于防护状态会先尝试解锁。");
                if (!ok) return;
                await callApi("remove_site", { site_id: siteId });
                showToast("站点已删除");
            }

            await loadMainData();
        } catch (err) {
            showToast(err.message || "操作失败", true);
        } finally {
            setLoading(btn, false);
        }
    }

    function bindEvents() {
        el.tabs.addEventListener("click", (event) => {
            const target = event.target.closest(".tab");
            if (!target) return;
            switchTab(target.dataset.tab);
        });

        el.btnRefreshAll.addEventListener("click", async () => {
            try {
                await loadMainData();
                showToast("全局数据已刷新");
            } catch (err) {
                showToast(err.message, true);
            }
        });

        el.btnRefreshSites.addEventListener("click", async () => {
            try {
                await loadSites();
                showToast("网站列表已刷新");
            } catch (err) {
                showToast(err.message, true);
            }
        });

        el.btnRefreshLogs.addEventListener("click", async () => {
            try {
                await loadLogs();
                showToast("日志已刷新");
            } catch (err) {
                showToast(err.message, true);
            }
        });

        el.btnClearLogs.addEventListener("click", async () => {
            const ok = window.confirm("确认清空日志吗？");
            if (!ok) return;
            try {
                await callApi("clear_logs");
                await loadLogs();
                showToast("日志已清空");
            } catch (err) {
                showToast(err.message, true);
            }
        });

        if (el.btnPickSitePath) {
            el.btnPickSitePath.addEventListener("click", async () => {
                setLoading(el.btnPickSitePath, true);
                try {
                    const selectedPath = await pickSitePath(el.sitePath ? el.sitePath.value : "");
                    if (selectedPath && el.sitePath) {
                        el.sitePath.value = selectedPath;
                        showToast("已填充网站路径");
                    } else {
                        showToast("未选择路径，保留当前输入");
                    }
                } catch (_err) {
                    showToast("路径选择器不可用，请手动输入网站路径", true);
                } finally {
                    setLoading(el.btnPickSitePath, false);
                }
            });
        }

        el.addSiteForm.addEventListener("submit", async (event) => {
            event.preventDefault();
            const formData = new FormData(el.addSiteForm);
            const payload = {
                site_name: (formData.get("site_name") || "").toString().trim(),
                site_path: (formData.get("site_path") || "").toString().trim(),
                mode: (formData.get("mode") || "strict").toString(),
            };

            if (!payload.site_name || !payload.site_path) {
                showToast("请完整填写网站名称和路径", true);
                return;
            }

            const submitBtn = el.addSiteForm.querySelector("button[type='submit']");
            setLoading(submitBtn, true);
            try {
                await callApi("add_site", payload);
                el.addSiteForm.reset();
                showToast("新增站点成功");
                await loadMainData();
            } catch (err) {
                showToast(err.message, true);
            } finally {
                setLoading(submitBtn, false);
            }
        });

        el.siteTableBody.addEventListener("click", (event) => {
            const btn = event.target.closest("button[data-action]");
            if (!btn) return;
            const action = btn.dataset.action;
            const siteId = Number(btn.dataset.id || 0);
            if (!action || !siteId) return;
            handleSiteAction(action, siteId, btn);
        });
    }

    async function bootstrap() {
        bindEvents();
        await detectPluginName();
        await loadHealth();
        await loadMainData();
        switchTab("dashboard");
    }

    bootstrap().catch((err) => {
        showToast(err.message || "初始化失败", true);
    });
})();
