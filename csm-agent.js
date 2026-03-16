#!/usr/bin/env node
// CSM Hub Node Agent — Lightweight standalone agent
// Connects to the CSM Hub via WebSocket, reports system metrics,
// and runs tmux session commands from the hub.
//
// Environment variables (from /etc/csm-agent.env, chmod 600):
//   CSM_HUB_URL     - WebSocket URL (ws://hub-ip:7780/ws/node)
//   CSM_AUTH_TOKEN   - Bearer auth token
//   CSM_HOSTNAME     - Node hostname to register as

const WebSocket = require('ws');
const os = require('os');
const { execFileSync } = require('child_process');

const HUB_URL = process.env.CSM_HUB_URL;
const AUTH_TOKEN = process.env.CSM_AUTH_TOKEN;
const HOSTNAME = process.env.CSM_HOSTNAME || os.hostname();

if (!HUB_URL || !AUTH_TOKEN) {
  console.error('[csm-agent] Error: CSM_HUB_URL and CSM_AUTH_TOKEN must be set');
  process.exit(1);
}

// Sanitize names to prevent injection — only allow safe chars
function safeName(name) {
  return String(name || '').replace(/[^a-zA-Z0-9_.-]/g, '-').slice(0, 64);
}

function getResources() {
  try {
    const loadavg = os.loadavg()[0];
    const cpuCount = os.cpus().length || 1;
    const cpuPct = Math.min(Math.round((loadavg / cpuCount) * 100), 100);
    const ramFreeMb = Math.round(os.freemem() / 1024 / 1024);
    let diskPct = 0;
    try {
      const out = execFileSync('df', ['/', '--output=pcent'], { encoding: 'utf8', timeout: 5000 });
      diskPct = parseInt(out.split('\n')[1]) || 0;
    } catch {}
    return { cpuPct, ramFreeMb, diskPct, maxSessions: 8 };
  } catch {
    return { cpuPct: 0, ramFreeMb: Math.round(os.freemem() / 1024 / 1024), diskPct: 0, maxSessions: 8 };
  }
}

function getTmuxSessions() {
  try {
    const out = execFileSync('tmux', ['list-sessions', '-F', '#{session_name}'], { encoding: 'utf8', timeout: 5000 });
    return out.trim().split('\n').filter(Boolean);
  } catch { return []; }
}

let nodeId = null;
let hbTimer = null;

function sendEvent(ws, sessionId, eventType, data) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'session-event', payload: { sessionId, eventType, timestamp: new Date().toISOString(), data } }));
  }
}

function handleCommand(ws, payload) {
  const { commandType, args } = payload;
  console.log('[csm-agent] Command:', commandType);
  try {
    switch (commandType) {
      case 'create-session': {
        const n = safeName(args.name || args.sessionId);
        execFileSync('tmux', ['new-session', '-d', '-s', n, '-c', args.workingDir || '/tmp'], { timeout: 10000 });
        sendEvent(ws, args.sessionId, 'state-change', { newState: 'active' });
        break;
      }
      case 'kill-session': {
        const n = safeName(args.name || args.sessionId);
        execFileSync('tmux', ['kill-session', '-t', n], { timeout: 5000 });
        break;
      }
      case 'send-keys': {
        const n = safeName(args.name);
        execFileSync('tmux', ['send-keys', '-t', n, args.keys || ''], { timeout: 5000 });
        break;
      }
      case 'capture-pane': {
        const n = safeName(args.name);
        const output = execFileSync('tmux', ['capture-pane', '-t', n, '-p'], { encoding: 'utf8', timeout: 5000 });
        sendEvent(ws, args.name, 'terminal-output', { output });
        break;
      }
    }
  } catch (err) { console.error('[csm-agent] Failed:', err.message); }
}

function connect() {
  console.log('[csm-agent] Connecting to', HUB_URL, 'as', HOSTNAME);
  const ws = new WebSocket(HUB_URL, { headers: { Authorization: 'Bearer ' + AUTH_TOKEN }, handshakeTimeout: 10000 });

  ws.on('open', () => {
    ws.send(JSON.stringify({ type: 'register', payload: { hostname: HOSTNAME, platform: os.platform(), protocolVersion: 1, agentVersion: '1.0.0', resources: getResources(), activeSessions: getTmuxSessions() } }));
    if (hbTimer) clearInterval(hbTimer);
    hbTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'heartbeat', payload: { nodeId: nodeId || HOSTNAME, resources: getResources(), activeSessions: getTmuxSessions() } }));
    }, 30000);
  });

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'registered') { nodeId = msg.payload.nodeId; console.log('[csm-agent] Registered:', nodeId); }
      else if (msg.type === 'relay-command') handleCommand(ws, msg.payload);
    } catch {}
  });

  ws.on('close', () => { if (hbTimer) { clearInterval(hbTimer); hbTimer = null; } console.log('[csm-agent] Reconnecting in 5s...'); setTimeout(connect, 5000); });
  ws.on('error', (err) => console.error('[csm-agent] Error:', err.message));
}

process.on('SIGTERM', () => { if (hbTimer) clearInterval(hbTimer); process.exit(0); });
process.on('SIGINT', () => { if (hbTimer) clearInterval(hbTimer); process.exit(0); });

connect();
