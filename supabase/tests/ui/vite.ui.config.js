import { defineConfig } from 'vite'
export default defineConfig({
  preview: { proxy: { '/rest/v1': { target: 'http://127.0.0.1:3010', changeOrigin: true, rewrite: p => p.replace(/^\/rest\/v1/, '') } } },
})
