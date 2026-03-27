import http from "k6/http";
import { check, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://edge";

// -----------------------------
// Object taxonomy
// -----------------------------
const OBJECTS = {
  liveMaster: { name: "live_master", p95Ms: 500 },
  livePlaylist: { name: "live_playlist", p95Ms: 600 },
  liveSegment: { name: "live_segment", p95Ms: 900 },

  vodManifest: { name: "vod_manifest", p95Ms: 500 },
  vodPlaylist: { name: "vod_playlist", p95Ms: 600 },
  vodSegment: { name: "vod_segment", p95Ms: 900 },
};

// -----------------------------
// Catalog / media universe
// -----------------------------
const LIVE_CHANNELS = (__ENV.LIVE_CHANNELS || "match1,match2,match3").split(",");
const VOD_TITLES = (__ENV.VOD_TITLES || "movie1,movie2,movie3").split(",");

// -----------------------------
// Workload knobs
// -----------------------------
const TOTAL_VUS = Number(__ENV.TOTAL_VUS || 100);
const LIVE_FRAC = Number(__ENV.LIVE_FRAC || 0.5);
const LIVE_VUS = Math.floor(TOTAL_VUS * LIVE_FRAC);
const VOD_VUS = TOTAL_VUS - LIVE_VUS;

const LIVE_SEG_S = Number(__ENV.LIVE_SEG_S || 2);
const VOD_SEG_S = Number(__ENV.VOD_SEG_S || 2);

const LIVE_JOIN_RATE = Number(__ENV.LIVE_JOIN_RATE || 0);
const LIVE_JOIN_SPIKE = Number(__ENV.LIVE_JOIN_SPIKE || 0);
const LOCK_PROBE_RATE = Number(__ENV.LOCK_PROBE_RATE || 0);
const LOCK_PROBE_SPIKE = Number(__ENV.LOCK_PROBE_SPIKE || 0);
const HOT_VOD_TITLE = __ENV.HOT_VOD_TITLE || "movie1";
const HOT_VOD_SEGMENT = String(__ENV.HOT_VOD_SEGMENT || "0007");
const HOT_VOD_VARIANT = __ENV.HOT_VOD_VARIANT || "720p";

// -----------------------------
// Helpers
// -----------------------------
function pick(xs) {
  return xs[Math.floor(Math.random() * xs.length)];
}

function taggedGet(url, objectName) {
  return http.get(url, { tags: { name: objectName } });
}

function check200(response, kind) {
  return check(
    response,
    { [`${kind} status is 200`]: (r) => r.status === 200 },
    { kind }
  );
}

function requestAndCheck(url, objectName) {
  const res = taggedGet(url, objectName);
  check200(res, objectName);
  return res;
}

function purgeEdgeCache() {
  return http.request("PURGE", `${baseUrl}/cache`, null, {
    tags: { name: "edge_cache_purge" },
    timeout: "30s",
  });
}

// -----------------------------
// Thresholds
// -----------------------------
export const options = {
  thresholds: {
    http_req_failed: ["rate<0.01"],

    [`http_req_duration{name:${OBJECTS.liveMaster.name}}`]: [`p(95)<${OBJECTS.liveMaster.p95Ms}`],
    [`http_req_duration{name:${OBJECTS.livePlaylist.name}}`]: [`p(95)<${OBJECTS.livePlaylist.p95Ms}`],
    [`http_req_duration{name:${OBJECTS.liveSegment.name}}`]: [`p(95)<${OBJECTS.liveSegment.p95Ms}`],
    [`http_req_duration{name:${OBJECTS.vodManifest.name}}`]: [`p(95)<${OBJECTS.vodManifest.p95Ms}`],
    [`http_req_duration{name:${OBJECTS.vodPlaylist.name}}`]: [`p(95)<${OBJECTS.vodPlaylist.p95Ms}`],
    [`http_req_duration{name:${OBJECTS.vodSegment.name}}`]: [`p(95)<${OBJECTS.vodSegment.p95Ms}`],

    [`checks{kind:${OBJECTS.liveMaster.name}}`]: ["rate>0.95"],
    [`checks{kind:${OBJECTS.livePlaylist.name}}`]: ["rate>0.95"],
    [`checks{kind:${OBJECTS.liveSegment.name}}`]: ["rate>0.95"],
    [`checks{kind:${OBJECTS.vodManifest.name}}`]: ["rate>0.95"],
    [`checks{kind:${OBJECTS.vodPlaylist.name}}`]: ["rate>0.95"],
    [`checks{kind:${OBJECTS.vodSegment.name}}`]: ["rate>0.95"],
  },

  scenarios: {
    live_steady: {
      executor: "constant-vus",
      exec: "liveSteady",
      vus: LIVE_VUS,
      duration: __ENV.DURATION || "5m",
      tags: { traffic: "live", phase: "steady" },
    },

    vod_steady: {
      executor: "constant-vus",
      exec: "vodSteady",
      vus: VOD_VUS,
      duration: __ENV.DURATION || "5m",
      tags: { traffic: "vod", phase: "steady" },
    },

    ...(LIVE_JOIN_RATE > 0 || LIVE_JOIN_SPIKE > 0
      ? {
          live_joiners: {
            executor: "ramping-arrival-rate",
            exec: "liveJoiner",
            startRate: LIVE_JOIN_RATE,
            timeUnit: "1s",
            preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 50),
            maxVUs: Number(__ENV.MAX_VUS || 500),
            stages: [
              { target: LIVE_JOIN_RATE, duration: "30s" },
              { target: LIVE_JOIN_SPIKE, duration: "30s" },
              { target: LIVE_JOIN_RATE, duration: "60s" },
            ],
            tags: { traffic: "live", phase: "startup" },
          },
        }
      : {}),

    ...(LOCK_PROBE_RATE > 0 || LOCK_PROBE_SPIKE > 0
      ? {
          vod_lock_probe: {
            executor: "ramping-arrival-rate",
            exec: "vodLockProbe",
            startRate: LOCK_PROBE_RATE,
            timeUnit: "1s",
            preAllocatedVUs: Number(__ENV.LOCK_PROBE_PREALLOCATED_VUS || 50),
            maxVUs: Number(__ENV.LOCK_PROBE_MAX_VUS || 500),
            stages: [
              { target: LOCK_PROBE_RATE, duration: "30s" },
              { target: LOCK_PROBE_SPIKE, duration: "30s" },
              { target: LOCK_PROBE_RATE, duration: "60s" },
            ],
            tags: { traffic: "vod", phase: "cache_lock_probe" },
          },
        }
      : {}),
  },
};

