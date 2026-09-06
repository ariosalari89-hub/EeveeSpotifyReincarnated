(() => {
  "use strict";

  // Mobile owns lifecycle; the pinned PC engine owns all image processing.
  // Keep the desktop's default 300x150 backing store and CSS scaling.
  class GradientField {
    constructor(parent) {
      this.canvas = document.createElement("canvas");
      this.canvas.className = "gradient-field";
      this.canvas.setAttribute("aria-hidden", "true");
      this.canvas.hidden = true;
      parent.appendChild(this.canvas);
      this.source = null;
      this.phase = 0;
      this.rate = .1;
      this.speed = 1;
      this.wanted = false;
      this.active = false;
      this.ready = false;
      this.lastTime = null;
      this.request = 0;
      this.loadedOnce = false;
      this.tick = this.tick.bind(this);
      this.engine = this.createEngine();
      this.canvas.addEventListener("webglcontextlost", event => {
        event.preventDefault();
        this.ready = false;
        this.canvas.hidden = true;
        this.synchronize();
        this.engine = null;
      });
      this.canvas.addEventListener("webglcontextrestored", () => {
        this.engine = this.createEngine();
        this.setImage(this.source);
      });
    }

    createEngine() {
      try {
        return new window.Kawarp(this.canvas, {
          warpIntensity: 1, blurPasses: 8, animationSpeed: .1, saturation: 1.5,
          dithering: .008, transitionDuration: 500, tintIntensity: 0, scale: 1
        });
      } catch (_) { return null; }
    }

    setImage(source) {
      this.source = source;
      this.ready = false;
      if (source && this.engine) {
        try {
          // Static/reduced-motion users receive the current art immediately.
          // Playing uses the PC's 500ms first / 1000ms subsequent crossfade.
          this.engine.transitionDuration = this.wanted ? (this.loadedOnce ? 1000 : 500) : 0;
          this.engine.loadImageElement(source);
          this.loadedOnce = true;
          this.ready = true;
          this.paint();
        } catch (_) { /* A tainted or unreadable image uses the static CSS fallback. */ }
      }
      this.canvas.hidden = !this.ready;
      this.synchronize();
      return this.ready;
    }

    setMotion(active, speed) {
      this.wanted = !!active;
      this.speed = Math.max(.1, Math.min(5, Number(speed) / 100 || 1));
      this.synchronize();
    }

    synchronize() {
      const active = !!(this.wanted && this.ready && this.engine);
      if (active === this.active) return;
      this.active = active;
      this.lastTime = active ? performance.now() : null;
      if (active && !this.request) this.request = requestAnimationFrame(this.tick);
      if (!active && this.request) {
        cancelAnimationFrame(this.request);
        this.request = 0;
      }
    }

    tick(now) {
      this.request = 0;
      if (!this.active) return;
      const dt = Math.max(0, now - this.lastTime) / 1000;
      this.lastTime = now;
      // Identical to Kawarp's renderLoop clock. Owning scheduling here permits
      // frozen static frames and lifecycle suspension without a resume jump.
      this.rate += (this.speed - this.rate) * .05;
      this.phase += dt * this.rate;
      this.paint();
      this.request = requestAnimationFrame(this.tick);
    }

    paint() {
      if (this.ready && this.engine) this.engine.renderFrame(this.phase);
    }
  }

  window.SpicyGradientField = GradientField;
})();
