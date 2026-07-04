const $ = (sel) => document.querySelector(sel);

async function postJson(url, payload) {
  const res = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(payload || {})
  });
  return await res.json();
}

function setResult(selector, message, ok) {
  const el = $(selector);
  if (!el) return;
  el.textContent = message || "";
  el.className = ok ? "good-text" : "bad-text";
}

function jellyfinPayload() {
  return {
    jellyfin_url: $("#jellyfin_url")?.value || "",
    jellyfin_api_key: $("#jellyfin_api_key")?.value || "",
  };
}

document.addEventListener("DOMContentLoaded", () => {
  const qbitBtn = $("#testQbit");
  if (qbitBtn) {
    qbitBtn.addEventListener("click", async () => {
      setResult("#testResult", "Testing...", true);
      const payload = {
        qbittorrent_url: $("#qbittorrent_url").value,
        qbittorrent_username: $("#qbittorrent_username").value,
        qbittorrent_password: $("#qbittorrent_password").value,
      };
      try {
        const data = await postJson("/api/qbit/test", payload);
        setResult("#testResult", data.message, data.ok);
      } catch (error) {
        setResult("#testResult", `qBittorrent test failed: ${error}`, false);
      }
    });
  }

  const tmdbBtn = $("#testTmdb");
  if (tmdbBtn) {
    tmdbBtn.addEventListener("click", async () => {
      setResult("#tmdbTestResult", "Testing...", true);
      const payload = {
        tmdb_api_key: $("#tmdb_api_key").value,
      };
      try {
        const data = await postJson("/api/tmdb/test", payload);
        setResult("#tmdbTestResult", data.message, data.ok);
      } catch (error) {
        setResult("#tmdbTestResult", `TMDb test failed: ${error}`, false);
      }
    });
  }

  const jellyfinBtn = $("#testJellyfin");
  if (jellyfinBtn) {
    jellyfinBtn.addEventListener("click", async () => {
      setResult("#jellyfinTestResult", "Testing...", true);
      try {
        const data = await postJson("/api/jellyfin/test", jellyfinPayload());
        setResult("#jellyfinTestResult", data.message, data.ok);
      } catch (error) {
        setResult("#jellyfinTestResult", `Jellyfin test failed: ${error}`, false);
      }
    });
  }

  const refreshBtn = $("#refreshJellyfinNow");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", async () => {
      setResult("#jellyfinTestResult", "Requesting Jellyfin library scan...", true);
      refreshBtn.disabled = true;
      try {
        const data = await postJson("/api/jellyfin/refresh", jellyfinPayload());
        setResult("#jellyfinTestResult", data.message, data.ok);
      } catch (error) {
        setResult("#jellyfinTestResult", `Jellyfin refresh failed: ${error}`, false);
      } finally {
        refreshBtn.disabled = false;
      }
    });
  }
});