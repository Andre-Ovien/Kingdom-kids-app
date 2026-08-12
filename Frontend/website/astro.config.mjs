import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://kingdom-kids.app',
  vite: {
    server: {
      proxy: {
        '/api': 'http://127.0.0.1:8000',
      },
    },
  },
});
