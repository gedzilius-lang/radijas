import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    proxy: {
      '/hls': 'http://stream.peoplewelike.club',
      '/api': 'http://stream.peoplewelike.club',
      '/share': 'http://stream.peoplewelike.club',
      '/og': 'http://stream.peoplewelike.club',
    },
  },
});
