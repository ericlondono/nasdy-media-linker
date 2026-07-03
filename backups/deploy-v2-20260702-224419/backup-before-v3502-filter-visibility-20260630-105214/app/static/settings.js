const $ = (sel) => document.querySelector(sel);

document.addEventListener("DOMContentLoaded", () => {
  const qbitBtn = $("#testQbit");
  if (qbitBtn) {
    qbitBtn.addEventListener("click", async () => {
      $("#testResult").textContent = "Testing...";
      const payload = {
        qbittorrent_url: $("#qbittorrent_url").value,
        qbittorrent_username: $("#qbittorrent_username").value,
        qbittorrent_password: $("#qbittorrent_password").value,
      };
      const res = await fetch("/api/qbit/test", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify(payload)
      });
      const data = await res.json();
      $("#testResult").textContent = data.message;
      $("#testResult").className = data.ok ? "good-text" : "bad-text";
    });
  }

  const tmdbBtn = $("#testTmdb");
  if (tmdbBtn) {
    tmdbBtn.addEventListener("click", async () => {
      $("#tmdbTestResult").textContent = "Testing...";
      const payload = {
        tmdb_api_key: $("#tmdb_api_key").value,
      };
      const res = await fetch("/api/tmdb/test", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify(payload)
      });
      const data = await res.json();
      $("#tmdbTestResult").textContent = data.message;
      $("#tmdbTestResult").className = data.ok ? "good-text" : "bad-text";
    });
  }
});
