import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    proxy: {
      '/hls': 'http://stream.peoplewelike.club',
      '/api': 'http://stream.peoplewelike.club',
    },
  },
});
