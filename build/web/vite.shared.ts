import { resolve } from 'node:path';
import type { UserConfig } from 'vite';
import { viteSingleFile } from 'vite-plugin-singlefile';
import { gwFinalize } from './vite/finalize.ts';

/**
 * One factory for the error pages, each built as its own single-file bundle. viteSingleFile()'s useRecommendedBuildConfig
 * (the default) already forces cssCodeSplit:false, assetsInlineLimit:true,
 * base:"./", and assetsDir:"" via its own `config` hook -- this only sets
 * what's specific to a page: its entry point(s) and the markers gwFinalize
 * should assert survived the build.
 */
export function makeConfig(
  input: string | Record<string, string>,
  requiredMarkers: string[] = [],
): UserConfig {
  return {
    root: import.meta.dirname,
    build: {
      target: 'es2022',
      outDir: 'dist',
      emptyOutDir: false, // the three error builds share dist/
      modulePreload: false,
      rollupOptions: {
        input: typeof input === 'string' ? resolve(import.meta.dirname, input) : input,
      },
    },
    // gwFinalize's generateBundle is order:'post' and listed after viteSingleFile(), which
    // is what guarantees it runs on the already-inlined HTML -- see its own
    // header comment for the full ordering argument.
    plugins: [viteSingleFile(), gwFinalize({ requiredMarkers })],
  };
}
