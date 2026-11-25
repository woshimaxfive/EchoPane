const form = document.querySelector("#connect");
const code = document.querySelector("#code");
const submit = form.querySelector("button");
const stop = document.querySelector("#stop");
const statusLine = document.querySelector("#status");

function show(connected, message) {
  form.hidden = connected;
  stop.hidden = !connected;
  statusLine.textContent = message || (connected ? "已连接。请在视频播放器中开启字幕。" : "从 EchoPane 的「网页字幕」复制连接码。");
  if (connected) code.value = "";
}

form.addEventListener("submit", async event => {
  event.preventDefault();
  submit.disabled = true;
  statusLine.textContent = "正在连接…";
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const response = await chrome.runtime.sendMessage({ type: "start", tabId: tab?.id, code: code.value.trim() });
    show(response.connected, response.error);
  } catch {
    show(false, "无法建立连接，请重试。");
  } finally {
    submit.disabled = false;
  }
});

stop.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "stop" });
  show(false, "已断开。再次使用时请在 EchoPane 开启新连接。");
});

chrome.runtime.sendMessage({ type: "status" }).then(response => show(response.connected));
