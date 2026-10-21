const c = (name) => `rgb(var(--${name}) / <alpha-value>)`;

/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        bg: c('bg'), panel: c('panel'), subtle: c('subtle'), line: c('line'), fg: c('fg'), muted: c('muted'),
        accent: c('accent'), ok: c('ok'), warn: c('warn'), bad: c('bad'),
      },
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      fontSize: { xs: ['0.75rem', '1rem'], sm: ['0.8125rem', '1.125rem'] },
    },
  },
  plugins: [],
};
