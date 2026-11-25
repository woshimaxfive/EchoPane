let active = null;

function disconnect(session = active) {
  if (!session || active !== session) return;
  active = null;
  session.port?.disconnect();
  session.socket.close();
}

async function start(tabId, code) {
  if (active) return "请先断开已连接的标签页。";
  const parts = /^(\d{1,5})-([A-Za-z0-9_-]{24})$/.exec(code);
  const port = Number(parts?.[1]);
  if (!Number.isInteger(tabId) || !parts || port < 1024 || port > 65535) {
    return "请粘贴 EchoPane 复制的连接码。";
  }

  const socket = new WebSocket(`ws://127.0.0.1:${port}/`, `echopane-v1.${parts[2]}`);
  const session = { tabId, socket, port: null };
  active = session;
  socket.addEventListener("close", () => disconnect(session));
  const opened = await new Promise(resolve => {
    const timeout = setTimeout(() => resolve(false), 2500);
    const finish = ok => {
      clearTimeout(timeout);
      resolve(ok);
    };
    socket.addEventListener("open", () => finish(true), { once: true });
    socket.addEventListener("error", () => finish(false), { once: true });
    socket.addEventListener("close", () => finish(false), { once: true });
  });
  if (!opened || active !== session) {
    disconnect(session);
    return "连不上 EchoPane。请开启新连接，再复制连接码。";
  }
  try {
    await chrome.scripting.executeScript({ target: { tabId }, files: ["player.js"] });
  } catch {
    disconnect(session);
    return "无法读取这个标签页。请在视频网页里重新打开扩展。";
  }
  return active === session ? "" : "连接已关闭，请在 EchoPane 重新开启。";
}

chrome.runtime.onConnect.addListener(port => {
  const session = active;
  if (!session || session.port || port.name !== "player-caption" ||
      port.sender?.tab?.id !== session.tabId || port.sender?.frameId !== 0) {
    port.disconnect();
    return;
  }
  session.port = port;
  port.onDisconnect.addListener(() => disconnect(session));
  port.onMessage.addListener(snapshot => {
    if (active !== session || session.socket.readyState !== WebSocket.OPEN) return;
    if (session.socket.bufferedAmount > 32 * 1024) {
      disconnect(session);
      return;
    }
    session.socket.send(JSON.stringify(snapshot));
  });
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.url !== chrome.runtime.getURL("popup.html")) return;
  if (message.type === "status") reply({ connected: Boolean(active) });
  if (message.type === "stop") {
    disconnect();
    reply({ connected: false });
  }
  if (message.type === "start") {
    start(message.tabId, message.code).then(
      error => reply({ connected: !error, error }),
      () => reply({ connected: false, error: "无法建立连接，请重试。" }),
    );
    return true;
  }
});
