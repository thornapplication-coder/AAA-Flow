import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// Standalone PWA (Spec Abschnitt 3). Desktop ist Leitplattform, Tablet und
// iPhone werden reduziert bedient. Icons und Farben werden mit dem Logo
// nachgeliefert (Spec Abschnitt 15, Punkt 3).
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon.svg'],
      manifest: {
        name: 'AAA Flow',
        short_name: 'AAA Flow',
        description: 'Gate-Steuerung für Trainingsvorgänge — Aviation Academy Austria',
        lang: 'de',
        display: 'standalone',
        start_url: '/',
        theme_color: '#0b1f3a',
        background_color: '#f4f6fa',
        icons: [{ src: 'icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' }],
      },
      workbox: {
        navigateFallbackDenylist: [/^\/auth\//],
      },
    }),
  ],
  server: { port: 5173 },
})
