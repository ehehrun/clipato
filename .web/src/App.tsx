import { site } from './site';

export default function App() {
  return <div class="page">
    <a class="skip-link" href="#main">跳至内容</a>

    <header class="header">
      <a class="brand" href="#" aria-label="Clipato 首页">
        <img src="/icon.svg" width="28" height="28" alt="" />
        <span>Clipato</span>
      </a>
      <nav aria-label="主导航">
        <a href={site.guide} target="_blank" rel="noopener noreferrer">使用指南</a>
        <a href={site.repository} target="_blank" rel="noopener noreferrer">GitHub</a>
      </nav>
    </header>

    <main id="main" class="content">
      <div class="intro">
        <p class="platform">macOS 截图与录屏工具</p>
        <h1>截图、录屏、贴图。</h1>
        <p class="description">取色、拼图、批量图像处理，<br />再加一个本地图片保管箱。</p>
        <p class="agents"><strong>支持 AI Agent 调用</strong><span>Skills / MCP / CLI</span></p>

        <div class="package-size">
          <strong>{site.downloadSize}</strong>
          <span>安装包</span>
        </div>

        <a class="download" href={site.releases} target="_blank" rel="noopener noreferrer">下载 Clipato</a>
        <p class="compatibility">macOS {site.minimumMacOS}+ · Apple Silicon / Intel</p>
        <p class="release-note">v{site.version} · 前往 GitHub Releases 选择安装包</p>
      </div>

      <figure class="preview">
        <div class="preview-stack">
          <img class="preview-back" src="/console.webp" width="1440" height="960" alt="" aria-hidden="true" decoding="async" />
          <img class="preview-middle" src="/console.webp" width="1440" height="960" alt="" aria-hidden="true" decoding="async" />
          <img class="preview-front" src="/console.webp" width="1440" height="960" alt="Clipato 实际界面：截图保管箱、收藏夹、标签及图片处理工具" decoding="async" />
        </div>
        <figcaption>Clipato · 截图保管箱</figcaption>
      </figure>
    </main>

    <footer class="footer">
      <p>本地处理。MIT 开源。</p>
      <div><a href={`mailto:${site.email}`}>意见反馈</a><a href={site.license} target="_blank" rel="noopener noreferrer">© {site.author}</a></div>
    </footer>
  </div>;
}
