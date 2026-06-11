#!/usr/bin/env node

/**
 * Codex Desktop IPC Refresh Broadcaster
 *
 * Purpose: Connect to Codex desktop app via IPC socket and send cache invalidation
 *          broadcasts to refresh the tasks list in real-time.
 *
 * Usage: node codex-desktop-refresh.mjs [--socket <path>]
 *        CODEX_IPC_SOCK=<path> node codex-desktop-refresh.mjs
 *
 * Exit codes:
 *   0 = Successfully sent refresh broadcasts
 *   2 = Socket not found (Codex.app not running)
 *   3 = Connection timeout
 *   4 = Process timeout (did not complete within 5000ms)
 *   5 = Socket error (ECONNREFUSED, etc.)
 */

import net from 'net';
import os from 'os';
import path from 'path';
import crypto from 'crypto';
import fs from 'fs';

// ============================================================================
// Configuration & Helpers
// ============================================================================

function getSocketPath() {
  // Command line argument takes precedence
  const argIdx = process.argv.indexOf('--socket');
  if (argIdx !== -1 && argIdx + 1 < process.argv.length) {
    return process.argv[argIdx + 1];
  }

  // Then environment variable
  if (process.env.CODEX_IPC_SOCK) {
    return process.env.CODEX_IPC_SOCK;
  }

  // Default path
  return path.join(os.tmpdir(), 'codex-ipc', `ipc-${process.getuid()}.sock`);
}

function frameFor(payload) {
  const json = JSON.stringify(payload);
  const size = Buffer.byteLength(json, 'utf8');
  const frame = Buffer.alloc(4 + size);
  frame.writeUInt32LE(size, 0);
  frame.write(json, 4, 'utf8');
  return frame;
}

function generateRequestId() {
  return crypto.randomUUID();
}

// ============================================================================
// Socket Preflight Check
// ============================================================================

function checkSocketExists(socketPath) {
  try {
    const stats = fs.statSync(socketPath);
    if (!stats.isSocket()) {
      throw new Error('not a socket');
    }
    return true;
  } catch (err) {
    return false;
  }
}

// ============================================================================
// Frame Parser (handles packet fragmentation)
// ============================================================================

class FrameParser {
  constructor() {
    this.buffer = Buffer.alloc(0);
    this.nextSize = null;
  }

  feed(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const frames = [];

    while (true) {
      // Read frame size if we haven't yet
      if (this.nextSize === null) {
        if (this.buffer.length < 4) {
          break; // Need more data
        }
        this.nextSize = this.buffer.readUInt32LE(0);

        // Sanity check: frame size must be reasonable
        if (this.nextSize > 256 * 1024 * 1024) {
          throw new Error(`frame size too large: ${this.nextSize}`);
        }

        this.buffer = this.buffer.subarray(4);
      }

      // Read frame payload
      if (this.buffer.length < this.nextSize) {
        break; // Need more data
      }

      const raw = this.buffer.subarray(0, this.nextSize);
      this.buffer = this.buffer.subarray(this.nextSize);
      this.nextSize = null;

      try {
        const payload = JSON.parse(raw.toString('utf8'));
        frames.push(payload);
      } catch (err) {
        throw new Error(`failed to parse frame JSON: ${err.message}`);
      }
    }

    return frames;
  }
}

// ============================================================================
// Main Logic
// ============================================================================

async function main() {
  const socketPath = getSocketPath();

  // Preflight: check socket exists
  if (!checkSocketExists(socketPath)) {
    console.error(`codex desktop ipc socket not found: ${socketPath} (Codex.app not running?)`);
    process.exit(2);
  }

  // Global watchdog: fail if we don't complete within 5000ms
  const watchdog = setTimeout(() => {
    console.error('codex-desktop-refresh: process timeout (5000ms exceeded)');
    process.exit(4);
  }, 5000);

  try {
    // Connect to socket
    const socket = net.createConnection(socketPath);

    // Setup error handler
    socket.on('error', (err) => {
      clearTimeout(watchdog);
      console.error(`codex-desktop-refresh: socket error: ${err.code || err.message}`);
      process.exit(5);
    });

    // Setup frame parser
    const parser = new FrameParser();
    let initializeRequestId = null;
    let clientId = 'claude-desktop-refresh'; // fallback
    let initResponseReceived = false;
    let broadcastsSent = 0;

    socket.on('data', (chunk) => {
      try {
        const frames = parser.feed(chunk);

        for (const frame of frames) {
          // Handle initialize response
          if (
            frame.type === 'response' &&
            frame.requestId === initializeRequestId &&
            !initResponseReceived
          ) {
            initResponseReceived = true;
            if (frame.result && frame.result.clientId) {
              clientId = frame.result.clientId;
            }

            // Now send the two cache invalidation broadcasts
            const broadcast1 = {
              type: 'broadcast',
              method: 'query-cache-invalidate',
              sourceClientId: clientId,
              version: 0,
              params: { queryKey: ['tasks'] },
            };

            const broadcast2 = {
              type: 'broadcast',
              method: 'query-cache-invalidate',
              sourceClientId: clientId,
              version: 0,
              params: { queryKey: ['command-menu-thread-search', 'local'] },
            };

            socket.write(frameFor(broadcast1));
            socket.write(frameFor(broadcast2));
            broadcastsSent = 2;

            // Clean up and exit
            clearTimeout(watchdog);
            socket.destroy();
            console.log(`desktop-refresh: sent (clientId=${clientId})`);
            process.exit(0);
          }

          // Handle discovery request (reply and continue waiting)
          if (frame.type === 'client-discovery-request') {
            const response = {
              type: 'client-discovery-response',
              requestId: frame.requestId,
              response: { canHandle: false },
            };
            socket.write(frameFor(response));
            continue;
          }

          // Ignore other broadcast/server messages
        }
      } catch (err) {
        clearTimeout(watchdog);
        console.error(`codex-desktop-refresh: frame parsing error: ${err.message}`);
        socket.destroy();
        process.exit(5);
      }
    });

    socket.on('connect', () => {
      // Send initialize request
      initializeRequestId = generateRequestId();
      const initPayload = {
        type: 'request',
        requestId: initializeRequestId,
        sourceClientId: 'claude-desktop-refresh',
        version: 0,
        method: 'initialize',
        params: { clientType: 'claude-desktop-refresh' },
      };

      socket.write(frameFor(initPayload));
    });

    socket.on('timeout', () => {
      clearTimeout(watchdog);
      console.error('codex-desktop-refresh: connection timeout');
      socket.destroy();
      process.exit(3);
    });

    // Set connection timeout
    socket.setTimeout(3000);
  } catch (err) {
    clearTimeout(watchdog);
    console.error(`codex-desktop-refresh: unexpected error: ${err.message}`);
    process.exit(5);
  }
}

main().catch((err) => {
  console.error(`codex-desktop-refresh: uncaught error: ${err.message}`);
  process.exit(5);
});
