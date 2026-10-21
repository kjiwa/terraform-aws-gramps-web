import { describe, expect, it } from 'vitest';
import { escapeHtml } from '../../src/shared/html.ts';

describe('escapeHtml', () => {
  it('escapes the five special characters', () => {
    expect(escapeHtml(`<script>&"'</script>`)).toBe(
      '&lt;script&gt;&amp;&quot;&#39;&lt;/script&gt;',
    );
  });

  it('leaves ordinary text untouched', () => {
    expect(escapeHtml('Gramps Web')).toBe('Gramps Web');
  });
});
