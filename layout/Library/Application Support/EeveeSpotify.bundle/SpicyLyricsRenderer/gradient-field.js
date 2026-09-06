(() => {
  "use strict";

  class GradientField {
    constructor(parent) {
      this.canvas = document.createElement("canvas");
      this.canvas.className = "gradient-field";
      this.canvas.setAttribute("aria-hidden", "true");
      this.canvas.width = this.canvas.height = 96;
      this.canvas.hidden = true;
      parent.appendChild(this.canvas);
      this.context = this.canvas.getContext("2d", { alpha: false });
      this.frame = this.context?.createImageData(96, 96);
      this.palette = [];
      this.phase = 0;
      this.speed = 1;
      this.active = false;
      this.lastTime = null;
      this.lastPaint = null;
      this.request = 0;
      this.tick = this.tick.bind(this);
    }

    setPalette(palette) {
      if (JSON.stringify(palette) === JSON.stringify(this.palette)) return;
      this.palette = palette.map(rgb => rgb.slice());
      this.canvas.hidden = !this.context || !this.palette.length;
      if (!this.canvas.hidden) this.paint();
    }

    setMotion(active, speed) {
      const now = performance.now();
      this.advance(now);
      this.speed = speed / 100;
      this.active = !!(active && this.context && this.palette.length);
      this.lastTime = this.active ? now : null;
      if (this.active && !this.request) this.request = requestAnimationFrame(this.tick);
      if (!this.active && this.request) {
        cancelAnimationFrame(this.request);
        this.request = 0;
      }
    }

    advance(now) {
      if (this.active && this.lastTime !== null) {
        this.phase += Math.min(100, Math.max(0, now - this.lastTime)) * .00015 * this.speed;
      }
      this.lastTime = now;
    }

    tick(now) {
      this.request = 0;
      if (!this.active) return;
      this.advance(now);
      if (this.lastPaint === null || now - this.lastPaint >= 32) {
        this.paint();
        this.lastPaint = now;
      }
      this.request = requestAnimationFrame(this.tick);
    }

    paint() {
      if (!this.context || !this.palette.length) return;
      const [first, second = first, third = first, fourth = second] = this.palette;
      const colors = [first, second, third, fourth];
      const pixels = this.frame.data;
      const time = this.phase;
      const curl = 2.1 + 1.3 * Math.sin(time * .67);
      const centerX = .09 * Math.sin(time * .83);
      const centerY = .09 * Math.sin(time * .71);
      const fold = .18 * Math.sin(time * .93);
      for (let y = 0; y < 96; y++) {
        for (let x = 0; x < 96; x++) {
          const u = (x + .5) / 48 - 1 - centerX;
          const v = (y + .5) / 48 - 1 - centerY;
          const angle = curl * Math.exp(-(u * u + v * v) * .85) + time * .16;
          const cosine = Math.cos(angle), sine = Math.sin(angle);
          const materialX = u * cosine - v * sine + centerX;
          const materialY = u * sine + v * cosine + centerY;
          const horizontal = .5 + .5 * Math.tanh((materialX + fold * Math.sin(materialY * 3)) * 4.5);
          const vertical = .5 + .5 * Math.tanh((materialY - fold * Math.sin(materialX * 3)) * 4.5);
          const weights = [(1 - horizontal) * (1 - vertical), horizontal * (1 - vertical),
            (1 - horizontal) * vertical, horizontal * vertical];
          const offset = (y * 96 + x) * 4;
          for (let channel = 0; channel < 3; channel++) {
            pixels[offset + channel] = colors.reduce((sum, rgb, index) => sum + rgb[channel] * weights[index], 0);
          }
          pixels[offset + 3] = 255;
        }
      }
      this.context.putImageData(this.frame, 0, 0);
    }
  }

  window.SpicyGradientField = GradientField;
})();
