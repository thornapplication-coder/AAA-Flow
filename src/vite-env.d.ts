/// <reference types="vite/client" />
/// <reference types="vite-plugin-pwa/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string
  readonly VITE_SUPABASE_ANON_KEY: string
}

// Von Vite zur Bauzeit ersetzt (siehe vite.config.ts).
declare const __APP_VERSION__: string
