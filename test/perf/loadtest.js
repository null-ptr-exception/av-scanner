import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const cleanP95 = new Trend('scan_p95_clean', true);
const eicarP95 = new Trend('scan_p95_eicar', true);
const scanErrors = new Counter('scan_errors');

const API_URL = __ENV.API_URL;

// Load pre-generated test files from disk
const cleanZip = open('/tmp/k6-perf-data/clean.zip', 'b');
const eicarZip = open('/tmp/k6-perf-data/eicar.zip', 'b');

export const options = {
  scenarios: {
    clean: {
      executor: 'constant-vus',
      exec: 'scanClean',
      vus: 5,
      duration: '30s',
    },
    eicar: {
      executor: 'constant-vus',
      exec: 'scanEicar',
      vus: 2,
      duration: '30s',
    },
  },
  thresholds: {
    'http_req_failed': ['rate<0.05'],
  },
};

function doScan(payload, filename, expectedStatus, metric) {
  const res = http.post(`${API_URL}/api/v1/scan`, {
    file: http.file(payload, filename),
  });

  metric.add(res.timings.duration);

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
  });

  if (!ok) {
    scanErrors.add(1);
    return;
  }

  let body;
  try { body = JSON.parse(res.body); } catch (e) {
    scanErrors.add(1);
    return;
  }

  if (body.status !== expectedStatus) {
    scanErrors.add(1);
    console.error(`MISMATCH: expected=${expectedStatus} got=${body.status}`);
  }
}

export function scanClean() { doScan(cleanZip, 'clean.zip', 'clean',    cleanP95); }
export function scanEicar() { doScan(eicarZip, 'eicar.zip', 'infected', eicarP95); }

export function handleSummary(data) {
  const lines = ['\n========== LOAD TEST RESULTS =========='];

  for (const [label, key] of [['clean', 'scan_p95_clean'], ['eicar', 'scan_p95_eicar']]) {
    const m = data.metrics[key];
    if (m) {
      lines.push(`  ${label.padEnd(8)} | p95: ${m.values['p(95)'].toFixed(0).padStart(6)}ms | avg: ${m.values.avg.toFixed(0).padStart(6)}ms | count: ${m.values.count}`);
    } else {
      lines.push(`  ${label.padEnd(8)} | no data`);
    }
  }

  const failed = data.metrics['http_req_failed'];
  if (failed) {
    lines.push(`\n  Error rate: ${(failed.values.rate * 100).toFixed(2)}%`);
  }

  const errors = data.metrics['scan_errors'];
  if (errors) {
    lines.push(`  Scan mismatches: ${errors.values.count}`);
  }

  lines.push('=========================================\n');
  console.log(lines.join('\n'));

  return { stdout: JSON.stringify(data, null, 2) };
}
