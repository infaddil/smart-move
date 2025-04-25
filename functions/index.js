const functions = require("firebase-functions");

exports.generateCrowdMap = functions.https.onRequest((req, res) => {
  const busStops = [
    { id: "usm_main_gate", name: "USM Main Gate", lat: 5.3571, lng: 100.3035 },
    { id: "tesco_gelugor", name: "Tesco Gelugor", lat: 5.3840, lng: 100.3023 },
    { id: "sungai_dua", name: "Sungai Dua Terminal", lat: 5.3537, lng: 100.2985 },
    { id: "komtar", name: "Komtar", lat: 5.4141, lng: 100.3288 }
  ];

  const results = busStops.map(stop => ({
    ...stop,
    time: new Date().toISOString(),
    crowd_score: Number((Math.random() * 0.8 + 0.2).toFixed(2)) // 0.2–1.0
  }));

  res.json(results);
});
