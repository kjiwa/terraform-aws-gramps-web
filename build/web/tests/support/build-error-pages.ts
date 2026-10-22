/**
 * Builds the 502 error page with and without STATUS_PUBLIC_PAGE into
 * dist/e2e-error/{on,off}, so the error-page spec tests both shapes of the
 * shipped bundle regardless of how `npm run build` was invoked.
 */
import { execFileSync } from 'node:child_process';

export default function globalSetup(): void {
  for (const [dir, flag] of [
    ['on', 'true'],
    ['off', 'false'],
  ] as const) {
    execFileSync(
      'npx',
      [
        '--no-install',
        'vite',
        'build',
        '--config',
        'vite.config.error.ts',
        '--outDir',
        `dist/e2e-error/${dir}`,
      ],
      {
        env: { ...process.env, GW_ERROR_CODE: '502', STATUS_PUBLIC_PAGE: flag },
        stdio: 'pipe',
      },
    );
  }
}
