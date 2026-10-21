import { escapeHtml } from '../shared/html.ts';
import type { ErrorPageCopy } from './pages.ts';

const CONTEXT_LINE = '<p class="ctx" id="ctx" aria-live="polite"></p>';
const STATUS_LINK = ' &middot; <a href="/_status">Status page</a>';

/**
 * Fills the shell for one error code. The measured-context line and the
 * status link are included only when /_status/public exists; without them
 * the page has no reserved gap and issues no fetch (main.ts finds no #ctx).
 */
export function renderErrorPage(
  shell: string,
  code: string,
  copy: ErrorPageCopy,
  title: string,
  statusPublicPage: boolean,
): string {
  return shell
    .replaceAll('__GW_CONTEXT__', statusPublicPage ? CONTEXT_LINE : '')
    .replaceAll('__GW_STATUS_LINK__', statusPublicPage ? STATUS_LINK : '')
    .replaceAll('__GW_TITLE__', escapeHtml(title))
    .replaceAll('__GW_STATUS__', escapeHtml(code))
    .replaceAll('__GW_STATUS_TEXT__', escapeHtml(copy.statusText))
    .replaceAll('__GW_HEADING__', escapeHtml(copy.heading))
    .replaceAll('__GW_BODY__', escapeHtml(copy.body));
}
