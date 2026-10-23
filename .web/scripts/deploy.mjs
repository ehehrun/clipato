import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, extname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(webRoot, 'dist');
const wrangler = join(webRoot, 'node_modules/wrangler/bin/wrangler.js');
const localState = join(webRoot, '.wrangler');
const { values } = parseArgs({
  options: {
    help: { type: 'boolean', short: 'h' },
    'dry-run': { type: 'boolean' },
    name: { type: 'string' },
    'account-id': { type: 'string' },
  },
});

if (values.help) {
  console.log(`Clipato 网站 · Cloudflare Workers 静态部署

  npm run deploy                       交互式构建、检查并确认发布
  npm run deploy -- --dry-run           仅本地构建及预检，无需登录，不上传
  npm run deploy -- --name clipato      指定默认 Worker 名称
  npm run deploy -- --account-id ID     指定 Cloudflare Account ID

需要 Node.js 22.12+。先运行 npm ci 安装锁定的本地依赖。
登录状态查询及浏览器登录均会事先询问；只有输入 deploy 才会发布。
凭据使用 Wrangler 登录或 CLOUDFLARE_API_TOKEN 环境变量，不写入项目配置。
发布内容仅限 dist/；目标配置和日志保存在被 Git 忽略的 .wrangler/。`);
  process.exit(0);
}

const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 12)) {
  throw new Error('需要 Node.js 22.12 或更新版本。');
}
if (!process.env.npm_execpath) {
  throw new Error('请通过 npm run deploy 启动部署脚本。');
}
if (!values['dry-run'] && (!process.stdin.isTTY || !process.stdout.isTTY)) {
  throw new Error('正式部署需要交互式终端和明确确认。自动检查请使用 --dry-run。');
}

const childEnv = {
  ...process.env,
  WRANGLER_SEND_METRICS: 'false',
  DO_NOT_TRACK: '1',
  WRANGLER_LOG: 'log',
  WRANGLER_LOG_PATH: join(localState, 'logs', 'wrangler.log'),
  WRANGLER_OUTPUT_FILE_DIRECTORY: join(localState, 'output'),
  CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV: 'false',
};
delete childEnv.CLOUDFLARE_ENV;
delete childEnv.WRANGLER_OUTPUT_FILE_PATH;

function run(script, args, { capture = false, env = childEnv } = {}) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(process.execPath, [script, ...args], {
      cwd: webRoot,
      env,
      stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    });
    let stdout = '';
    let stderr = '';
    if (capture) {
      child.stdout.setEncoding('utf8').on('data', (data) => { stdout += data; });
      child.stderr.setEncoding('utf8').on('data', (data) => { stderr += data; });
    }
    child.on('error', reject);
    child.on('close', (code, signal) => {
      if (capture) resolveRun({ code, stdout, stderr });
      else if (code === 0) resolveRun();
      else reject(new Error(`${args[0]} 失败${signal ? `（${signal}）` : `（退出码 ${code}）`}。`));
    });
  });
}

const publicExtensions = new Set([
  '.html', '.js', '.css', '.png', '.jpg', '.jpeg', '.webp', '.avif', '.svg',
  '.ico', '.woff', '.woff2', '.ttf', '.otf', '.txt', '.json', '.xml', '.webmanifest',
]);

async function inspectAssets() {
  await access(join(dist, 'index.html'));
  const hash = createHash('sha256');
  let files = 0;
  let bytes = 0;
  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      const relative = path.slice(dist.length + 1);
      if (entry.isSymbolicLink() || entry.name.startsWith('.') || /^(?:node_modules|secrets?|credentials?|client[._-]secret|service[._-]account|private[._-]key|_worker)(?:[._-]|$)/i.test(entry.name)) {
        throw new Error(`拒绝发布非公开资源：${relative}`);
      }
      if (entry.isDirectory()) {
        await visit(path);
      } else if (entry.isFile()) {
        if (!publicExtensions.has(extname(entry.name).toLowerCase()) && !['_headers', '_redirects'].includes(entry.name)) {
          throw new Error(`dist 包含非发布文件：${relative}。请移除源文件、映射和私密配置。`);
        }
        const content = await readFile(path);
        hash.update(relative).update('\0').update(content).update('\0');
        files += 1;
        bytes += content.byteLength;
      } else {
        throw new Error(`不支持的资源类型：${relative}`);
      }
    }
  }
  if (!(await lstat(dist)).isDirectory()) throw new Error('dist 必须是静态构建目录，不能使用符号链接。');
  await visit(dist);
  return { files, bytes, digest: hash.digest('hex') };
}

