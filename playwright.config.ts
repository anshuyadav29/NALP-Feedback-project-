import { defineConfig, devices } from '@playwright/test';

/**
 * The application is served by the backend as a static export, so the tests run
 * against the backend rather than the Next.js dev server. A PostgreSQL instance
 * must be reachable on the connection configured in `e2e/fixtures/db.ts`.
 */
const BASE_URL = process.env.E2E_BASE_URL ?? 'http://localhost:8080';

export default defineConfig({
  testDir: './e2e',
  // Tests isolate themselves by working on their own board, so they can run in parallel
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  // Retries mask flakiness; a drag test that needs a retry is a broken test
  retries: 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never' }]]
    : [['list'], ['html', { open: 'never' }]],

  use: {
    baseURL: BASE_URL,
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        // Must come after the device preset, which carries its own 1280x720.
        // Drags need source and target visible at once, and a backlog with a
        // few categories is taller than 720px.
        viewport: { width: 1440, height: 1000 },
      },
    },
  ],

  webServer: {
    command: 'cd .. && ./gradlew bootRun',
    url: `${BASE_URL}/actuator/health`,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },
});
