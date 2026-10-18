import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitepress';

// The pages live outside this package, so imports made from them would not
// find its node_modules: resolve vue (and vue/server-renderer) here.
const modules = fileURLToPath(new URL('../node_modules/', import.meta.url));

// The SAFBox documentation and start page. The pages are the Markdown in
// docs/; this directory only holds the site's configuration and theme.
export default defineConfig({
  vite: {
    resolve: {
      alias: [{ find: /^vue(\/.*)?$/, replacement: `${modules}vue$1` }],
    },
  },
  srcDir: '../docs',
  srcExclude: ['upstream/**', 'adrs/**'],
  title: 'SAFBox',
  description: 'The MITRE Security Automation Framework in a box',
  lang: 'en-US',
  head: [['link', { rel: 'icon', href: '/saf-logo.svg' }]],
  themeConfig: {
    logo: '/saf-logo.svg',
    nav: [
      { text: 'Guides', link: '/guides/proxmox/build' },
      { text: 'Reference', link: '/reference/platform' },
      { text: 'saf.mitre.org', link: 'https://saf.mitre.org' },
    ],
    sidebar: [
      { text: 'Welcome', link: '/' },
      {
        text: 'Guides',
        items: [
          { text: 'Building SAFBox on Proxmox VE', link: '/guides/proxmox/build' },
          { text: 'Reaching the console (SPICE)', link: '/guides/proxmox/desktop' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Base image, disk and build host', link: '/reference/platform' },
          { text: 'How SAFBox is validated', link: '/reference/validation' },
          { text: 'The appliance layer', link: '/reference/appliance' },
          { text: 'Site CA bundles', link: '/reference/site-config' },
          { text: 'STIG hardening', link: '/reference/hardening' },
          { text: 'Tools on the box', link: '/reference/tools' },
          { text: 'Services on the box', link: '/reference/services' },
          { text: 'Accounts', link: '/reference/accounts' },
          { text: 'Troubleshooting', link: '/reference/troubleshooting' },
          { text: 'Developing SAFBox', link: '/reference/development' },
        ],
      },
      {
        text: 'Design record',
        items: [
          {
            text: 'ADR-0001: the appliance pipeline',
            link: 'https://github.com/mitre/safbox/blob/main/docs/adrs/0001-safbox-appliance-pipeline.md',
          },
        ],
      },
    ],
    search: { provider: 'local' },
    outline: [2, 3],
  },
});