let prompt;
let targetDirectory;
try {
  await access(wrangler);
  const source = JSON.parse(await readFile(join(webRoot, 'wrangler.jsonc'), 'utf8'));
  if (source.main || source.routes || source.route || resolve(webRoot, source.assets.directory) !== dist) {
    throw new Error('此脚本只支持 dist 静态站点；请保持 wrangler.jsonc 的静态资源配置。');
  }
  let name = values.name ?? source.name;
  let accountId = values['account-id'] ?? process.env.CLOUDFLARE_ACCOUNT_ID ?? '';
  if (!values['dry-run']) {
    prompt = createInterface({ input: process.stdin, output: process.stdout });
    name = (await prompt.question(`Worker 名称 [${name}]：`)).trim() || name;
    accountId = (await prompt.question(`Account ID [${accountId || '留空后选择登录账户'}]：`)).trim() || accountId;
  }
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(name)) throw new Error('Worker 名称须为 1–63 个小写字母、数字或连字符，且以字母或数字开头。');
  if (accountId && !/^[a-f0-9]{32}$/i.test(accountId)) throw new Error('Account ID 须为 32 位十六进制字符。');

  await mkdir(localState, { recursive: true, mode: 0o700 });
  targetDirectory = await mkdtemp(join(localState, 'deploy-'));
  const configPath = join(targetDirectory, 'wrangler.json');
  const config = {
    ...source,
    $schema: join(webRoot, 'node_modules/wrangler/config-schema.json'),
    name,
    assets: { ...source.assets, directory: dist },
  };
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  console.log('\n构建并检查静态资源…');
  await run(process.env.npm_execpath, ['run', 'build']);
  const assets = await inspectAssets();
  console.log(`已检查 ${assets.files} 个文件，${(assets.bytes / 1024).toFixed(1)} KB；无源码映射、隐藏文件或非公开文件类型。`);
  await run(wrangler, ['deploy', '--config', configPath, '--dry-run', '--autoconfig=false', '--install-skills=false'], { env: { ...childEnv, CI: 'true' } });
  if (values['dry-run']) {
    console.log('\n本地预检通过。未登录、未上传、未发布。');
  } else {
    const check = (await prompt.question('\n检查 Cloudflare 登录状态（联网，不上传站点）？[y/N] ')).trim().toLowerCase();
    if (check !== 'y') {
      console.log('已取消，未发布。');
    } else {
      async function whoami() {
        const result = await run(wrangler, ['whoami', '--json', '--config', configPath, '--install-skills=false'], { capture: true, env: { ...childEnv, CI: 'true' } });
        if (result.stderr) process.stderr.write(result.stderr);
        const identity = JSON.parse(result.stdout);
        if (result.code !== 0 && identity.loggedIn !== false) throw new Error(`登录状态查询失败（退出码 ${result.code}）。`);
        return identity;
      }
      let identity = await whoami();
      if (!identity.loggedIn) {
        const login = (await prompt.question('未登录。允许 Wrangler 打开浏览器进行 Cloudflare 登录？[y/N] ')).trim().toLowerCase();
        if (login !== 'y') throw new Error('未登录，已停止部署。');
        await run(wrangler, ['login', '--install-skills=false']);
        identity = await whoami();
        if (!identity.loggedIn) throw new Error('Cloudflare 登录未完成，已停止部署。');
      }
      if (!accountId) {
        if (identity.accounts.length === 0) throw new Error('未找到可用账户，请使用 --account-id 指定有部署权限的账户。');
        identity.accounts.forEach((account, index) => console.log(`${index + 1}. ${account.name} · ${account.id}`));
        const choice = (await prompt.question(`选择账户 [${identity.accounts.length === 1 ? '1' : '输入序号'}]：`)).trim();
        const index = choice === '' && identity.accounts.length === 1 ? 0 : Number(choice) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= identity.accounts.length) throw new Error('无效的账户序号。');
        accountId = identity.accounts[index].id;
      }
      config.account_id = accountId;
      await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
      console.log(`\n目标：Cloudflare Workers / ${name}\n账户：${accountId}\n内容：dist/ · ${assets.files} 个文件\n可见性：公开 workers.dev 网站\n操作：发布到生产环境；同名 Worker 将被更新。`);
      const confirmation = await prompt.question('\n输入 deploy 确认发布，其他输入取消：');
      if (confirmation !== 'deploy') {
        console.log('已取消，未发布。');
      } else {
        const current = await inspectAssets();
        if (current.digest !== assets.digest) throw new Error('确认期间构建内容已变化，请重新运行部署脚本。');
        await run(wrangler, ['deploy', '--config', configPath, '--autoconfig=false', '--install-skills=false'], { env: { ...childEnv, CI: 'true', CLOUDFLARE_ACCOUNT_ID: accountId } });
      }
    }
  }
} catch (error) {
  console.error(`\n部署停止：${error.message}`);
  process.exitCode = 1;
} finally {
  prompt?.close();
  if (targetDirectory) await rm(targetDirectory, { recursive: true });
}
