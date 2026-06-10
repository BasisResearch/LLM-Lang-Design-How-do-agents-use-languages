#!/usr/bin/env node
// Read JSON from stdin and print value at path given as first arg (dot-separated)
// If path is empty, print the whole JSON
const fs = require('fs');

function get(obj, path) {
  if (!path) return obj;
  const parts = path.split('.');
  let cur = obj;
  for (const p of parts) {
    if (cur == null) return undefined;
    if (Array.isArray(cur) && /^\d+$/.test(p)) {
      cur = cur[Number(p)];
    } else {
      cur = cur[p];
    }
  }
  return cur;
}

let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => data += chunk);
process.stdin.on('end', () => {
  try {
    const obj = JSON.parse(data || 'null');
    const path = process.argv[2] || '';
    const val = get(obj, path);
    if (typeof val === 'object') {
      console.log(JSON.stringify(val));
    } else {
      console.log(String(val));
    }
  } catch (e) {
    console.error('Invalid JSON');
    process.exit(2);
  }
});

if (process.stdin.isTTY) {
  // if no stdin, read from file path arg2
  const file = process.argv[3];
  if (!file) process.exit(1);
  const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
  const path = process.argv[2] || '';
  const val = get(obj, path);
  if (typeof val === 'object') console.log(JSON.stringify(val));
  else console.log(String(val));
}
