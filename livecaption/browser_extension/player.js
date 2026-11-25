(() => {
  const port = chrome.runtime.connect({ name: "player-caption" });
  const watchers = new AbortController();
  let video = null;
  let videoEvents = null;
  let track = null;
  let trackEvents = null;
  let previous = "";
  let lastSend = 0;

  const isCaption = track => track.kind === "captions" || track.kind === "subtitles";

  function findVideo() {
    const videos = Array.from(document.querySelectorAll("video"), element => ({
      element,
      area: element.clientWidth * element.clientHeight,
      captions: Array.from(element.textTracks).some(isCaption),
    })).filter(video => video.area > 0);
    videos.sort((a, b) => Number(b.captions) - Number(a.captions) || b.area - a.area);
    return videos[0]?.element ?? null;
  }

  function watchVideo(element) {
    videoEvents?.abort();
    video = element;
    if (!video) return;
    videoEvents = new AbortController();
    const options = { signal: videoEvents.signal };
    for (const event of ["play", "pause", "seeking", "seeked", "ended", "emptied", "loadedmetadata", "ratechange"]) {
      video.addEventListener(event, sample, options);
    }
    for (const event of ["addtrack", "removetrack", "change"]) {
      video.textTracks.addEventListener(event, sample, options);
    }
  }

  function clip(text, length) {
    return Array.from(text.replace(/\s+/g, " ").trim()).slice(0, length).join("");
  }

  function textOf(cue) {
    if (typeof cue.text !== "string") return "";
    return typeof cue.getCueAsHTML === "function" ? cue.getCueAsHTML().textContent : cue.text;
  }

  function upcomingCue(cues, time) {
    let first = 0;
    let last = cues.length;
    while (first < last) {
      const middle = Math.floor((first + last) / 2);
      if (cues[middle].startTime <= time) first = middle + 1;
      else last = middle;
    }
    const next = cues[first];
    return next && next.startTime - time <= 6 ? clip(textOf(next), 1500) : "";
  }

  function sample() {
    if (!video?.isConnected) watchVideo(findVideo());
    const tracks = Array.from(video?.textTracks ?? []).filter(isCaption);
    const selected = tracks.find(track => track.mode === "showing") ?? null;
    if (selected !== track) {
      trackEvents?.abort();
      track = selected;
      if (track) {
        trackEvents = new AbortController();
        track.addEventListener("cuechange", sample, { signal: trackEvents.signal });
      }
    }
    const snapshot = { state: "no_video", track: "", text: "", upcoming: "" };
    if (video) snapshot.state = tracks.length ? "off" : "no_track";
    if (track) {
      snapshot.track = clip(track.label || track.language, 80);
      const trackElement = Array.from(video.querySelectorAll("track")).find(element => element.track === track);
      if (video.seeking) snapshot.state = "seeking";
      else if (video.ended) snapshot.state = "ended";
      else if (trackElement?.readyState === HTMLTrackElement.ERROR) snapshot.state = "track_error";
      else if (!track.cues || !video.readyState) snapshot.state = "loading";
      else {
        snapshot.state = video.paused ? "paused" : "playing";
        const time = video.currentTime;
        const cues = Array.from(track.activeCues ?? []).filter(cue => cue.startTime <= time && cue.endTime > time);
        snapshot.text = clip(cues.map(textOf).filter(Boolean).join(" "), 1500);
        if (!video.paused) snapshot.upcoming = upcomingCue(track.cues, time);
      }
    }
    const encoded = JSON.stringify(snapshot);
    if (encoded !== previous || performance.now() - lastSend >= 2000) {
      previous = encoded;
      lastSend = performance.now();
      port.postMessage(snapshot);
    }
  }

  function stop() {
    clearInterval(timer);
    watchers.abort();
    videoEvents?.abort();
    trackEvents?.abort();
  }

  const timer = setInterval(sample, 200);
  port.onDisconnect.addListener(stop);
  window.addEventListener("pagehide", () => {
    stop();
    port.disconnect();
  }, { signal: watchers.signal });
  sample();
})();
