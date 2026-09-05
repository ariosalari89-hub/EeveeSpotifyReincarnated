// Test-only input through agent-browser's documented local streaming transport.
// Chromium dispatches trusted touch events; this is not DOM dispatchEvent().
const [port, type, x, y] = process.argv.slice(2);
const socket = new WebSocket(`ws://127.0.0.1:${Number(port)}/?pacing=ack&maxFps=1`);
let closing = false;
const timeout = setTimeout(() => { console.error('Touch transport timed out'); process.exit(1); }, 3000);
socket.addEventListener('error', error => {
  if (!closing) { console.error(error.message, error.error); process.exit(1); }
});
socket.addEventListener('open', () => {
  socket.send(JSON.stringify({
    type: 'input_touch', eventType: type,
    touchPoints: type === 'touchEnd' || type === 'touchCancel' ? []
      : [{ x: Number(x), y: Number(y), id: 1, radiusX: 5, radiusY: 5, force: 1 }]
  }));
  // Transport dispatch is asynchronous; the calling test additionally checks
  // receipt and resulting state in the rendered page.
  setTimeout(() => { closing = true; socket.close(); clearTimeout(timeout); }, 100);
});
