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

    // Update check (fires from main on app launch if a newer release exists)
    onUpdateAvailable: (cb) => ipcRenderer.on('update:available', (_e, payload) => cb(payload)),

    // Auth
    tokenExists:    ()    => ipcRenderer.invoke('token:exists'),
    runAuth:        ()    => ipcRenderer.invoke('token:run-auth'),
    onAuthOutput:   (cb)  => ipcRenderer.on('auth:output', (_e, l) => cb(l)),

    // Download
    startDownload:  (p)   => ipcRenderer.invoke('download:start', p),
    cancelDownload: ()    => ipcRenderer.invoke('download:cancel'),
    onDownloadLine: (cb)  => ipcRenderer.on('download:line', (_e, l) => cb(l)),
    onDownloadDone: (cb)  => ipcRenderer.on('download:done', (_e, r) => cb(r)),

    // Bulk (queue of tracks → batch download)
    startBulk:      (p)   => ipcRenderer.invoke('bulk:start', p),

    // Resolver: input → tracks for the queue
    resolveInput:   (p)   => ipcRenderer.invoke('resolve:input', p),
    resolveOcr:     (p)   => ipcRenderer.invoke('resolve:ocr-tracks', p),

    // Library (read-only duplicate index)
    libraryStatus:   ()  => ipcRenderer.invoke('library:status'),
    libraryRescan:   ()  => ipcRenderer.invoke('library:rescan'),
    onLibraryScanned: (cb) => ipcRenderer.on('library:scanned', (_e, p) => cb(p)),
});
