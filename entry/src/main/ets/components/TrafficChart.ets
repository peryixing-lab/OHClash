@Component
export struct TrafficChart {
  @StorageProp('themeDark') @Watch('redraw') dark: boolean = true;
  @Prop @Watch('redraw') samples: number[] = [];
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  private redraw(): void {
    if (!this.ready) { return; }
    const ctx = this.context;
    const w = ctx.width;
    const h = ctx.height;
    if (w <= 0 || h <= 0) { return; }
    ctx.clearRect(0, 0, w, h);
    const values = new Array<number>(60).fill(0);
    const recent = this.samples.slice(-60);
    recent.forEach((value: number, index: number) => { values[60 - recent.length + index] = Math.max(0, value); });
    const peak = Math.max(1024, ...values) * 1.15;
    const xs = values.map((_: number, i: number): number => i * w / 59);
    const ys = values.map((value: number): number => h * 0.74 - value / peak * h * 0.65);
    ctx.beginPath();
    ctx.moveTo(0, ys[0]);
    for (let i = 1; i < values.length - 1; i++) {
      ctx.quadraticCurveTo(xs[i], ys[i], (xs[i] + xs[i + 1]) / 2, (ys[i] + ys[i + 1]) / 2);
    }
    ctx.lineTo(w, ys[59]);
    ctx.strokeStyle = this.dark ? '#ECD8DE' : '#805160';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.lineTo(w, h);
    ctx.lineTo(0, h);
    ctx.closePath();
    const gradient = ctx.createLinearGradient(0, 0, 0, h);
    gradient.addColorStop(0, this.dark ? 'rgba(236, 216, 222, 0.38)' : 'rgba(128, 81, 96, 0.22)');
    gradient.addColorStop(1, this.dark ? 'rgba(236, 216, 222, 0.08)' : 'rgba(128, 81, 96, 0.03)');
    ctx.fillStyle = gradient;
    ctx.fill();
  }

  build() {
    Canvas(this.context).width('100%').height('100%')
      .onReady(() => { this.ready = true; this.redraw(); })
      .onAreaChange(() => { this.redraw(); })
      .accessibilityText('最近 60 次采样的实际上传与下载总速度');
  }
}

@Component
export struct TrafficRing {
  @StorageProp('themeDark') @Watch('redraw') dark: boolean = true;
  @Prop @Watch('redraw') upload: number = 0;
  @Prop @Watch('redraw') download: number = 0;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;

  private redraw(): void {
    if (!this.ready) { return; }
    const ctx = this.context;
    const size = Math.min(ctx.width, ctx.height);
    const radius = size / 2 - 6;
    if (radius <= 0) { return; }
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    ctx.lineWidth = 10;
    ctx.lineCap = 'round';
    const total = this.upload + this.download;
    const start = -Math.PI / 2;
    const end = start + Math.PI * 2;
    const fraction = total > 0 ? this.upload / total : 0;
    if (fraction > 0) {
      ctx.beginPath();
      ctx.strokeStyle = this.dark ? '#ECD8DE' : '#805160';
      ctx.arc(size / 2, size / 2, radius, start + 0.24, Math.max(start + 0.24, start + Math.PI * 2 * fraction - 0.24));
      ctx.stroke();
    }
    if (fraction < 1) {
      ctx.beginPath();
      ctx.strokeStyle = this.dark ? '#756E70' : '#C4B6BC';
      ctx.arc(size / 2, size / 2, radius, Math.min(end - 0.24, start + Math.PI * 2 * fraction + 0.24), end - 0.24);
      ctx.stroke();
    }
  }

  build() {
    Canvas(this.context).width(62).height(62)
      .onReady(() => { this.ready = true; this.redraw(); })
      .onAreaChange(() => { this.redraw(); })
      .accessibilityText(`上传 ${this.upload} 字节，下载 ${this.download} 字节`);
  }
}
