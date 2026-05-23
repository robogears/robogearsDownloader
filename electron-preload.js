// Preload — exposes a minimal, safe API to the renderer
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
    // Settings
    getSettings:    ()    => ipcRenderer.invoke('settings:get'),
    saveSettings:   (s)   => ipcRenderer.invoke('settings:save', s),
    resetSettings:  ()    => ipcRenderer.invoke('settings:reset'),
    pickFolder:     ()    => ipcRenderer.invoke('settings:pick-folder'),
    openFolder:     (p)   => ipcRenderer.invoke('open-folder', p),
    openExternal:   (url) => ipcRenderer.invoke('shell:open-external', url),

    // Update check (auto on launch + manual via Settings)
    onUpdateAvailable: (cb)  => ipcRenderer.on('update:available', (_e, payload) => cb(payload)),
    checkForUpdates:   ()    => ipcRenderer.invoke('update:check'),
    getAppVersion:     ()    => ipcRenderer.invoke('app:version'),

    // Self-install (Windows portable only — falls back to opening the
    // download URL externally on macOS / non-portable builds)
    canSelfInstall:    ()    => ipcRenderer.invoke('update:can-self-install'),
    downloadUpdate:    (url) => ipcRenderer.invoke('update:download', url),
    applyUpdate:       ()    => ipcRenderer.invoke('update:apply'),
    onUpdateDownloadProgress: (cb) => ipcRenderer.on('update:download-progress', (_e, p) => cb(p)),

    // Auth
    tokenExists:    ()    => ipcRenderer.invoke('token:exists'),
    runAuth:        ()    => ipcRenderer.invoke('token:run-auth'),
    onAuthOutput:   (cb)  => ipcRenderer.on('auth:output', (_e, l) => cb(l)),
    onAuthUrl:      (cb)  => ipcRenderer.on('auth:url', (_e, url) => cb(url)),

    // Download lifecycle (shared with the bulk flow — single-track downloads
    // also go through startBulk)
    cancelDownload: ()    => ipcRenderer.invoke('download:cancel'),
    onDownloadLine: (cb)  => ipcRenderer.on('download:line', (_e, l) => cb(l)),
    onDownloadDone: (cb)  => ipcRenderer.on('download:done', (_e, r) => cb(r)),

    // Bulk (queue of tracks → batch download)
    startBulk:      (p)   => ipcRenderer.invoke('bulk:start', p),
    onTrackStart:    (cb) => ipcRenderer.on('bulk:track-start',    (_e, p) => cb(p)),
    onTrackProgress: (cb) => ipcRenderer.on('bulk:track-progress', (_e, p) => cb(p)),
    onTrackDone:     (cb) => ipcRenderer.on('bulk:track-done',     (_e, p) => cb(p)),

    // Resolver: input → tracks for the queue
    resolveInput:   (p)   => ipcRenderer.invoke('resolve:input', p),
    cancelResolve:  ()    => ipcRenderer.invoke('resolve:cancel'),
    resolveOcr:     (p)   => ipcRenderer.invoke('resolve:ocr-tracks', p),

    // Queue persistence (across app restarts)
    getQueue:       ()    => ipcRenderer.invoke('queue:get'),
    saveQueue:      (q)   => ipcRenderer.invoke('queue:save', q),

    // Library (read-only duplicate index)
    libraryStatus:   ()  => ipcRenderer.invoke('library:status'),
    libraryRescan:   ()  => ipcRenderer.invoke('library:rescan'),
    onLibraryScanned: (cb) => ipcRenderer.on('library:scanned', (_e, p) => cb(p)),
    onLibraryScanProgress: (cb) => ipcRenderer.on('library:scan-progress', (_e, p) => cb(p)),
});