// -----------------------------
// Behavior functions
// -----------------------------
export function liveSteady() {
  const channel = pick(LIVE_CHANNELS);

  if (__ITER % 15 === 0) {
    requestAndCheck(`${baseUrl}/live/${channel}/master.m3u8`, OBJECTS.liveMaster.name);
  }

  requestAndCheck(`${baseUrl}/live/${channel}/live.m3u8`, OBJECTS.livePlaylist.name);
  requestAndCheck(
    `${baseUrl}/live/${channel}/seg_${(__ITER % 500) + 1}.ts`,
    OBJECTS.liveSegment.name
  );

  sleep(LIVE_SEG_S);
}

export function vodSteady() {
  const title = pick(VOD_TITLES);

  if (__ITER % 10 === 0) {
    requestAndCheck(`${baseUrl}/vod/${title}/master.m3u8`, OBJECTS.vodManifest.name);
  }

  requestAndCheck(`${baseUrl}/vod/${title}/playlist.m3u8`, OBJECTS.vodPlaylist.name);
  requestAndCheck(
    `${baseUrl}/vod/${title}/seg_${String((__ITER % 1000) + 1).padStart(4, "0")}.ts`,
    OBJECTS.vodSegment.name
  );

  sleep(VOD_SEG_S);
}

export function liveJoiner() {
  const channel = pick(LIVE_CHANNELS);

  requestAndCheck(`${baseUrl}/live/${channel}/master.m3u8`, OBJECTS.liveMaster.name);
  requestAndCheck(`${baseUrl}/live/${channel}/live.m3u8`, OBJECTS.livePlaylist.name);

  for (let i = 0; i < 3; i++) {
    requestAndCheck(
      `${baseUrl}/live/${channel}/seg_${1200 + i}.ts`,
      OBJECTS.liveSegment.name
    );
  }
}

export function vodLockProbe() {
  requestAndCheck(
    `${baseUrl}/vod/${HOT_VOD_TITLE}/playlist.m3u8?variant=${HOT_VOD_VARIANT}`,
    OBJECTS.vodPlaylist.name
  );
  requestAndCheck(
    `${baseUrl}/vod/${HOT_VOD_TITLE}/seg_${HOT_VOD_SEGMENT}.ts?variant=${HOT_VOD_VARIANT}`,
    OBJECTS.vodSegment.name
  );
}

export function teardown() {
  const response = purgeEdgeCache();
  check(response, {
    "edge cache purge status is 200": (r) => r.status === 200,
  });
}
