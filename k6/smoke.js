import http from "k6/http";
import { check, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://edge";
const LABS = {
  baseline: "edge_cache_baseline",
  openresty: "openresty_runtime",
  admin: "edge_admin",
};

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

  openrestyTransform: { name: "openresty_transform", p95Ms: 450 },
  openrestyPolicy: { name: "openresty_policy", p95Ms: 350 },
  openrestyGcProbe: { name: "openresty_gc_probe", p95Ms: 900 },
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
const OPENRESTY_VUS = Number(__ENV.OPENRESTY_VUS || 0);
const OPENRESTY_SEG_S = Number(__ENV.OPENRESTY_SEG_S || 1);
const OPENRESTY_BURST_RATE = Number(__ENV.OPENRESTY_BURST_RATE || 0);
const OPENRESTY_BURST_SPIKE = Number(__ENV.OPENRESTY_BURST_SPIKE || 0);
const OPENRESTY_BURST_BASE_DURATION = __ENV.OPENRESTY_BURST_BASE_DURATION || "30s";
const OPENRESTY_BURST_SPIKE_DURATION = __ENV.OPENRESTY_BURST_SPIKE_DURATION || "30s";
const OPENRESTY_BURST_RECOVERY_DURATION = __ENV.OPENRESTY_BURST_RECOVERY_DURATION || "60s";

// -----------------------------
// Helpers
// -----------------------------
function pick(xs) {
  return xs[Math.floor(Math.random() * xs.length)];
}

function taggedGet(url, objectName, extraTags = {}) {
  return http.get(url, { tags: { name: objectName, ...extraTags } });
}

function check200(response, kind) {
  return check(
    response,
    { [`${kind} status is 200`]: (r) => r.status === 200 },
    { kind }
  );
}

function requestAndCheck(url, objectName, extraTags = {}) {
  const res = taggedGet(url, objectName, extraTags);
  check200(res, objectName);
  return res;
}

function purgeEdgeCache() {
  return http.request("PURGE", `${baseUrl}/cache`, null, {
    tags: {
      name: "edge_cache_purge",
      lab: LABS.admin,
      edge_mode: "edge_admin",
      experiment: "cache_purge",
    },
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
    ...(OPENRESTY_VUS > 0 || OPENRESTY_BURST_RATE > 0 || OPENRESTY_BURST_SPIKE > 0
      ? {
          [`http_req_duration{name:${OBJECTS.openrestyTransform.name}}`]: [
            `p(95)<${OBJECTS.openrestyTransform.p95Ms}`,
          ],
          [`http_req_duration{name:${OBJECTS.openrestyPolicy.name}}`]: [
            `p(95)<${OBJECTS.openrestyPolicy.p95Ms}`,
          ],
          [`http_req_duration{name:${OBJECTS.openrestyGcProbe.name}}`]: [
            `p(95)<${OBJECTS.openrestyGcProbe.p95Ms}`,
          ],
          [`checks{kind:${OBJECTS.openrestyTransform.name}}`]: ["rate>0.95"],
          [`checks{kind:${OBJECTS.openrestyPolicy.name}}`]: ["rate>0.95"],
          [`checks{kind:${OBJECTS.openrestyGcProbe.name}}`]: ["rate>0.95"],
        }
      : {}),
  },

  scenarios: {
    live_steady: {
      executor: "constant-vus",
      exec: "liveSteady",
      vus: LIVE_VUS,
      duration: __ENV.DURATION || "5m",
      tags: { traffic: "live", phase: "steady", lab: LABS.baseline, edge_mode: "proxy_cache" },
    },

    vod_steady: {
      executor: "constant-vus",
      exec: "vodSteady",
      vus: VOD_VUS,
      duration: __ENV.DURATION || "5m",
      tags: { traffic: "vod", phase: "steady", lab: LABS.baseline, edge_mode: "proxy_cache" },
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
            tags: {
              traffic: "live",
              phase: "startup",
              lab: LABS.baseline,
              edge_mode: "proxy_cache",
            },
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
            tags: {
              traffic: "vod",
              phase: "cache_lock_probe",
              lab: LABS.baseline,
              edge_mode: "proxy_cache",
            },
          },
        }
      : {}),

    ...(OPENRESTY_VUS > 0
      ? {
          openresty_runtime: {
            executor: "constant-vus",
            exec: "openrestyRuntime",
            vus: OPENRESTY_VUS,
            duration: __ENV.OPENRESTY_DURATION || __ENV.DURATION || "5m",
            tags: {
              traffic: "openresty",
              phase: "steady",
              lab: LABS.openresty,
              edge_mode: "openresty_lua",
            },
          },
        }
      : {}),

    ...(OPENRESTY_BURST_RATE > 0 || OPENRESTY_BURST_SPIKE > 0
      ? {
          openresty_gc_burst: {
            executor: "ramping-arrival-rate",
            exec: "openrestyGcBurst",
            startRate: OPENRESTY_BURST_RATE,
            timeUnit: "1s",
            preAllocatedVUs: Number(__ENV.OPENRESTY_PREALLOCATED_VUS || 25),
            maxVUs: Number(__ENV.OPENRESTY_MAX_VUS || 250),
            stages: [
              { target: OPENRESTY_BURST_RATE, duration: OPENRESTY_BURST_BASE_DURATION },
              { target: OPENRESTY_BURST_SPIKE, duration: OPENRESTY_BURST_SPIKE_DURATION },
              { target: OPENRESTY_BURST_RATE, duration: OPENRESTY_BURST_RECOVERY_DURATION },
            ],
            tags: {
              traffic: "openresty",
              phase: "gc_burst",
              lab: LABS.openresty,
              edge_mode: "openresty_lua",
            },
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
  const tags = { experiment: "baseline_live" };

  if (__ITER % 15 === 0) {
    requestAndCheck(`${baseUrl}/live/${channel}/master.m3u8`, OBJECTS.liveMaster.name, tags);
  }

  requestAndCheck(`${baseUrl}/live/${channel}/live.m3u8`, OBJECTS.livePlaylist.name, tags);
  requestAndCheck(
    `${baseUrl}/live/${channel}/seg_${(__ITER % 500) + 1}.ts`,
    OBJECTS.liveSegment.name,
    tags
  );

  sleep(LIVE_SEG_S);
}

export function vodSteady() {
  const title = pick(VOD_TITLES);
  const tags = { experiment: "baseline_vod" };

  if (__ITER % 10 === 0) {
    requestAndCheck(`${baseUrl}/vod/${title}/master.m3u8`, OBJECTS.vodManifest.name, tags);
  }

  requestAndCheck(`${baseUrl}/vod/${title}/playlist.m3u8`, OBJECTS.vodPlaylist.name, tags);
  requestAndCheck(
    `${baseUrl}/vod/${title}/seg_${String((__ITER % 1000) + 1).padStart(4, "0")}.ts`,
    OBJECTS.vodSegment.name,
    tags
  );

  sleep(VOD_SEG_S);
}

export function liveJoiner() {
  const channel = pick(LIVE_CHANNELS);
  const tags = { experiment: "baseline_live_join" };

  requestAndCheck(`${baseUrl}/live/${channel}/master.m3u8`, OBJECTS.liveMaster.name, tags);
  requestAndCheck(`${baseUrl}/live/${channel}/live.m3u8`, OBJECTS.livePlaylist.name, tags);

  for (let i = 0; i < 3; i++) {
    requestAndCheck(
      `${baseUrl}/live/${channel}/seg_${1200 + i}.ts`,
      OBJECTS.liveSegment.name,
      tags
    );
  }
}

export function vodLockProbe() {
  requestAndCheck(
    `${baseUrl}/vod/${HOT_VOD_TITLE}/playlist.m3u8?variant=${HOT_VOD_VARIANT}`,
    OBJECTS.vodPlaylist.name,
    { experiment: "baseline_vod_lock_probe", variant: HOT_VOD_VARIANT }
  );
  requestAndCheck(
    `${baseUrl}/vod/${HOT_VOD_TITLE}/seg_${HOT_VOD_SEGMENT}.ts?variant=${HOT_VOD_VARIANT}`,
    OBJECTS.vodSegment.name,
    { experiment: "baseline_vod_lock_probe", variant: HOT_VOD_VARIANT }
  );
}

export function openrestyRuntime() {
  if (__ITER % 2 === 0) {
    requestAndCheck(
      `${baseUrl}/openresty/lua/transform?repeat=48&width=6&decode=1&seed=vod${__VU}`,
      OBJECTS.openrestyTransform.name,
      { experiment: "lua_transform", openresty_target: "transform" }
    );
  } else {
    requestAndCheck(
      `${baseUrl}/openresty/lua/policy?tenant=demo&title=movie${(__ITER % 3) + 1}&variant=${pick([
        "540p",
        "720p",
        "1080p",
      ])}&region=${pick(["us", "eu", "apac"])}&entitlements=vod,hd,edge`,
      OBJECTS.openrestyPolicy.name,
      { experiment: "lua_policy", openresty_target: "policy" }
    );
  }

  sleep(OPENRESTY_SEG_S);
}

export function openrestyGcBurst() {
  requestAndCheck(
    `${baseUrl}/openresty/lua/transform?repeat=160&width=12&decode=1&seed=burst${__VU}`,
    OBJECTS.openrestyGcProbe.name,
    { experiment: "lua_gc_burst", openresty_target: "transform" }
  );
}

export function teardown() {
  const response = purgeEdgeCache();
  check(response, {
    "edge cache purge status is 200": (r) => r.status === 200,
  });
}
