import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://runlang.dev',
  legacy: {
    collections: true,
  },
  integrations: [
    starlight({
      title: 'Run',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/marsolab/runlang' },
      ],
      sidebar: [
        {
          label: 'Language Tour',
          items: [
            { label: 'Introduction', slug: 'tour/00-introduction' },
            { label: 'Hello World', slug: 'tour/01-hello-world' },
            { label: 'Packages', slug: 'tour/02-packages' },
            { label: 'Types', slug: 'tour/03-types' },
            { label: 'Imports', slug: 'tour/04-imports' },
            { label: 'Variables', slug: 'tour/05-variables' },
            { label: 'Constants', slug: 'tour/06-constants' },
            { label: 'Functions', slug: 'tour/07-functions' },
            { label: 'For Loops', slug: 'tour/08-for-loops' },
            { label: 'If / Else', slug: 'tour/09-if-else' },
            { label: 'Switch', slug: 'tour/10-switch' },
            { label: 'Defer', slug: 'tour/11-defer' },
            { label: 'Pointers', slug: 'tour/12-pointers' },
            { label: 'Structs', slug: 'tour/13-structs' },
            { label: 'Slices', slug: 'tour/14-slices' },
            { label: 'Maps', slug: 'tour/15-maps' },
            { label: 'Strings', slug: 'tour/16-strings' },
            { label: 'Methods', slug: 'tour/17-methods' },
            { label: 'Interfaces', slug: 'tour/18-interfaces' },
            { label: 'Sum Types', slug: 'tour/19-sum-types' },
            { label: 'Nullable Types', slug: 'tour/20-nullable-types' },
            { label: 'New Types', slug: 'tour/21-new-types' },
            { label: 'Error Handling', slug: 'tour/22-error-handling' },
            { label: 'Closures', slug: 'tour/23-closures' },
            { label: 'Concurrency', slug: 'tour/24-concurrency' },
            { label: 'Channels', slug: 'tour/25-channels' },
            { label: 'Memory Model', slug: 'tour/26-memory-model' },
            { label: 'Type Conversions', slug: 'tour/27-type-conversions' },
            { label: 'Operators', slug: 'tour/28-operators' },
            { label: 'Break / Continue', slug: 'tour/29-break-continue' },
            { label: 'Index Iteration', slug: 'tour/30-index-iteration' },
            { label: 'Visibility & Modules', slug: 'tour/31-visibility-modules' },
            { label: 'Error Sets', slug: 'tour/32-error-sets' },
            { label: 'Unsafe', slug: 'tour/33-unsafe' },
            { label: 'Allocators', slug: 'tour/34-allocators' },
            { label: 'Testing', slug: 'tour/35-testing' },
            { label: 'Project Structure', slug: 'tour/36-project-structure' },
            { label: 'Standard Library', slug: 'tour/37-standard-library' },
            { label: 'Design Philosophy', slug: 'tour/38-design-philosophy' },
            { label: "What's Next", slug: 'tour/39-whats-next' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Specification', slug: 'reference/specification' },
            { label: 'Compiler Status', slug: 'reference/compiler-status' },
          ],
        },
        {
          label: 'Runtime',
          autogenerate: { directory: 'runtime' },
        },
      ],
      customCss: ['./src/styles/custom.css'],
    }),
    react(),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
