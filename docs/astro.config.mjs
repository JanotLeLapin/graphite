// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://janotlelapin.github.io',
	base: '/graphite',
	integrations: [
		starlight({
			title: 'Graphite',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/PhoenixUHC/graphite' }],
			sidebar: [
				{
					label: 'Guides',
					items: [
						// Each item here is one entry in the navigation menu.
						{ label: 'Modules', slug: 'guides/modules' },
						{ label: 'Sending Packets', slug: 'guides/packets' },
					],
				},
			],
		}),
	],
});
