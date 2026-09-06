// An independent PC implementation and the shipping mobile adapter receive
// identical images, clock ticks and public speed changes. Never derive the
// expected image from the mobile implementation or its private state.
window.runPCGradientChecks = function (DesktopKawarp) {
  const original = { now: performance.now, raf: window.requestAnimationFrame, caf: window.cancelAnimationFrame };
  let now = 0, identifier = 0;
  const callbacks = new Map(), results = [];
  const host = document.createElement('div'), referenceCanvas = document.createElement('canvas');
  document.body.appendChild(host); host.appendChild(referenceCanvas);
  const mobileHost = document.createElement('div'); host.appendChild(mobileHost);
  let reference, mobile;
  const snapshot = canvas => {
    const copy = document.createElement('canvas'); copy.width = 300; copy.height = 150;
    const context = copy.getContext('2d'); context.drawImage(canvas, 0, 0, 300, 150);
    return context.getImageData(0, 0, 300, 150).data;
  };
  const compare = name => {
    const expected = snapshot(referenceCanvas), actual = snapshot(mobile.canvas);
    let maximum = 0, total = 0, differentPixels = 0, peak = 0;
    for (let offset = 0; offset < expected.length; offset += 4) {
      let difference = 0;
      for (let channel = 0; channel < 3; channel++) {
        const delta = Math.abs(expected[offset + channel] - actual[offset + channel]);
        maximum = Math.max(maximum, delta); difference = Math.max(difference, delta); total += delta;
        peak = Math.max(peak, expected[offset + channel]);
      }
      if (difference > 1) differentPixels++;
    }
    results.push({ name, pass: maximum <= 1 && peak > 40 && mobile.canvas.width === 300 && mobile.canvas.height === 150,
      detail: { maximumChannelError: maximum, meanChannelError: total / (300 * 150 * 3), differentPixels, peak } });
  };
  const source = (second = false) => {
    const canvas = document.createElement('canvas'); canvas.width = 256; canvas.height = 256;
    const context = canvas.getContext('2d');
    context.fillStyle = second ? '#dfd7c5' : '#090b11'; context.fillRect(0, 0, 256, 256);
    const colors = second ? ['#121f3a', '#a22a95', '#eeeeea', '#da572d'] : ['#e32859', '#157ded', '#e0a72e', '#268f61'];
    [[0, 0, 153, 120], [157, 45, 99, 211], [18, 156, 127, 100], [65, 100, 90, 74]].forEach((rect, i) => {
      context.fillStyle = colors[i]; context.fillRect(...rect);
    });
    return canvas;
  };
  const advance = time => {
    now = time;
    const pending = [...callbacks.values()]; callbacks.clear();
    pending.forEach(callback => callback(now));
  };
  try {
    performance.now = () => now;
    window.requestAnimationFrame = callback => { callbacks.set(++identifier, callback); return identifier; };
    window.cancelAnimationFrame = id => callbacks.delete(id);
    reference = new DesktopKawarp(referenceCanvas, {
      warpIntensity: 1, blurPasses: 8, animationSpeed: .1, saturation: 1.5,
      dithering: .008, transitionDuration: 500, tintIntensity: 0, scale: 1
    });
    mobile = new window.SpicyGradientField(mobileHost);
    const first = source();
    reference.loadImageElement(first); reference.animationSpeed = 1; reference.start();
    mobile.setMotion(true, 100); mobile.setImage(first);
    for (let frame = 0; frame <= 660; frame++) {
      advance(frame * 1000 / 60 + (frame > 540 ? 5000 : 0));
      if (frame === 60) { compare('PC pixels: first cover at one second'); reference.transitionDuration = 1000; }
      if (frame === 240) compare('PC pixels: asymmetric cover at four seconds');
      if (frame === 300) {
        const next = source(true); reference.loadImageElement(next); mobile.setImage(next);
      }
      if ([315, 345, 360].includes(frame)) compare('PC pixels: next cover crossfade at ' + (frame - 300) / 60 + ' seconds');
      if (frame === 420) {
        const before = mobile.canvas.toDataURL(); reference.animationSpeed = .25; mobile.setMotion(true, 25);
        results.push({name:'Changing gradient speed does not repaint or reset its phase',pass:before === mobile.canvas.toDataURL()});
      }
      if ([421, 450].includes(frame)) compare('PC pixels: slow-speed smoothing frame ' + frame);
      if (frame === 480) { reference.animationSpeed = 2; mobile.setMotion(true, 200); }
      if ([481, 510].includes(frame)) compare('PC pixels: fast-speed smoothing frame ' + frame);
      if (frame === 540) {
        reference.stop(); mobile.setMotion(false, 200);
        const frozen = mobile.canvas.toDataURL(); advance(now + 5000);
        results.push({name:'Suspended gradient has no scheduled paint and no five-second drift',
          pass:callbacks.size === 0 && frozen === mobile.canvas.toDataURL()});
        reference.start(); mobile.setMotion(true, 200);
      }
      if ([541, 600, 660].includes(frame)) compare('PC pixels: phase-continuous resume frame ' + frame);
    }
    advance(60000); compare('PC pixels: long frame uses the same clock integration');
    return results;
  } finally {
    reference?.dispose(); mobile?.setMotion(false, 100); host.remove();
    performance.now = original.now; window.requestAnimationFrame = original.raf; window.cancelAnimationFrame = original.caf;
  }
};
