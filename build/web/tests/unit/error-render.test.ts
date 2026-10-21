import { describe, expect, it } from 'vitest';
import { ERROR_PAGES } from '../../src/error/pages.ts';
import { renderErrorPage } from '../../src/error/render.ts';

const SHELL =
  '<main>__GW_TITLE__ __GW_STATUS__ __GW_STATUS_TEXT__ __GW_HEADING__ __GW_BODY__ __GW_CONTEXT__</main>' +
  '<footer>Powered__GW_STATUS_LINK__</footer>';

describe('renderErrorPage', () => {
  it('includes the context line and status link when /_status/public exists', () => {
    const html = renderErrorPage(SHELL, '502', ERROR_PAGES['502'], 'Site', true);
    expect(html).toContain('id="ctx"');
    expect(html).toContain('href="/_status"');
    expect(html).not.toContain('__GW_');
  });

  it('omits both when it does not', () => {
    const html = renderErrorPage(SHELL, '502', ERROR_PAGES['502'], 'Site', false);
    expect(html).not.toContain('id="ctx"');
    expect(html).not.toContain('/_status');
    expect(html).not.toContain('__GW_');
  });
});
