import { app, BrowserWindow, dialog, Menu, session, shell } from 'electron';
import { fork, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktopRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
let window: BrowserWindow | null = null;
let backend: ChildProcess | null = null;
let origin = '';
let quitting = false;
app.setName('AGENTGATE Studio');
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => {
    if (window?.isMinimized()) window.restore();
    window?.show();
    window?.focus();
  });
  void app
    .whenReady()
    .then(start)
    .catch(() => {
      dialog.showErrorBox(
        'AGENTGATE could not start',
        'The local application server could not be started. Rebuild the desktop app, or check that its data folder is writable. Your saved projects have not been reset.',
      );
      app.quit();
    });
}
async function start() {
  const resources = app.isPackaged
    ? process.resourcesPath
    : join(desktopRoot, 'stage');
  const dataDirectory =
    process.env.AGENTGATE_DESKTOP_DATA_DIR ||
    join(app.getPath('userData'), 'workspace');
  await mkdir(dataDirectory, { recursive: true, mode: 0o700 });
  const token = randomBytes(32).toString('hex');
  const environment: NodeJS.ProcessEnv = {
    ...process.env,
    NODE_ENV: 'production',
    NEXT_TELEMETRY_DISABLED: '1',
    AGENTGATE_DATA_DIR: dataDirectory,
    PATH: [
      join(resources, 'runtime'),
      process.env.PATH ?? '/usr/bin:/bin',
    ].join(':'),
  };
  delete environment.NODE_OPTIONS;
  delete environment.ELECTRON_RUN_AS_NODE;
  const child = fork(join(resources, 'server.mjs'), [], {
    execPath: join(resources, 'runtime', 'node'),
    execArgv: [],
    env: environment,
    stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
  });
  backend = child;
  origin = await new Promise<string>((accept, reject) => {
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error('Startup deadline exceeded'));
    }, 30_000);
    const fail = () => {
      clearTimeout(timer);
      reject(new Error('Backend unavailable'));
    };
    child.once('error', fail);
    child.once('exit', fail);
    child.on('message', (value: unknown) => {
      if (typeof value !== 'object' || value === null || !('type' in value))
        return;
      if (value.type === 'failed') {
        fail();
        return;
      }
      if (
        value.type === 'ready' &&
        'port' in value &&
        typeof value.port === 'number' &&
        Number.isInteger(value.port) &&
        value.port > 0 &&
        value.port <= 65535
      ) {
        clearTimeout(timer);
        child.off('exit', fail);
        accept(`http://127.0.0.1:${value.port}`);
      }
    });
    child.send({
      type: 'start',
      token,
      directory: join(resources, 'web', 'apps', 'web'),
    });
  });
  const isolatedSession = session.fromPartition(
    `agentgate-${randomBytes(12).toString('hex')}`,
  );
  isolatedSession.setPermissionRequestHandler(
    (_contents, _permission, callback) => callback(false),
  );
  isolatedSession.setPermissionCheckHandler(() => false);
  isolatedSession.on('will-download', (event) => event.preventDefault());
  isolatedSession.webRequest.onBeforeRequest((details, callback) =>
    callback({
      cancel: !isAppUrl(details.url) && details.url !== 'about:blank',
    }),
  );
  isolatedSession.webRequest.onBeforeSendHeaders((details, callback) =>
    callback({
      requestHeaders: {
        ...details.requestHeaders,
        ...(isAppUrl(details.url) ? { 'x-agentgate-desktop': token } : {}),
      },
    }),
  );
  const createWindow = async () => {
    window = new BrowserWindow({
      width: 1320,
      height: 880,
      minWidth: 720,
      minHeight: 540,
      show: false,
      title: 'AGENTGATE Studio',
      backgroundColor: '#101115',
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 20, y: 20 },
      webPreferences: {
        session: isolatedSession,
        nodeIntegration: false,
        contextIsolation: true,
        sandbox: true,
        webSecurity: true,
        spellcheck: false,
      },
    });
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', (event, url) => {
      if (!isAppUrl(url)) {
        event.preventDefault();
        if (isGithubRun(url))
          void shell
            .openExternal(url)
            .catch(() =>
              dialog.showErrorBox(
                'Could not open GitHub',
                'Open the run from GitHub Actions in your browser.',
              ),
            );
      }
    });
    window.webContents.on('will-attach-webview', (event) =>
      event.preventDefault(),
    );
    window.on('closed', () => {
      window = null;
    });
    await window.loadURL(origin);
    window.show();
  };
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: app.name,
        submenu: [
          { role: 'about' },
          { type: 'separator' },
          { role: 'hide' },
          { role: 'hideOthers' },
          { role: 'unhide' },
          { type: 'separator' },
          { role: 'quit' },
        ],
      },
      {
        label: 'Edit',
        submenu: [
          { role: 'undo' },
          { role: 'redo' },
          { type: 'separator' },
          { role: 'cut' },
          { role: 'copy' },
          { role: 'paste' },
          { role: 'selectAll' },
        ],
      },
      {
        label: 'View',
        submenu: [
          { role: 'reload' },
          { role: 'resetZoom' },
          { role: 'zoomIn' },
          { role: 'zoomOut' },
          { role: 'togglefullscreen' },
        ],
      },
      {
        label: 'Window',
        submenu: [{ role: 'minimize' }, { role: 'zoom' }, { role: 'close' }],
      },
    ]),
  );
  await createWindow();
  child.on('exit', () => {
    if (quitting) return;
    dialog.showErrorBox(
      'Local server stopped',
      'Restart AGENTGATE to reconnect. Completed conversations are saved. Interrupted work will be marked as failed when the server restarts.',
    );
    app.quit();
  });
  app.on('activate', () => {
    if (!window) void createWindow().catch(() => app.quit());
    else window.show();
  });
}
function isAppUrl(value: string): boolean {
  try {
    return new URL(value).origin === origin;
  } catch {
    return false;
  }
}
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('before-quit', () => {
  quitting = true;
  backend?.kill('SIGTERM');
});

function isGithubRun(value: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.origin === 'https://github.com' &&
      !url.username &&
      !url.password &&
      /^\/[^/]+\/[^/]+\/actions\/runs\/\d+/.test(url.pathname)
    );
  } catch {
    return false;
  }
}
