'use strict';
const matrix = require('./candidate-matrix.json');

const output = matrix.candidates.map((candidate) => {
  const failures = Object.entries(candidate.statuses)
    .filter(([, status]) => status !== 'EXECUTABLE_PASS')
    .map(([control, status]) => ({ control, status }));
  return { candidate: candidate.name, verdict: failures.length ? 'FAIL' : 'PASS', failures };
});

process.stdout.write(`${JSON.stringify({ gate: 'FP-003', verdict: output.some(x => x.verdict === 'PASS') ? 'PASS' : 'FAIL', candidates: output }, null, 2)}\n`);
process.exitCode = output.some(x => x.verdict === 'PASS') ? 0 : 1;
