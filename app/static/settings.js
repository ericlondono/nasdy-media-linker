const $ = (sel) => document.querySelector(sel);

document.addEventListener("DOMContentLoaded", () => {
  const btn = $("#testQbit");
  if (!btn) return;
  btn.addEventListener("click", async () => {
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
});
