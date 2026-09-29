import { defineConfig } from 'vite'

export default defineConfig({
  server: { fs: { allow: ['..'] } },
  build: { target: 'es2022', assetsInlineLimit: 0 },
})
