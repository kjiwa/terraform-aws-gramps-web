/**
 * Escapes text for safe interpolation into HTML markup. Used at build time
 * (vite.config.error.ts, substituting Terraform-and-CodeBuild-sourced
 * config like SITE_TITLE into the generated error pages) rather than at
 * runtime -- these pages have no server-side render, so "build time" is the
 * only time this ever runs.
 */
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
