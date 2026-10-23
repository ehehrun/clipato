# Clipato 产品页

SolidJS + TypeScript + Vite，静态站点，部署到 Cloudflare Workers Static Assets。

## 本地开发

需要 Node.js **22.12+**，建议使用当前 Node.js LTS。

```sh
cd .web
npm ci
npm run dev
```

打开终端显示的本地地址。`npm run build` 会先做类型检查，再输出到 `dist/`；`npm run preview` 可查看构建结果。

## 内容配置

公开产品信息与链接集中在 `src/site.ts`。下载按钮直接进入 GitHub Releases。页面在桌面端一屏展示，手机端自然纵向排列，重点介绍小体积、主要功能与 AI Agent 调用。

发布新版本时更新 `version`，并根据两种芯片的实际 DMG 大小更新 `downloadSize` 与 `index.html` 中的描述。当前 v0.1.0 的 Apple Silicon 安装包为 4,575,725 字节，Intel 为 4,902,927 字节，因此使用“安装包不到 5 MB”；此处不是 App 展开后的大小。

正式应用截图位于 `public/console.webp`，应用标识位于 `public/icon.svg`。页面使用系统字体，无外部字体、统计或广告服务。

## 部署

```sh
npm run deploy -- --dry-run
npm run deploy
```

第一条仅构建并在本地检查，无需登录 Cloudflare。第二条逐步确认 Worker 名称和账户，构建页面，然后询问是否检查登录状态。需要授权时，脚本经确认后打开 Wrangler 的浏览器登录流程。最终会显示公开生产环境目标，只有完整输入 `deploy` 才会发布；已有同名 Worker 将被更新。

查看参数：

```sh
npm run deploy -- --help
```

部署只上传 `dist/`。账户配置和日志保存在被忽略的 `.wrangler/`；可使用 Wrangler 的本机登录，或通过终端环境提供 `CLOUDFLARE_API_TOKEN` 和 `CLOUDFLARE_ACCOUNT_ID`。凭据不写入源码、命令参数或前端变量。

不要把任何密钥放进 `VITE_` 变量，它们会被打包到浏览器代码。`node_modules/`、`dist/`、`.wrangler/`、`.env*`、`.dev.vars*` 和日志已忽略。`package-lock.json` 应与源码一起保留。

静态资源通过 Cloudflare 分发，无需常驻 Node.js 服务器；本地 Node.js 仅用于开发、构建和部署。
