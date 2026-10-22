/**
 * Instance-theme readers shared across pages that mirror the Gramps Web
 * instance's look: the status page and the error pages.
 * Bundled directly into each entry by Vite.
 *
 * Readers only: this module touches localStorage and nothing else.
 * Applying the values (CSS custom properties, data-theme, iframe theming)
 * differs per page and stays there. Approximate by design: seed colors are
 * used directly rather than reproducing the full Material 3 tonal scheme.
 */

export const DEFAULT_PRIMARY = '#6d4c41';
export const DEFAULT_SECONDARY = '#0277bd';

/** Tree id from the JWT, used to pick tree-specific settings below. */
export function treeIdFromToken(): string | null {
  try {
    const token = localStorage.getItem('access_token');
    if (!token) return null;
    const payloadSegment = token.split('.')[1];
    if (!payloadSegment) return null;
    const base64 = payloadSegment.replace(/-/g, '+').replace(/_/g, '/');
    const payload = JSON.parse(atob(base64)) as { tree?: string };
    return payload.tree ?? null;
  } catch {
    return null;
  }
}

/**
 * Gramps Web's getSettings(): tree-independent settings overlaid with the
 * current tree's settings.
 */
export function mergedSettings(): Record<string, unknown> {
  try {
    const indep = JSON.parse(localStorage.getItem('grampsjs_settings') ?? '{}') as Record<
      string,
      unknown
    >;
    const perTree = JSON.parse(localStorage.getItem('grampsjs_settings_tree') ?? '{}') as Record<
      string,
      Record<string, unknown>
    >;
    const treeId = treeIdFromToken();
    return { ...indep, ...((treeId && perTree[treeId]) || {}) };
  } catch {
    return {};
  }
}

/** The current tree's entry in the SPA's tree-config store. */
export function treeConfig(): Record<string, unknown> {
  try {
    const all = JSON.parse(localStorage.getItem('grampsjs_tree_config') ?? '{}') as Record<
      string,
      Record<string, unknown>
    >;
    return all[treeIdFromToken() ?? 'unknown'] ?? {};
  } catch {
    return {};
  }
}

export function treeColors(): { primary: string; secondary: string } {
  const cfg = treeConfig();
  return {
    primary: (cfg['frontend.primaryColor'] as string | undefined) || DEFAULT_PRIMARY,
    secondary: (cfg['frontend.secondaryColor'] as string | undefined) || DEFAULT_SECONDARY,
  };
}

export type ThemeMode = 'light' | 'dark' | 'system';

/** 'light' | 'dark' | 'system'; anything unset is 'system'. */
export function themeMode(): ThemeMode {
  const theme = mergedSettings().theme;
  return theme === 'light' || theme === 'dark' ? theme : 'system';
}

/**
 * White vs near-black text over a solid color, by luminance (matches
 * Gramps Web's own onColor()).
 */
export function onColor(hex: string): string {
  try {
    let c = hex.replace('#', '');
    if (c.length === 3) {
      c = c.charAt(0) + c.charAt(0) + c.charAt(1) + c.charAt(1) + c.charAt(2) + c.charAt(2);
    }
    const r = parseInt(c.substring(0, 2), 16);
    const g = parseInt(c.substring(2, 4), 16);
    const b = parseInt(c.substring(4, 6), 16);
    const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    return lum > 0.6 ? 'rgba(0,0,0,0.87)' : '#ffffff';
  } catch {
    return '#ffffff';
  }
}

/** True if the resolved theme mode should render dark, given the OS preference. */
export function isDark(mode: ThemeMode, prefersDark: boolean): boolean {
  return mode === 'dark' || (mode === 'system' && prefersDark);
}
