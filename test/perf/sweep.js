// Fixed arrival rate (RATE scans/s) for DURATION; 80% clean / 20% EICAR.
// Run through scripts/perf-test.sh sweep, which prints one JSON line per rate.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const API_URL = __ENV.API_URL;
const DATA = __ENV.DATA_DIR;
const clean = open(`${DATA}/clean.zip`, 'b');
const eicar = open(`${DATA}/eicar.zip`, 'b');
const mismatches = new Counter('scan_mismatches');

export const options = {
  scenarios: {
    sweep: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: 50,
      maxVUs: 300,
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'max'],
};

export default function () {
  const isEicar = Math.random() < 0.2;
  const res = http.post(`${API_URL}/api/v1/scan`, {
    file: http.file(isEicar ? eicar : clean, isEicar ? 'eicar.zip' : 'clean.zip'),
  }, { timeout: '60s', headers: __ENV.AUTH_TOKEN ? { Authorization: `Bearer ${__ENV.AUTH_TOKEN}` } : {} });
  let status = '';
  try { status = JSON.parse(res.body).status; } catch (e) {}
  const expected = isEicar ? 'infected' : 'clean';
  if (res.status !== 200 || status !== expected) {
    mismatches.add(1);
    console.error(`MISMATCH expected=${expected} http=${res.status} body=${String(res.body).slice(0, 300)}`);
  }
}

export function handleSummary(d) {
  const m = d.metrics, dur = m.http_req_duration.values;
  const out = {
    rate: Number(__ENV.RATE),
    achieved: m.iterations ? m.iterations.values.rate : 0,
    p50: dur['p(50)'], p95: dur['p(95)'], max: dur.max,
    failed: m.http_req_failed ? m.http_req_failed.values.rate : 0,
    mismatches: m.scan_mismatches ? m.scan_mismatches.values.count : 0,
    dropped: m.dropped_iterations ? m.dropped_iterations.values.count : 0,
    count: m.iterations ? m.iterations.values.count : 0,
  };
  return { stdout: JSON.stringify(out) + '\n' };
}
