#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import fetch from "node-fetch";
import { exec } from "child_process";
import path from "path";
import { fileURLToPath } from "url";

// Get the directory of the current module
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration
const LOCAL_APP_URL = "http://localhost:8080";
const MAX_RETRY_ATTEMPTS = 30; // Maximum number of attempts to check if the app is ready
const RETRY_DELAY = 2000; // Delay between retries in milliseconds
const APP_NAME = "location-getter-agent.app";

// Track the app process for proper cleanup
let appProcess: { pid?: string } = {};

/**
 * Start the macOS application
 * @returns Promise that resolves when the app is launched
 */
async function startMacOSApp(): Promise<void> {
  // Construct the absolute path to the .app bundle
  const appPath = path.join(__dirname, "..", APP_NAME);
  console.error(`Starting macOS app at: ${appPath}`);

  return new Promise((resolve, reject) => {
    // Use the 'open' command to launch the .app bundle
    exec(`open "${appPath}"`, (error) => {
      if (error) {
        console.error(`Failed to launch app: ${error.message}`);
        reject(error);
        return;
      }

      // Find the app process ID for later termination
      exec(
        `ps -A | grep "${APP_NAME}" | grep -v grep | awk '{print $1}'`,
        (err, stdout) => {
          if (!err && stdout.trim()) {
            appProcess.pid = stdout.trim();
            console.error(`App launched with PID: ${appProcess.pid}`);
          }
          console.error(`App launch command executed successfully`);
          resolve();
        },
      );
    });
  });
}

/**
 * Kill the macOS application
 */
async function killMacOSApp(): Promise<void> {
  if (appProcess.pid) {
    console.error(`Terminating app with PID: ${appProcess.pid}`);
    return new Promise((resolve) => {
      exec(`pkill -P ${appProcess.pid} || kill ${appProcess.pid}`, () => {
        appProcess = {};
        resolve();
      });
    });
  } else {
    // Try to find and kill the app by name if we don't have the PID
    return new Promise((resolve) => {
      exec(`pkill -f "${APP_NAME}"`, () => {
        resolve();
      });
    });
  }
}

/**
 * Check if the local app is ready by sending a request to it
 * @returns Promise that resolves when the app is ready
 */
async function waitForLocalApp(): Promise<void> {
  console.error(`Waiting for location app to be ready at ${LOCAL_APP_URL}...`);

  // First, start the macOS app
  try {
    await startMacOSApp();
  } catch (error: any) {
    throw new Error(`Failed to start the location app: ${error.message}`);
  }

  // Then wait for the HTTP server to be ready
  for (let attempt = 1; attempt <= MAX_RETRY_ATTEMPTS; attempt++) {
    try {
      const response = await fetch(LOCAL_APP_URL, {
        method: "GET",
      });

      if (response.ok) {
        console.error(`Location app is ready (after ${attempt} attempts)`);
        return;
      }
    } catch (error: any) {
      // Intentionally catch and ignore the error - we'll retry
    }

    console.error(
      `Attempt ${attempt}/${MAX_RETRY_ATTEMPTS} failed. Retrying in ${RETRY_DELAY / 1000} seconds...`,
    );
    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY));
  }

  throw new Error(
    `Local app is not ready after ${MAX_RETRY_ATTEMPTS} attempts. Please ensure the location-getter-agent.app is running properly.`,
  );
}

async function main() {
  try {
    // Wait for the local app to be ready before starting the MCP server
    await waitForLocalApp();

    // Create the MCP server
    const server = new McpServer({
      name: "Location Server",
      version: "1.0.0",
      capabilities: {
        tools: { listChanged: true },
      },
    });

    // Add the getCurrentLocation tool
    server.tool(
      "getCurrentLocation",
      {}, // No parameters needed for this tool
      async () => {
        try {
          const response = await fetch(LOCAL_APP_URL);

          if (!response.ok) {
            return {
              content: [
                {
                  type: "text",
                  text: `Error: Failed to get location. Status: ${response.status}`,
                },
              ],
              isError: true,
            };
          }

          const locationData = await response.text();
          return {
            content: [
              {
                type: "text",
                text: locationData,
              },
            ],
          };
        } catch (error: any) {
          return {
            content: [
              {
                type: "text",
                text: `Error: Failed to connect to location service. ${error.message}`,
              },
            ],
            isError: true,
          };
        }
      },
    );

    // Add the getCalendarEvents tool
    server.tool(
      "getCalendarEvents",
      {}, // No parameters needed for this tool
      async () => {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify([
                {
                  "@type": "Event",
                  endDate: "2025-04-12T21:15:00.000+03:00",
                  location: "Vyshniakivska Street 10\nKyiv, Ukraine",
                  name: "Doctor",
                  startDate: "2025-04-11T20:15:00.000+03:00",
                },
              ]),
            },
          ],
        };
      },
    );

    // Set up process termination handlers
    const cleanup = async () => {
      console.error("Shutting down...");
      await killMacOSApp();
      process.exit(0);
    };

    // Handle various termination signals
    process.on("SIGINT", cleanup);
    process.on("SIGTERM", cleanup);
    process.on("exit", cleanup);

    // Start the server with stdio transport
    console.error("Starting MCP Location Server...");
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error("MCP Location Server started successfully!");
  } catch (error: any) {
    console.error(`Failed to start MCP server: ${error.message}`);
    await killMacOSApp();
    process.exit(1);
  }
}

// Start the server
main();
