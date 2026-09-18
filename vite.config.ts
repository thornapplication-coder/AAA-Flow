import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

// Standalone PWA (Abschnitt 8 der Architektur). Desktop ist Leitplattform,
// Tablet und Telefon werden reduziert bedient. Icons und Farben werden mit dem
// Logo nachgeliefert.
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      // Abschnitt 8 der Architektur: kein Neuladen mitten in einer Eingabe.
      // Eine neue Fassung meldet sich und wird auf Klick übernommen.
      registerType: 'prompt',
      includeAssets: ['icon.svg'],
      manifest: {
        name: 'Project Control Center',
        short_name: 'Control Center',
        description: 'Projektsteuerung der Aviation Academy Austria',
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
