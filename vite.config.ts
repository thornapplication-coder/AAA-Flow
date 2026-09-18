import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import pkg from './package.json'

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
      includeAssets: ['icon.svg', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png'],
      manifest: {
        name: 'Project Control Center',
        short_name: 'Control Center',
        description: 'Projektsteuerung der Aviation Academy Austria',
        lang: 'de',
        display: 'standalone',
        start_url: '/',
        theme_color: '#0b1f3a',
        background_color: '#f4f6fa',
        // Android verlangt 192 und 512 als PNG, iOS nimmt das SVG. Das
        // maskierbare Symbol hat einen Rand, damit kein Zuschnitt hineinschneidet.
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
          { src: 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
          { src: 'icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
        ],
      },
      workbox: {
        navigateFallbackDenylist: [/^\/auth\//],
      },
    }),
  ],
  // Die Fassung steht in package.json und nirgends sonst: so kann die
  // Oberfläche sie nicht anders angeben als der Build.
  define: { __APP_VERSION__: JSON.stringify(pkg.version) },
  server: { port: 5173 },
})
