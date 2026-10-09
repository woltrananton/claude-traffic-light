// Two jobs for the traffic light:
// 1. Registers which terminals (shell pid) exist in this window and what the window is called,
//    in ~/.claude/trafficlight-windows/<pid>.json. The tray app uses it to find the right
//    VS Code window, since all windows share the same process.
// 2. Watches ~/.claude/trafficlight-focus, which the tray app writes when a dot is clicked
//    ("<shell-pid> <timestamp ms>"), and shows the terminal tab if it is in this window.
//    For background agents, a "claude attach <session-id>" tab is opened instead.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

const focusFile = path.join(os.homedir(), '.claude', 'trafficlight-focus');
const registryDir = path.join(os.homedir(), '.claude', 'trafficlight-windows');
const registryFile = path.join(registryDir, `${process.pid}.json`);
let lastStamp = 0;

async function writeRegistry() {
  const pids = (await Promise.all(vscode.window.terminals.map((t) => t.processId))).filter(Boolean);
  try {
    fs.mkdirSync(registryDir, { recursive: true });
    // The window title contains the workspace name: "... - <name> - Visual Studio Code"
    fs.writeFileSync(registryFile, JSON.stringify({ name: vscode.workspace.name || '', terminals: pids }));
  } catch {}
}

// "<shell-pid> <timestamp>" or, for background agents, "<shell-pid> <timestamp> <session-id> <label>"
function readRequest() {
  try {
    const [pid, stamp, sessionId, label] = fs.readFileSync(focusFile, 'utf8').trim().split(/\s+/);
    return { pid: Number(pid), stamp: Number(stamp), sessionId, label };
  } catch {
    return null;
  }
}

function claudePath() {
  const local = path.join(os.homedir(), '.local', 'bin', 'claude.exe');
  return fs.existsSync(local) ? local : 'claude';
}

function isAttachTerminal(terminal) {
  const args = terminal.creationOptions.shellArgs;
  return Array.isArray(args) && args[0] === 'attach';
}

// Background agents have no terminal of their own - they're shown with "claude attach" in a separate tab
// in the editor area, next to the terminal agent view runs in. The tab is reused on the next click.
function showAttachTerminal(sessionId, label, parentTerminal) {
  // "claude attach" wants the short id (first 8 characters), not the full session id
  const jobId = sessionId.slice(0, 8);
  const existing = vscode.window.terminals.find((t) =>
    !t.exitStatus && isAttachTerminal(t) && t.creationOptions.shellArgs.includes(jobId));
  if (existing) {
    existing.show(false);
    return;
  }
  // First show the terminal that started the agents, so its editor group becomes active
  // and the new tab ends up in the same group
  parentTerminal.show(false);
  const terminal = vscode.window.createTerminal({
    name: `Claude ${label || jobId}`,
    shellPath: claudePath(),
    shellArgs: ['attach', jobId],
    location: { viewColumn: vscode.ViewColumn.Active },
  });
  terminal.show(false);
}

// Close the attach tab when you leave the agent (Ctrl+Z). On error it stays open so the message is visible.
function closeFinishedAttach(terminal) {
  if (isAttachTerminal(terminal) && terminal.exitStatus && !terminal.exitStatus.code) {
    terminal.dispose();
  }
}

async function handleRequest() {
  const req = readRequest();
  if (!req || !req.pid || req.stamp <= lastStamp) return;
  lastStamp = req.stamp;
  // Old requests (e.g. from before the window opened) shouldn't switch tabs
  if (Date.now() - req.stamp > 5000) return;

  for (const terminal of vscode.window.terminals) {
    if ((await terminal.processId) === req.pid) {
      if (req.sessionId) showAttachTerminal(req.sessionId, req.label, terminal);
      else terminal.show(false);
      return;
    }
  }
}

function activate(context) {
  const existing = readRequest();
  if (existing) lastStamp = existing.stamp;

  writeRegistry();
  context.subscriptions.push(
    vscode.window.onDidOpenTerminal(writeRegistry),
    vscode.window.onDidCloseTerminal((t) => { closeFinishedAttach(t); writeRegistry(); }),
    vscode.workspace.onDidChangeWorkspaceFolders(writeRegistry),
  );

  // watchFile (polling) is more reliable than fs.watch on Windows
  fs.watchFile(focusFile, { interval: 200 }, () => { handleRequest(); });
  context.subscriptions.push({ dispose: () => fs.unwatchFile(focusFile) });
}

function deactivate() {
  try { fs.unlinkSync(registryFile); } catch {}
}

module.exports = { activate, deactivate };
