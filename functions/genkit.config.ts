import { defineConfig } from '@genkit-ai/core';
import { gemini } from '@genkit-ai/gemini';

export default defineConfig({
  plugins: [gemini()],
  logLevel: 'debug',
});
