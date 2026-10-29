// @ts-check
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import mdx from '@astrojs/mdx';
import { unified } from '@astrojs/markdown-remark';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'astro/config';
import { rehypeCode, remarkHeading } from 'fumadocs-core/mdx-plugins';
import {
  rehypeFumadocsElements,
  rehypeGithubAlerts,
  rehypeGuideComponents,
  remarkGuideCode,
  remarkGuideLinks,
  remarkGuideTitle,
} from './src/lib/markdown.ts';

// The guides live outside this project, in the repository's docs/guides/.
const repoRoot = fileURLToPath(new URL('..', import.meta.url));

/** @param {string} repoPath */
function isDirectory(repoPath) {
  try {
    return statSync(join(repoRoot, repoPath)).isDirectory();
  } catch {
    return false;
  }
}

// Order matters: heading ids are assigned (GitHub slugs, H1 included) before
// remarkGuideTitle removes the H1, so the ids match the anchors GitHub renders.
/** @type {import('@astrojs/markdown-remark').UnifiedProcessorOptions['remarkPlugins']} */
const remarkPlugins = [
  [remarkGuideLinks, { repoRoot, isDirectory }],
  remarkHeading,
  [remarkGuideTitle, { repoRoot }],
  // Code block titles and the `sshconfig` -> Shiki `ssh-config` fence name.
  remarkGuideCode,
];

// Static output only: Fumadocs renders as a React island, and a Cloudflare
// Worker serves `dist/` as plain files (see wrangler.toml).
export default defineConfig({
  site: 'https://docs.heeler.bybee.dev',
  build: {
    // Emit `/404.html` and `/tailscale.html` rather than `…/index.html`, so
    // Workers' asset router picks up the not-found page (same as landing/).
    format: 'file',
  },
  prefetch: { prefetchAll: true },
  markdown: {
    processor: unified({
      remarkPlugins,
      rehypePlugins: [
        rehypeGithubAlerts,
        // Steps, callouts, and the lead; before rehypeCode, while code blocks
        // are still plain <pre> elements.
        rehypeGuideComponents,
        // Fence languages Shiki does not bundle render as plain text instead
        // of failing the build.
        [rehypeCode, { fallbackLanguage: 'text' }],
        rehypeFumadocsElements,
      ],
      // GitHub renders straight quotes and dashes; smart punctuation would also
      // change heading text and therefore the anchors other guides link to.
      smartypants: false,
    }),
    // Fumadocs' rehypeCode highlights code blocks instead (light and dark themes).
    syntaxHighlight: false,
  },
  integrations: [react(), mdx({ extendMarkdownConfig: true })],
  vite: {
    plugins: [tailwindcss()],
    // Lets the image route find docs/guides/images at build time.
    define: { 'import.meta.env.HEELER_REPO_ROOT': JSON.stringify(repoRoot) },
    // The dev server reads the guides from outside the project root.
    server: { fs: { allow: [repoRoot] } },
  },
});
