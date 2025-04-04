import { flow } from '@genkit-ai/core';
import { generateText } from '@genkit-ai/gemini';
import * as functions from 'firebase-functions';

export const generateCrowdMap = flow('generateCrowdMap', async () => {
  const prompt = `
Simulate crowd_score (0.0 to 1.0) for 10 Penang bus stops with time (6AM–10PM), lat, lng.
Return in JSON: [{bus_stop_id, name, lat, lng, time, crowd_score}]
`;

  const result = await generateText({
    model: 'gemini-pro',
    prompt,
  });

  return result.text(); // or JSON.parse if you want structure
});

// Firebase HTTP function
export const generateCrowdMapHTTP = functions.https.onRequest(async (req, res) => {
  const data = await generateCrowdMap.run(); // .run() executes Genkit flow
  res.status(200).send(data);
});
