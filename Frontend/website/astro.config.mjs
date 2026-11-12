import { defineConfig } from 'astro/config';

// Development proxy only. Production same-origin routes are defined in vercel.json.
const developmentApiOrigin = process.env.KINGDOM_KIDS_API_ORIGIN || 'http://127.0.0.1:8100';

export default defineConfig({
  site: 'https://kingdom-kids.app',
  output: 'static',
  vite: {
    server: {
      proxy: {
        '/api': developmentApiOrigin,
      },
    },
  },
});
