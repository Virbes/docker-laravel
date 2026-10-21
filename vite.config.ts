import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import react from '@vitejs/plugin-react';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.tsx'],
            refresh: true,
        }),
        react(),
    ],
    server: {
        host: '0.0.0.0',          // Escuchar fuera del contenedor
        port: 5173,
        strictPort: true,
        hmr: {
            host: 'localhost',    // Donde el NAVEGADOR encuentra a Vite
        },
        // watch: { usePolling: true },  // Solo si el proyecto está en /mnt/c (Windows) y no detecta cambios
    },
});