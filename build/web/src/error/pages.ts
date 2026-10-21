/**
 * Copy for the three CloudFront custom error pages. Consumed only at build
 * time by vite.config.error.ts to materialize pages/errors/generated/*.html;
 * never shipped to the browser.
 */
export interface ErrorPageCopy {
  statusText: string;
  heading: string;
  body: string;
}

// 502 is the one a Spot replacement actually produces: the origin IP has no
// listener mid-swap, so CloudFront can't connect and returns 502 (not 504,
// which is the connected-but-timed-out case).
export const ERROR_PAGES: Record<'502' | '503' | '504', ErrorPageCopy> = {
  '502': {
    statusText: 'bad gateway',
    heading: "We'll be right back",
    body: 'The tree is briefly offline while the server restarts. Please try again in a few minutes.',
  },
  '503': {
    statusText: 'service unavailable',
    heading: "We'll be right back",
    body: 'The tree is temporarily unavailable. Please try again in a few minutes.',
  },
  '504': {
    statusText: 'gateway timeout',
    heading: "We'll be right back",
    body: 'The tree is briefly unavailable while we run an update. Please try again in a moment.',
  },
};

/**
 * The Gramps Web instance's display name, read from SITE_TITLE in the build
 * environment. Falls back to a generic name for local dev, where SITE_TITLE
 * is unset.
 */
export const TITLE = process.env.SITE_TITLE?.trim() || 'Gramps Web';

/**
 * Whether /_status/public exists (status enabled with public_reliability),
 * read from STATUS_PUBLIC_PAGE in the build environment. Unset, as in local
 * dev, means off.
 */
export const STATUS_PUBLIC_PAGE = process.env.STATUS_PUBLIC_PAGE === 'true';
