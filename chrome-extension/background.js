// Background service worker — minimal. Just opens the options page when the
// content script asks it to (content scripts can't call openOptionsPage
// themselves — that's a background-only API).

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.action === 'open-options') {
        chrome.runtime.openOptionsPage();
        sendResponse({ ok: true });
        return true;  // keep message channel alive briefly for the response
    }
    return false;
});

// First-install convenience: open the options page automatically so the user
// knows where to paste the token. Skipped on update so we don't pester them.
chrome.runtime.onInstalled.addListener((details) => {
    if (details.reason === 'install') {
        chrome.runtime.openOptionsPage();
    }
});
