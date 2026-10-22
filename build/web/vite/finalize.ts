import type { Plugin, Rollup } from 'vite';
import { DEFAULT_PRIMARY, DEFAULT_SECONDARY } from '../src/shared/theme.ts';

/**
 * Post-processes every HTML entry vite-plugin-singlefile inlines, running
 * build-time assertions and transforms across the bundle.
 *
 * Ordering matters: this must run in generateBundle AFTER
 * vite-plugin-singlefile's own generateBundle has already spliced every JS
 * chunk into its HTML entry as `<script type="module" ...>...</script>` and
 * every CSS chunk into `<style>...</style>` (see that plugin's
 * replaceScript()/replaceCss()). enforce: 'post' plus array position (after
 * viteSingleFile() in vite.shared.ts's plugins list) guarantees that
 * ordering -- Vite/Rollup runs same-named hooks pre-enforce, then
 * unenforced, then post-enforce plugins, in array order within each group.
 *
 * The </script-inside-an-inlined-script-body risk is closed by
 * vite-plugin-singlefile itself: replaceScript() escapes `</script` and `<!--`
 * inside inlined JS to `\x3C...` before splicing (see its source). CSS gets no
 * such escaping, so this plugin re-checks that narrower gap directly on the
 * final HTML, plus the type=module downgrade (below) and the per-page marker
 * assertions.
 */
export function gwFinalize(options: { requiredMarkers?: string[] } = {}): Plugin {
  const requiredMarkers = options.requiredMarkers ?? [];

  return {
    name: 'gw:finalize',
    enforce: 'post',
    generateBundle(_outputOptions, bundle) {
      for (const fileName of Object.keys(bundle)) {
        if (!/\.html?$/.test(fileName)) continue;
        const asset = bundle[fileName] as Rollup.OutputAsset;
        let html =
          typeof asset.source === 'string'
            ? asset.source
            : Buffer.from(asset.source).toString('utf-8');

        // 0. vite-plugin-singlefile's replaceCss() carries the original
        // <link> tag's other attributes (rel="stylesheet", crossorigin, ...)
        // onto the <style> it replaces it with -- meaningless on a <style>
        // element, so drop them, along with the sourcemap breadcrumb Vite
        // appends after the CSS ("/*$vite$:N*/"). Purely cosmetic; strips
        // nothing that affects behavior.
        html = html
          .replace(/<style(\s+rel="stylesheet")?(\s+crossorigin)?(\s*>)/g, '<style$3')
          .replace(/\/\*\$vite\$:\d+\*\/\s*/g, '');

        // 1. Downgrade the inlined module script(s) to plain blocking
        // scripts. vite-plugin-singlefile's default output keeps
        // type="module" (and any other original attributes, e.g.
        // crossorigin) on the tag it splices code into -- a module script
        // is deferred by the HTML spec regardless of inlining, which would
        // reintroduce the dark-mode flash theme.ts's caller is meant to
        // prevent by running before the skeleton paints. 'iife' Rollup
        // output isn't an option here (it rejects the error page's three
        // entry points), so the downgrade happens here instead.
        html = html.replace(
          /<script type="module"((?:\s+\S+?)*)>/g,
          (_match: string, rest: string) => {
            const cleaned = rest.replace(/\s+crossorigin(=("[^"]*"|'[^']*'))?/g, '');
            return `<script${cleaned}>`;
          },
        );

        // 2. Guard the one gap vite-plugin-singlefile's own JS-escaping
        // does not cover: an inlined <style> block containing a literal
        // `</style` sequence would truncate the stylesheet and spill the
        // remainder into the page as text. Scoped to style-block content
        // (not the whole document, which legitimately contains `</style`
        // once -- the tag's own close) via a non-greedy per-block scan.
        for (const block of html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)) {
          if (/<\/style/i.test(block[1] ?? '')) {
            throw new Error(
              `gwFinalize: ${fileName} has an inlined <style> block containing a literal </style sequence.`,
            );
          }
        }

        // 3. Marker assertions: this page's build-time proof that whatever
        // it depends on downstream (a mount root, a config script tag, ...)
        // actually made it into the output, in place of the two deleted
        // splice guards.
        for (const marker of requiredMarkers) {
          if (!html.includes(marker)) {
            throw new Error(`gwFinalize: ${fileName} is missing required marker: ${marker}`);
          }
        }

        // 4. At least one non-empty inlined script -- catches
        // vite-plugin-singlefile silently finding nothing to inline (a
        // misconfigured entry) independent of any page-specific marker.
        if (!/<script(?![^>]*\bsrc=)[^>]*>\s*\S[\s\S]*?<\/script>/.test(html)) {
          throw new Error(`gwFinalize: ${fileName} has no non-empty inlined <script>.`);
        }

        // 5. Brand-token CSS fallback: the two seed colors get exactly one
        // home (theme.ts's DEFAULT_PRIMARY/DEFAULT_SECONDARY).
        // Prepended so page-authored CSS can still override per-instance
        // via a later custom property assignment if a future page needs
        // one; none does yet.
        const brandVars = `:root{--gw-default-primary:${DEFAULT_PRIMARY};--gw-default-secondary:${DEFAULT_SECONDARY}}`;
        html = /<style[^>]*>/i.test(html)
          ? html.replace(/(<style[^>]*>)/i, `$1${brandVars}`)
          : html.replace(/<\/head>/i, `<style>${brandVars}</style></head>`);

        asset.source = html;
      }
    },
  };
}
