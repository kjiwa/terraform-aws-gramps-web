import { beforeEach, describe, expect, it } from 'vitest';
import {
  isDark,
  mergedSettings,
  onColor,
  themeMode,
  treeColors,
  treeIdFromToken,
} from '../../src/shared/theme.ts';

function jwt(payload: Record<string, unknown>): string {
  const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_');
  return `${b64({ alg: 'none' })}.${b64(payload)}.`;
}

beforeEach(() => {
  localStorage.clear();
});

describe('treeIdFromToken', () => {
  it('reads the tree claim out of the access token', () => {
    localStorage.setItem('access_token', jwt({ tree: 'my-tree' }));
    expect(treeIdFromToken()).toBe('my-tree');
  });

  it('returns null with no token', () => {
    expect(treeIdFromToken()).toBeNull();
  });

  it('returns null on a malformed token rather than throwing', () => {
    localStorage.setItem('access_token', 'not-a-jwt');
    expect(treeIdFromToken()).toBeNull();
  });
});

describe('mergedSettings', () => {
  it('overlays the current tree settings on top of the tree-independent ones', () => {
    localStorage.setItem('access_token', jwt({ tree: 't1' }));
    localStorage.setItem('grampsjs_settings', JSON.stringify({ theme: 'light', a: 1 }));
    localStorage.setItem('grampsjs_settings_tree', JSON.stringify({ t1: { theme: 'dark' } }));
    expect(mergedSettings()).toEqual({ theme: 'dark', a: 1 });
  });

  it('degrades to {} on unparsable storage', () => {
    localStorage.setItem('grampsjs_settings', '{not json');
    expect(mergedSettings()).toEqual({});
  });
});

describe('themeMode', () => {
  it('defaults to system when unset', () => {
    expect(themeMode()).toBe('system');
  });

  it('passes through an explicit light/dark choice', () => {
    localStorage.setItem('grampsjs_settings', JSON.stringify({ theme: 'dark' }));
    expect(themeMode()).toBe('dark');
  });

  it('treats an unrecognized value as system', () => {
    localStorage.setItem('grampsjs_settings', JSON.stringify({ theme: 'sepia' }));
    expect(themeMode()).toBe('system');
  });
});

describe('isDark', () => {
  it('is dark whenever the mode is explicitly dark, regardless of OS preference', () => {
    expect(isDark('dark', false)).toBe(true);
    expect(isDark('dark', true)).toBe(true);
  });

  it('never dark when the mode is explicitly light', () => {
    expect(isDark('light', true)).toBe(false);
  });

  it('follows the OS preference under system', () => {
    expect(isDark('system', true)).toBe(true);
    expect(isDark('system', false)).toBe(false);
  });
});

describe('treeColors', () => {
  it('falls back to the default seed colors with no tree config', () => {
    expect(treeColors()).toEqual({ primary: '#6d4c41', secondary: '#0277bd' });
  });

  it('reads the current tree entry from the tree-config store', () => {
    localStorage.setItem('access_token', jwt({ tree: 't1' }));
    localStorage.setItem(
      'grampsjs_tree_config',
      JSON.stringify({
        t1: { 'frontend.primaryColor': '#123456', 'frontend.secondaryColor': '#abcdef' },
      }),
    );
    expect(treeColors()).toEqual({ primary: '#123456', secondary: '#abcdef' });
  });
});

describe('onColor', () => {
  it('picks dark text over a light background', () => {
    expect(onColor('#ffffff')).toBe('rgba(0,0,0,0.87)');
  });

  it('picks white text over a dark background', () => {
    expect(onColor('#000000')).toBe('#ffffff');
  });

  it('expands a 3-digit hex before computing luminance', () => {
    expect(onColor('#fff')).toBe('rgba(0,0,0,0.87)');
  });

  it('degrades to white on an unparsable color', () => {
    expect(onColor('not-a-color')).toBe('#ffffff');
  });
});
